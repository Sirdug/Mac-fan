//
//  main.swift
//  macfan CLI
//
//  Commands:
//    sudo macfan install     Install + start the root daemon (disables
//                            ThermalForge / fancontrold daemons first)
//    sudo macfan uninstall   Stop + remove the daemon, reset fans to auto
//    sudo macfan daemon      Run the daemon (invoked by launchd)
//    macfan status           Show fans + temperatures
//    macfan diagnose         Read-only hardware/telemetry compatibility report
//    macfan set <rpm>        All fans to RPM
//    macfan setfan <i> <rpm> One fan to RPM
//    macfan auto             All fans back to Apple control
//    macfan max              All fans to max
//

import Foundation
import MacFanCore

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("macfan: " + message + "\n").utf8))
    exit(1)
}

func requireRoot(_ what: String) {
    guard geteuid() == 0 else { fail("\(what) requires root. Run with sudo.") }
}

@discardableResult
func shell(_ command: String) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", command]
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

// MARK: - Install / Uninstall

func disableCompetingDaemons() {
    for label in MacFanDaemon.competingDaemons {
        let plist = "/Library/LaunchDaemons/\(label).plist"
        guard FileManager.default.fileExists(atPath: plist) else { continue }
        print("Disabling competing fan daemon: \(label)")
        shell("launchctl bootout system/\(label) 2>/dev/null")
        shell("launchctl disable system/\(label)")
    }
    // Stop the ThermalForge app so it doesn't complain about its dead daemon
    shell("pkill -x ThermalForgeApp 2>/dev/null")
}

