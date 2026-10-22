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
//    - Sleep/wake: re-applies the last manual settings after wake
//    - SIGTERM: resets fans to auto before exiting
//

import Darwin
import Foundation
import IOKit.pwr_mgt

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl
    /// Serializes all SMC access across client handler / watchdog / wake
    private let smcLock = NSLock()

    /// Fans currently under manual control: fan index -> commanded RPM.
    /// Empty means everything is in Apple auto mode.
    private var manualFans: [Int: Float] = [:]
    private var lastHeartbeat: Date?
    private var failsafeActive = false
    private let stateLock = NSLock()

    private var sigtermSource: DispatchSourceSignal?

    public init(fanControl: FanControl) throws {
        self.fanControl = fanControl

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacFanError.smcConnectionFailed }
        self.socketFD = fd

        unlink(MacFanDaemon.socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setSocketPath(&addr, MacFanDaemon.socketPath)

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
        chmod(MacFanDaemon.socketPath, 0o777)

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw MacFanError.writeFailed("listen() failed")
        }
    }

    /// Run the server loop (blocks forever)
    public func run() {
        NSLog("macfan daemon: listening on %@", MacFanDaemon.socketPath)

        registerWakeNotification()
        registerSigterm()
        startWatchdog()

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let clientFD = accept(socketFD, nil, nil)
                guard clientFD >= 0 else { continue }
                handleClient(clientFD)
                close(clientFD)
            }
        }

        // Main thread runs the RunLoop for wake notifications
        RunLoop.main.run()
    }

    // MARK: - Watchdog + Failsafe

    /// Every 5 s: enforce the thermal failsafe and the heartbeat watchdog.
    private func startWatchdog() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: 5)

                // --- Thermal failsafe ---
                smcLock.lock()
                let hottest = fanControl.readTemperatures().values.max() ?? 0
                smcLock.unlock()

                stateLock.lock()
                let wasActive = failsafeActive
                if hottest >= ThermalSafety.failsafeTemp { failsafeActive = true }
                if failsafeActive && hottest < ThermalSafety.failsafeClearTemp { failsafeActive = false }
                let isActive = failsafeActive
                stateLock.unlock()

                if isActive {
                    NSLog("macfan daemon: FAILSAFE — hottest sensor %.1f°C, forcing max fans", hottest)
                    smcLock.lock()
                    try? fanControl.setMax()
                    smcLock.unlock()
                    continue
                } else if wasActive {
                    NSLog("macfan daemon: failsafe cleared (%.1f°C) — fans back to auto", hottest)
                    smcLock.lock()
                    try? fanControl.resetAuto()
                    smcLock.unlock()
                    stateLock.lock()
                    manualFans = [:]
                    lastHeartbeat = nil
                    stateLock.unlock()
                    continue
                }

                // --- Heartbeat watchdog ---
                stateLock.lock()
                let beat = lastHeartbeat
                let hasManual = !manualFans.isEmpty
                stateLock.unlock()

                guard let lastBeat = beat, hasManual else { continue }

                if Date().timeIntervalSince(lastBeat) > 15 {
                    NSLog("macfan daemon: heartbeat timeout — resetting fans to auto")
                    smcLock.lock()
                    let resetSucceeded: Bool
                    do {
                        try fanControl.resetAuto()
                        resetSucceeded = true
                    } catch {
                        NSLog("macfan daemon: watchdog reset failed: %@, will retry", "\(error)")
                        resetSucceeded = false
                    }
                    smcLock.unlock()

                    if resetSucceeded {
                        stateLock.lock()
                        manualFans = [:]
                        lastHeartbeat = nil
                        stateLock.unlock()
                    }
                }
            }
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
            unlink(MacFanDaemon.socketPath)
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

    private func handleWake() {
        stateLock.lock()
        let toApply = manualFans
        stateLock.unlock()

        guard !toApply.isEmpty else {
            NSLog("macfan daemon: woke — nothing to re-apply")
            return
        }

        NSLog("macfan daemon: woke — re-applying manual fan settings")

        // Delay slightly — SMC needs a moment after wake
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            smcLock.lock()
            defer { smcLock.unlock() }
            for (index, rpm) in toApply {
                do {
                    try fanControl.setSpeed(fan: index, rpm: rpm)
                } catch {
                    NSLog("macfan daemon: wake re-apply fan %d failed: %@", index, "\(error)")
                }
            }
        }
    }

    // MARK: - Client Handling

    private func handleClient(_ fd: Int32) {
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

    private func process(_ command: String) -> String {
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

        stateLock.lock()
        let failsafe = failsafeActive
        stateLock.unlock()

        smcLock.lock()
        defer { smcLock.unlock() }

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
                guard parts.count >= 2, let rpm = Float(parts[1]) else {
                    return "error: usage: set <rpm>"
                }
                let count = try fanControl.fanCount()
                for i in 0..<count {
                    try fanControl.setSpeed(fan: i, rpm: rpm)
                }
                stateLock.lock()
                for i in 0..<count { manualFans[i] = rpm }
                lastHeartbeat = Date()
                stateLock.unlock()
                return "ok"

            case "setfan":
                guard !failsafe else { return "error: thermal failsafe active" }
                guard parts.count >= 3, let index = Int(parts[1]), let rpm = Float(parts[2]) else {
                    return "error: usage: setfan <index> <rpm>"
                }
                guard index >= 0, index < (try fanControl.fanCount()) else {
                    return "error: no fan \(index)"
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
                    manualFans[i] = info.map { $0.maxRPM > 0 ? $0.maxRPM : 7826 } ?? 7826
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
            return "error: \(error)"
        }
    }

    private func readPerformanceSnapshot(sampleMilliseconds: Int) throws -> PerformanceSnapshot {
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
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "powermetrics failed"
            throw DaemonError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try PerformanceSnapshot.parsePowermetricsPlist(data)
    }

    deinit {
        close(socketFD)
        unlink(MacFanDaemon.socketPath)
    }
}
