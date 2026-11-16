//
//  DaemonServer.swift
//  Mac Fan
//
//  Privileged daemon that runs as root via launchd and owns all SMC writes.
//  Architecture adapted from ThermalForge (MIT), extended with per-fan
//  commands and a daemon-side thermal failsafe.
//
//  Safety layers (independent of the app):
//    - Heartbeat watchdog: fans manual + no app ping for 15 s -> back to auto
//    - Thermal failsafe: any sensor >= 95 °C -> max fans until it cools
//    - Wake: returns to Apple auto until the app reapplies its live profile
//    - SIGTERM: resets fans to auto before exiting
//

import Darwin
import Foundation
import IOKit.pwr_mgt

public final class DaemonServer {
    private let socketFD: Int32
    private let socketPath: String
    private let performanceLock = NSLock()
    private let clientSlots = DispatchSemaphore(value: 4)
    private let fanControl: FanControl
    /// Serializes all SMC access across client handler / watchdog / wake
    private let smcLock = NSLock()

    /// Fans currently under manual control: fan index -> commanded RPM.
    /// Empty means everything is in Apple auto mode.
    private var manualFans: [Int: Float] = [:]
    private var lastHeartbeat: Date?
    private var failsafeActive = false
    private var resetPending = false
    private let stateLock = NSLock()

    private var sigtermSource: DispatchSourceSignal?

    public convenience init(fanControl: FanControl) throws {
        try self.init(fanControl: fanControl, socketPath: MacFanDaemon.socketPath)
    }

