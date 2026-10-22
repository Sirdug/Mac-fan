//
//  DaemonProtocol.swift
//  Mac Fan
//
//  Unix-socket protocol between the unprivileged app/CLI and the root
//  daemon. Line-based commands, single response per connection.
//  Architecture adapted from ThermalForge (MIT).
//
//  Commands:
//    status            -> JSON ThermalStatus
//    set <rpm>         -> all fans to RPM
//    setfan <i> <rpm>  -> one fan to RPM
//    auto              -> all fans back to Apple control
//    autofan <i>       -> one fan back to Apple control
//    max               -> all fans to max RPM
//    heartbeat         -> app liveness ping (watchdog)
//    performance [ms]  -> JSON PerformanceSnapshot (privileged powermetrics)
//

import Darwin
import Foundation

// MARK: - Constants

public enum MacFanDaemon {
    public static let socketPath = "/tmp/macfan.sock"
    public static let label = "com.macfan.daemon"
    public static let plistPath = "/Library/LaunchDaemons/com.macfan.daemon.plist"
    public static let installPath = "/usr/local/bin/macfan"

    /// Competing fan daemons the installer disables (kept on disk).
    public static let competingDaemons = [
        "com.thermalforge.daemon",
        "com.fancontrol.fancontrold",
    ]

    /// Check if the daemon socket exists and accepts connections
    public static var isRunning: Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setSocketPath(&addr, socketPath)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

/// Copy a path string into sockaddr_un.sun_path
func setSocketPath(_ addr: inout sockaddr_un, _ path: String) {
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            _ = strlcpy(dest, path, 104)
        }
    }
}

// MARK: - Errors

public enum DaemonError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case commandFailed(String)

    public var description: String {
        switch self {
        case .notRunning:
            return "Mac Fan daemon is not running. Run: sudo macfan install"
        case .connectionFailed:
            return "Failed to connect to daemon socket"
        case .commandFailed(let msg):
            return "Daemon error: \(msg)"
        }
    }
}

// MARK: - Client

public final class DaemonClient {
    public init() {}

    /// Send a command and return the raw response line(s).
    public func send(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setSocketPath(&addr, MacFanDaemon.socketPath)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw DaemonError.notRunning }

        let cmdData = Array((command + "\n").utf8)
        _ = cmdData.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }

        // Server writes one response then closes — read to EOF
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard !data.isEmpty else { throw DaemonError.connectionFailed }

        let response = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if response.hasPrefix("error:") {
            throw DaemonError.commandFailed(
                String(response.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            )
        }
        return response
    }

    // MARK: Typed API

    public func status() throws -> ThermalStatus {
        let response = try send("status")
        guard let data = response.data(using: .utf8) else {
            throw DaemonError.commandFailed("bad status payload")
        }
        return try JSONDecoder().decode(ThermalStatus.self, from: data)
    }

    public func setAll(rpm: Float) throws { _ = try send("set \(Int(rpm))") }
    public func setFan(_ index: Int, rpm: Float) throws { _ = try send("setfan \(index) \(Int(rpm))") }
    public func auto() throws { _ = try send("auto") }
    public func autoFan(_ index: Int) throws { _ = try send("autofan \(index)") }
    public func max() throws { _ = try send("max") }
    public func heartbeat() throws { _ = try send("heartbeat") }

    public func performance(sampleMilliseconds: Int = 500) throws -> PerformanceSnapshot {
        let clamped = Swift.min(Swift.max(sampleMilliseconds, 250), 2_000)
        let response = try send("performance \(clamped)")
        guard let data = response.data(using: .utf8) else {
            throw DaemonError.commandFailed("bad performance payload")
        }
        return try JSONDecoder().decode(PerformanceSnapshot.self, from: data)
    }
}
