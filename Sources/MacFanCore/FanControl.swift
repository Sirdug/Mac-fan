//
//  FanControl.swift
//  Mac Fan
//
//  Core fan operations: unlock, per-fan set speed, reset, status.
//  Adapted from ThermalForge (MIT, github.com/ProducerGuy/ThermalForge)
//  with per-fan auto/manual control added.
//

import Foundation

// MARK: - Types

public enum MacFanError: Error, CustomStringConvertible {
    case smcConnectionFailed
    case unlockFailed(String)
    case readFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .writeFailed(let key):
            return "Failed to write SMC key: \(key). Run as root."
        }
    }
}

public struct FanInfo: Codable, Equatable {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: String

    public init(index: Int, actualRPM: Float, targetRPM: Float,
                minRPM: Float, maxRPM: Float, mode: String) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
    }
}

public struct ThermalStatus: Codable, Equatable {
    public let fans: [FanInfo]
    public let temperatures: [String: Float]

    public init(fans: [FanInfo], temperatures: [String: Float]) {
        self.fans = fans
        self.temperatures = temperatures
    }
}

// MARK: - Fan Control

public final class FanControl {
    private let smc: SMCConnection
    /// Which mode key works on this hardware (detected at init)
    private let modeKeyTemplate: String
    /// Whether Ftst unlock is available (M1-M4) or not (M5+)
    private let hasFtst: Bool
    /// Sensor keys that exist on this machine — probed once, then only
    /// these are read (absent keys otherwise cost IOKit calls every poll)
    private var presentFloatKeys: [String]?
    private var presentIoftKeys: [String]?
    /// Hardware fan RPM limits are constants — read once per fan
    private var cachedLimits: [Int: (min: Float, max: Float)] = [:]

    public init() throws {
        guard let connection = SMCConnection() else {
            throw MacFanError.smcConnectionFailed
        }
        self.smc = connection

        // Detect hardware: M5 family uses F%dmd (lowercase), M1-M4 use F%dMd
        let lowerResult = smc.readKey(SMCFanKey.key(SMCFanKey.modeLower, fan: 0))
        self.modeKeyTemplate = lowerResult.success ? SMCFanKey.modeLower : SMCFanKey.modeUpper

        // Ftst exists on M1-M4 only
        if let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size > 0 {
            self.hasFtst = true
        } else {
            self.hasFtst = false
        }
    }

    // MARK: - Read

    public func fanCount() throws -> Int {
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, !result.bytes.isEmpty else {
            throw MacFanError.readFailed(SMCFanKey.count)
        }
        return Int(result.bytes[0])
    }

    public func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)

        let minimum: Float
        let maximum: Float
        if let limits = cachedLimits[index] {
            (minimum, maximum) = limits
        } else {
            minimum = readFanFloat(index, template: SMCFanKey.minimum)
            maximum = readFanFloat(index, template: SMCFanKey.maximum)
            if minimum > 0 || maximum > 0 {
                cachedLimits[index] = (minimum, maximum)
            }
        }

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let modeResult = smc.readKey(modeKey)
        let modeValue = modeResult.success && !modeResult.bytes.isEmpty ? modeResult.bytes[0] : 0
        let mode: String
        switch modeValue {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown(\(modeValue))"
        }

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: minimum,
            maxRPM: maximum,
            mode: mode
        )
    }

    // MARK: - Unlock

    /// Put a single fan into manual mode.
    /// On M1-M4 this first writes Ftst=1 (suppresses thermalmonitord),
    /// then polls the mode key until the write sticks.
    private func unlockFan(_ index: Int) throws {
        if hasFtst {
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw MacFanError.unlockFailed("Failed to write Ftst=1. Run as root.")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let deadline = Date().addingTimeInterval(10.0)

        while Date() < deadline {
            if smc.writeKey(modeKey, bytes: [1]) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw MacFanError.unlockFailed("Timed out setting fan \(index) to manual mode. Run as root.")
    }

    // MARK: - Set Speed

    /// Set a single fan to a specific RPM (clamped to the hardware's min/max range).
    public func setSpeed(fan index: Int, rpm: Float) throws {
        let info = try fanInfo(index)

        var rpm = rpm
        if info.minRPM > 0 { rpm = max(rpm, info.minRPM) }
        if info.maxRPM > 0 { rpm = min(rpm, info.maxRPM) }

        if info.mode != "manual" {
            try unlockFan(index)
        }

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
            throw MacFanError.writeFailed(targetKey)
        }
    }

    /// Set all fans to a specific RPM.
    public func setAllFans(rpm: Float) throws {
        for i in 0..<(try fanCount()) {
            try setSpeed(fan: i, rpm: rpm)
        }
    }

    /// Set all fans to their maximum RPM.
    public func setMax() throws {
        for i in 0..<(try fanCount()) {
            let info = try fanInfo(i)
            let maxRPM = info.maxRPM > 0 ? info.maxRPM : 7826
            try setSpeed(fan: i, rpm: maxRPM)
        }
    }

    // MARK: - Reset

    /// Return a single fan to Apple's automatic control.
    /// Clears Ftst once no fan remains in manual mode.
    public func resetAutoFan(_ index: Int) throws {
        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        _ = smc.writeKey(modeKey, bytes: [0])

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        _ = smc.writeKey(targetKey, bytes: floatToSMCBytes(0))

        if hasFtst {
            let count = (try? fanCount()) ?? 0
            let anyManual = (0..<count).contains { i in
                (try? fanInfo(i).mode) == "manual"
            }
            if !anyManual {
                _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
            }
        }
    }

    /// Reset all fans to Apple defaults (auto mode, thermalmonitord resumes).
    public func resetAuto() throws {
        let count = try fanCount()

        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            _ = smc.writeKey(modeKey, bytes: [0])

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            _ = smc.writeKey(targetKey, bytes: floatToSMCBytes(0))
        }

        if hasFtst {
            _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
        }
    }

    // MARK: - Status

    /// Read current fan state and all available temperatures.
    public func status() throws -> ThermalStatus {
        let count = try fanCount()
        var fans: [FanInfo] = []
        for i in 0..<count {
            fans.append(try fanInfo(i))
        }
        return ThermalStatus(fans: fans, temperatures: readTemperatures())
    }

    /// Read all temperature sensors present on this machine.
    /// The full catalog is probed exactly once; subsequent calls only touch
    /// keys that actually exist.
    public func readTemperatures() -> [String: Float] {
        if presentFloatKeys == nil {
            presentFloatKeys = SensorCatalog.floatKeys.filter { key in
                smc.getKeyInfo(key)?.size == 4
            }
            presentIoftKeys = SensorCatalog.ioftKeys.filter { key in
                smc.getKeyInfo(key)?.size == 8
            }
        }

        var temps: [String: Float] = [:]

        for key in presentFloatKeys ?? [] {
            let result = smc.readKey(key)
            if result.success && result.size == 4 {
                let temp = smcBytesToFloat(result.bytes, size: result.size)
                if temp > 0 && temp < 150 {
                    temps[key] = (temp * 10).rounded() / 10
                }
            }
        }

        for key in presentIoftKeys ?? [] {
            let result = smc.readKey(key)
            if result.success && result.size == 8 {
                let temp = ioftBytesToFloat(result.bytes)
                if temp > 0 && temp < 150 {
                    temps[key] = (temp * 10).rounded() / 10
                }
            }
        }

        return temps
    }

    // MARK: - Private

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success else { return 0 }
        return smcBytesToFloat(result.bytes, size: result.size)
    }
}