    init(fanControl: FanControl, socketPath: String) throws {
        self.socketPath = socketPath
        self.fanControl = fanControl

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacFanError.smcConnectionFailed }
        self.socketFD = fd

        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setSocketPath(&addr, socketPath)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw MacFanError.writeFailed("bind() failed: \(errno)")
        }

        // Allow all local users to connect
        chmod(socketPath, 0o777)

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw MacFanError.writeFailed("listen() failed")
        }
    }

    /// Run the server loop (blocks forever)
    public func run() {
        NSLog("macfan daemon: listening on %@", socketPath)

        registerWakeNotification()
        registerSigterm()
        startWatchdog()

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                clientSlots.wait()
                let clientFD = accept(socketFD, nil, nil)
                guard clientFD >= 0 else { clientSlots.signal(); continue }
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer { clientSlots.signal() }
                    handleClient(clientFD)
                    close(clientFD)
                }
            }
        }

        // Main thread runs the RunLoop for wake notifications
        RunLoop.main.run()
    }

    // MARK: - Watchdog + Failsafe

    /// A one-second safety tick is independent of monitoring and client requests.
    private func startWatchdog() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                watchdogTick()
            }
        }
    }

    // All hardware and state transitions use the same lock order: SMC, state.
    func watchdogTick(now: Date = Date()) {
        smcLock.lock()
        defer { smcLock.unlock() }
        let hottest = fanControl.readTemperatures().values.max()
        stateLock.lock()
        let wasActive = failsafeActive
        if let hottest {
            if hottest >= ThermalSafety.failsafeTemp { failsafeActive = true }
            if hottest < ThermalSafety.failsafeClearTemp { failsafeActive = false }
        } else {
            failsafeActive = false
        }
        let active = failsafeActive
        let needsReset = resetPending
        let timedOut = !manualFans.isEmpty && (lastHeartbeat.map { now.timeIntervalSince($0) >= 15 } ?? true)
        stateLock.unlock()

        if active {
            do { try fanControl.setMax() }
            catch {
                NSLog("macfan daemon: failsafe fan write failed: %@", "\(error)")
                resetTrackedFans()
            }
        } else if hottest == nil || wasActive || timedOut || needsReset {
            // Missing sensors are not a temperature of zero. Return to Apple's
            // thermal controller instead of holding a stale manual speed.
            resetTrackedFans()
        }
    }

    private func resetTrackedFans() {
        do {
            try fanControl.resetAuto()
            stateLock.lock()
            manualFans = [:]
            lastHeartbeat = nil
            resetPending = false
            stateLock.unlock()
        } catch {
            NSLog("macfan daemon: auto reset failed: %@; will retry", "\(error)")
            stateLock.lock()
            // Keep the watchdog armed even after a partially failed command.
            resetPending = true
            stateLock.unlock()
        }
    }

    // MARK: - SIGTERM

    private func registerSigterm() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { [self] in
            NSLog("macfan daemon: SIGTERM — resetting fans to auto and exiting")
            smcLock.lock()
            try? fanControl.resetAuto()
            smcLock.unlock()
            unlink(socketPath)
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    // MARK: - Sleep/Wake

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private func registerWakeNotification() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &notifyPort, { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let server = Unmanaged<DaemonServer>.fromOpaque(refcon).takeUnretainedValue()

                // IOKit message constants (macros unavailable in Swift)
                let kSystemHasPoweredOn: UInt32 = 0xe0000300
                let kSystemWillSleep: UInt32 = 0xe0000280
                let kCanSystemSleep: UInt32 = 0xe0000270

                switch messageType {
                case kSystemHasPoweredOn:
                    server.handleWake()
                case kSystemWillSleep, kCanSystemSleep:
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: messageArgument)))
                default:
                    break
                }
            }, &notifier
        )

        guard rootPort != 0, let notifyPort = notifyPort else {
            NSLog("macfan daemon: failed to register for power notifications")
            return
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        NSLog("macfan daemon: registered for wake notifications")
    }

    func handleWake() {
        // Profiles will reapply on the next app poll. Never resurrect a captured
        // manual setting after its owner has quit or switched back to Auto.
        smcLock.lock()
        defer { smcLock.unlock() }
        resetTrackedFans()
    }

    // MARK: - Client Handling

    private func handleClient(_ fd: Int32) {
        configureSocket(fd, timeout: 15)
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { return }

        let command = String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let response = process(command)

        let responseBytes = Array((response + "\n").utf8)
        _ = responseBytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
    }

    func process(_ command: String) -> String {
        // powermetrics takes a short sample and must not hold the SMC lock;
        // fan polling and safety enforcement continue while it runs.
        if command == "performance" || command.hasPrefix("performance ") {
            do {
                let requested = command.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                let sampleMilliseconds = Swift.min(Swift.max(requested ?? 500, 250), 2_000)
                let snapshot = try readPerformanceSnapshot(sampleMilliseconds: sampleMilliseconds)
                let data = try JSONEncoder().encode(snapshot)
                return String(data: data, encoding: .utf8) ?? "error: encode failed"
            } catch {
                return "error: performance sample failed: \(error)"
            }
        }

        smcLock.lock()
        defer { smcLock.unlock() }

        stateLock.lock()
        let failsafe = failsafeActive
        stateLock.unlock()

        let parts = command.split(separator: " ")
        do {
            switch parts.first.map(String.init) {
            case "status":
                let status = try fanControl.status()
                let data = try JSONEncoder().encode(status)
                return String(data: data, encoding: .utf8) ?? "error: encode failed"

            case "heartbeat":
                stateLock.lock()
                lastHeartbeat = Date()
                stateLock.unlock()
                return "ok"

            case "set":
                guard !failsafe else { return "error: thermal failsafe active" }
                guard parts.count >= 2, let rpm = Float(parts[1]), rpm.isFinite, rpm >= 0 else {
                    return "error: usage: set <rpm>"
                }
                let count = try fanControl.fanCount()
                guard !fanControl.readTemperatures().isEmpty else {
                    resetTrackedFans()
                    return "error: temperature sensors unavailable; fans returned to Apple control"
                }
                try fanControl.setAllFans(rpm: rpm)
                stateLock.lock()
                for i in 0..<count { manualFans[i] = rpm }
                lastHeartbeat = Date()
                stateLock.unlock()
                return "ok"

            case "setfan":
                guard !failsafe else { return "error: thermal failsafe active" }
                guard parts.count >= 3, let index = Int(parts[1]), let rpm = Float(parts[2]), rpm.isFinite, rpm >= 0 else {
                    return "error: usage: setfan <index> <rpm>"
                }
                guard index >= 0, index < (try fanControl.fanCount()) else {
                    return "error: no fan \(index)"
                }
                guard !fanControl.readTemperatures().isEmpty else {
                    resetTrackedFans()
                    return "error: temperature sensors unavailable; fans returned to Apple control"
                }
                try fanControl.setSpeed(fan: index, rpm: rpm)
                stateLock.lock()
                manualFans[index] = rpm
                lastHeartbeat = Date()
                stateLock.unlock()
                return "ok"

            case "max":
                guard !failsafe else { return "error: thermal failsafe active" }
                try fanControl.setMax()
                let count = try fanControl.fanCount()
                stateLock.lock()
                for i in 0..<count {
                    let info = try? fanControl.fanInfo(i)
                    manualFans[i] = info?.maxRPM ?? 0
                }
                lastHeartbeat = Date()
                stateLock.unlock()
                return "ok"

            case "auto":
                guard !failsafe else { return "error: thermal failsafe active" }
                try fanControl.resetAuto()
                stateLock.lock()
                manualFans = [:]
                lastHeartbeat = nil
                stateLock.unlock()
                return "ok"

            case "autofan":
                guard !failsafe else { return "error: thermal failsafe active" }
                guard parts.count >= 2, let index = Int(parts[1]) else {
                    return "error: usage: autofan <index>"
                }
                guard index >= 0, index < (try fanControl.fanCount()) else {
                    return "error: no fan \(index)"
                }
                try fanControl.resetAutoFan(index)
                stateLock.lock()
                manualFans.removeValue(forKey: index)
                if manualFans.isEmpty { lastHeartbeat = nil }
                stateLock.unlock()
                return "ok"

            default:
                return "error: unknown command '\(command)'"
            }
        } catch {
            if ["set", "setfan", "max", "auto", "autofan"].contains(parts.first.map(String.init) ?? "") {
                resetTrackedFans()
            }
            return "error: \(error)"
        }
    }

    private func readPerformanceSnapshot(sampleMilliseconds: Int) throws -> PerformanceSnapshot {
        guard performanceLock.try() else { throw DaemonError.commandFailed("Performance sampler is busy") }
        defer { performanceLock.unlock() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "--samplers", "cpu_power,gpu_power,ane_power",
            "--sample-count", "1",
            "--sample-rate", "\(sampleMilliseconds)",
            "--format", "plist",
            "--buffer-size", "0",
            "--handle-invalid-values",
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? "powermetrics failed"
            throw DaemonError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try PerformanceSnapshot.parsePowermetricsPlist(data)
    }

    deinit {
        close(socketFD)
        unlink(socketPath)
    }
}