func install() {
    requireRoot("install")

    disableCompetingDaemons()

    // Stop the old helper before resetting/copying so it cannot reapply a
    // manual target while the installer is handing control back to Apple.
    shell("launchctl bootout system/\(MacFanDaemon.label) 2>/dev/null")

    // Reset fans in case an old daemon left them in manual mode
    do {
        try FanControl().resetAuto()
        print("Fans reset to Apple auto control")
    } catch {
        fail("could not restore Apple fan control: \(error)")
    }

    // Copy this binary to the install path
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    if selfPath != MacFanDaemon.installPath {
        try? FileManager.default.removeItem(atPath: MacFanDaemon.installPath)
        try? FileManager.default.createDirectory(
            atPath: "/usr/local/bin", withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(atPath: selfPath, toPath: MacFanDaemon.installPath)
        } catch {
            fail("failed to copy binary to \(MacFanDaemon.installPath): \(error)")
        }
        shell("chown root:wheel '\(MacFanDaemon.installPath)' && chmod 755 '\(MacFanDaemon.installPath)'")
        print("Installed CLI: \(MacFanDaemon.installPath)")
    }

    // Write the plist and start the new helper.
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(MacFanDaemon.label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(MacFanDaemon.installPath)</string>
            <string>daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/tmp/macfan.daemon.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/macfan.daemon.log</string>
    </dict>
    </plist>
    """
    do {
        try plist.write(toFile: MacFanDaemon.plistPath, atomically: true, encoding: .utf8)
    } catch {
        fail("failed to write \(MacFanDaemon.plistPath): \(error)")
    }
    shell("chown root:wheel '\(MacFanDaemon.plistPath)' && chmod 644 '\(MacFanDaemon.plistPath)'")

    shell("launchctl enable system/\(MacFanDaemon.label)")
    guard shell("launchctl bootstrap system '\(MacFanDaemon.plistPath)'") == 0 else {
        fail("launchctl bootstrap failed — check /tmp/macfan.daemon.log")
    }

    // Wait for the socket to come up
    for _ in 0..<20 {
        if MacFanDaemon.isRunning { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print(MacFanDaemon.isRunning
        ? "Mac Fan daemon installed and running."
        : "Daemon installed but socket not up yet — check /tmp/macfan.daemon.log")
}

func uninstall() {
    requireRoot("uninstall")

    shell("launchctl bootout system/\(MacFanDaemon.label) 2>/dev/null")
    do {
        try FanControl().resetAuto()
    } catch {
        fail("could not restore Apple fan control; helper files retained for retry: \(error)")
    }
    try? FileManager.default.removeItem(atPath: MacFanDaemon.plistPath)
    try? FileManager.default.removeItem(atPath: MacFanDaemon.installPath)
    unlink(MacFanDaemon.socketPath)

    print("Mac Fan daemon removed; fans back to Apple auto control.")
    print("(Note: previously disabled daemons — ThermalForge, fancontrold — stay disabled.)")
}

// MARK: - Status

func printStatus() {
    let status: ThermalStatus
    do {
        status = try DaemonClient().status()
    } catch {
        // Fall back to direct read (works unprivileged for reads on some setups)
        guard let fc = try? FanControl(), let direct = try? fc.status() else {
            fail("\(error)")
        }
        printStatus(direct)
        return
    }
    printStatus(status)
}

func printStatus(_ status: ThermalStatus) {
    print("FANS")
    for fan in status.fans {
        print(String(
            format: "  Fan %d: %5d RPM  (target %d, range %d-%d, %@)",
            fan.index, Int(fan.actualRPM), Int(fan.targetRPM),
            Int(fan.minRPM), Int(fan.maxRPM), fan.mode
        ))
    }
    print("TEMPERATURES")
    for (group, temp) in SensorCatalog.groupedMaxima(status.temperatures) {
        let name = group.displayName.padding(toLength: 8, withPad: " ", startingAt: 0)
        print(String(format: "  %@ %5.1f°C", name, temp))
    }
}

/// Safe to run on the target M1 Pro: does not issue any SMC writes and does not
/// include serial numbers, hardware UUIDs, or other device identifiers.
func diagnose() {
    print("Mac Fan compatibility report (read-only)")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for key in ["hw.model", "machdep.cpu.brand_string"] {
        var size = 0
        if sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname(key, &bytes, &size, nil, 0) == 0 {
                print("\(key): \(String(cString: bytes))")
            }
        }
    }
    do {
        let control = try FanControl()
        let status = try control.status()
        printStatus(status)
        print("Readable temperature sensors: \(status.temperatures.count)")
        let missing = SensorGroup.allCases.filter {
            SensorSource.group($0).resolve(in: status.temperatures) == nil
        }
        if !missing.isEmpty {
            print("Unavailable temperature groups: \(missing.map(\.displayName).joined(separator: ", "))")
        }
        if let smc = SMCConnection() {
            for fan in status.fans {
                let key = [SMCFanKey.modeUpper, SMCFanKey.modeLower]
                    .map { SMCFanKey.key($0, fan: fan.index) }
                    .first { smc.getKeyInfo($0)?.size == 1 }
                print("Fan \(fan.index) mode key: \(key ?? "unavailable")")
            }
            print("Diagnostic unlock key: \(smc.getKeyInfo(SMCFanKey.forceTest) == nil ? "absent (direct control)" : "available if needed")")
        }
    } catch {
        print("Direct hardware read unavailable: \(error)")
    }
    do {
        let client = DaemonClient()
        _ = try client.status()
        print("Installed helper: reachable")
        let metrics = try client.performance()
        print("Detailed CPU clocks: \(metrics.perCoreMHz.count) cores, \(metrics.clusterMHz.count) clusters")
        print("GPU frequency: \(metrics.gpuMHz.map { String(format: "%.0f MHz", $0) } ?? "unavailable")")
        print("CPU / GPU / ANE power: \([metrics.cpuPowerW, metrics.gpuPowerW, metrics.anePowerW].map { $0.map { String(format: "%.2f W", $0) } ?? "unavailable" }.joined(separator: " / "))")
    } catch {
        print("Helper telemetry unavailable: \(error)")
    }
    print("Manual fan writes, physical RPM response, sleep/wake, and login launch require an on-device check.")
}

// MARK: - Main

switch args.first {
case "daemon":
    requireRoot("daemon")
    do {
        let server = try DaemonServer(fanControl: try FanControl())
        server.run()
    } catch {
        fail("daemon failed to start: \(error)")
    }

case "install":
    install()

case "uninstall":
    uninstall()

case "status", nil:
    printStatus()

case "diagnose":
    diagnose()

case "performance":
    do {
        let snapshot = try DaemonClient().performance()
        let data = try JSONEncoder().encode(snapshot)
        print(String(data: data, encoding: .utf8) ?? "{}")
    } catch { fail("\(error)") }

case "set":
    guard args.count >= 2, let rpm = Float(args[1]) else { fail("usage: macfan set <rpm>") }
    do { try DaemonClient().setAll(rpm: rpm); print("ok") } catch { fail("\(error)") }

case "setfan":
    guard args.count >= 3, let index = Int(args[1]), let rpm = Float(args[2]) else {
        fail("usage: macfan setfan <index> <rpm>")
    }
    do { try DaemonClient().setFan(index, rpm: rpm); print("ok") } catch { fail("\(error)") }

case "auto":
    do { try DaemonClient().auto(); print("ok") } catch { fail("\(error)") }

case "max":
    do { try DaemonClient().max(); print("ok") } catch { fail("\(error)") }

case let cmd?:
    fail("unknown command '\(cmd)'. Commands: install, uninstall, daemon, status, diagnose, performance, set, setfan, auto, max")
}
