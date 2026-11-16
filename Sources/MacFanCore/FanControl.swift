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
    case invalidValue(String)

    public var description: String {
        switch self {
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .invalidValue(let detail):
            return detail
        case .writeFailed(let key):
            return "Failed to write or confirm SMC key: \(key)."
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
    private let smc: SMCIO
    private let pause: (TimeInterval) -> Void
    private var modeKeys: [Int: String] = [:]
    private var presentSensors: [(key: String, type: String)]?
    private var cachedLimits: [Int: (min: Float, max: Float)] = [:]

    public convenience init() throws {
        guard let connection = SMCConnection() else {
            throw MacFanError.smcConnectionFailed
        }
        self.init(smc: connection)
    }

    // Injectable transport lets tests exercise M1 Pro firmware behavior without
    // changing the fans on the computer running the test suite.
    init(smc: SMCIO, pause: @escaping (TimeInterval) -> Void = Thread.sleep) {
        self.smc = smc
        self.pause = pause
    }

    public func fanCount() throws -> Int {
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, result.bytes.count == 1, result.bytes[0] <= 10 else {
            throw MacFanError.readFailed(SMCFanKey.count)
        }
        return Int(result.bytes[0])
    }

    private func validateFan(_ index: Int) throws {
        guard index >= 0, index < (try fanCount()) else {
            throw MacFanError.invalidValue("No fan \(index)")
        }
    }

    private func modeKey(_ index: Int) throws -> String {
        if let key = modeKeys[index] { return key }
        for template in [SMCFanKey.modeLower, SMCFanKey.modeUpper] {
            let key = SMCFanKey.key(template, fan: index)
            if let info = smc.getKeyInfo(key), info.size == 1, info.type == "ui8 " {
                let value = smc.readKey(key)
                if value.success, value.bytes.count == 1 {
                    modeKeys[index] = key
                    return key
                }
            }
        }
        throw MacFanError.readFailed("fan \(index) mode (F\(index)Md/F\(index)md)")
    }

    private func modeValue(_ index: Int) throws -> UInt8 {
        let key = try modeKey(index)
        let result = smc.readKey(key)
        guard result.success, result.bytes.count == 1 else { throw MacFanError.readFailed(key) }
        return result.bytes[0]
    }

    public func fanInfo(_ index: Int) throws -> FanInfo {
        try validateFan(index)
        let actual = try readFanFloat(index, template: SMCFanKey.actual)
        let target = try readFanFloat(index, template: SMCFanKey.target)
        let limits: (min: Float, max: Float)
        if let cached = cachedLimits[index] {
            limits = cached
        } else {
            limits = (try readFanFloat(index, template: SMCFanKey.minimum),
                      try readFanFloat(index, template: SMCFanKey.maximum))
            guard limits.max > 0, limits.max >= limits.min else {
                throw MacFanError.invalidValue("Invalid RPM limits for fan \(index)")
            }
            cachedLimits[index] = limits
        }

        let value = try modeValue(index)
        let mode: String
        switch value {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown(\(value))"
        }
        return FanInfo(index: index, actualRPM: actual, targetRPM: target,
                       minRPM: limits.min, maxRPM: limits.max, mode: mode)
    }

    /// M1 Pro accepts a direct mode write. Use the global diagnostic unlock
    /// only if firmware rejects that path, and verify every mode transition.
    private func unlockFan(_ index: Int) throws {
        let key = try modeKey(index)
        if smc.writeKey(key, bytes: [1]), try modeValue(index) == 1 { return }

        guard let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size == 1,
              info.type == "ui8 ", smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
            throw MacFanError.unlockFailed("Fan \(index) rejected manual mode")
        }
        // Bound the fallback so a failed unlock cannot starve safety checks.
        for _ in 0..<50 {
            pause(0.1)
            if smc.writeKey(key, bytes: [1]), try modeValue(index) == 1 { return }
        }
        throw MacFanError.unlockFailed("Timed out setting fan \(index) to manual mode")
    }

    public func setSpeed(fan index: Int, rpm: Float) throws {
        guard rpm.isFinite, rpm >= 0 else {
            throw MacFanError.invalidValue("RPM must be a finite, nonnegative number")
        }
        let info = try fanInfo(index)
        let target = min(max(rpm, info.minRPM), info.maxRPM)
        do {
            if info.mode != "manual" { try unlockFan(index) }
            let key = SMCFanKey.key(SMCFanKey.target, fan: index)
            guard smc.writeKey(key, bytes: floatToSMCBytes(target)) else {
                throw MacFanError.writeFailed(key)
            }
            try confirmTarget(target, fan: index)
        } catch {
            // Includes partial unlocks: never leave Ftst enabled after failure.
            try? resetAuto()
            throw error
        }
    }

    /// M5 firmware acknowledges a target write before its readback updates
    /// (about 200 ms on hardware). Wait at most one second without rewriting
    /// the target; a persistent mismatch still triggers setSpeed's rollback.
    private func confirmTarget(_ target: Float, fan index: Int) throws {
        let key = SMCFanKey.key(SMCFanKey.target, fan: index)
        for attempt in 0...10 {
            let actualTarget = try readFanFloat(index, template: SMCFanKey.target)
            guard try modeValue(index) == 1 else { throw MacFanError.writeFailed(key) }
            if abs(actualTarget - target) <= 1 { return }
            if attempt < 10 { pause(0.1) }
        }
        throw MacFanError.writeFailed(key)
    }

    public func setAllFans(rpm: Float) throws {
        do {
            for i in 0..<(try fanCount()) { try setSpeed(fan: i, rpm: rpm) }
        } catch {
            try? resetAuto()
            throw error
        }
    }

    public func setMax() throws {
        do {
            for i in 0..<(try fanCount()) {
                try setSpeed(fan: i, rpm: fanInfo(i).maxRPM)
            }
        } catch {
            try? resetAuto()
            throw error
        }
    }

    private func releaseFan(_ index: Int) throws {
        let key = try modeKey(index)
        // System mode (3) already belongs to Apple and may reject a mode write.
        let value = try modeValue(index)
        if value == 0 || value == 3 { return }
        guard smc.writeKey(key, bytes: [0]) else { throw MacFanError.writeFailed(key) }
        let after = try modeValue(index)
        guard after == 0 || after == 3 else { throw MacFanError.writeFailed(key) }
        // The target is ignored in auto mode. Do not write a zero target after
        // releasing the fan: firmware may reject it once Apple owns the fan.
    }

    private func clearUnlock() throws {
        guard let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size == 1 else { return }
        let current = smc.readKey(SMCFanKey.forceTest)
        if current.success, current.bytes == [0] { return }
        guard smc.writeKey(SMCFanKey.forceTest, bytes: [0]) else {
            throw MacFanError.writeFailed(SMCFanKey.forceTest)
        }
        let after = smc.readKey(SMCFanKey.forceTest)
        guard after.success, after.bytes == [0] else {
            throw MacFanError.writeFailed(SMCFanKey.forceTest)
        }
    }

    public func resetAutoFan(_ index: Int) throws {
        try validateFan(index)
        try releaseFan(index)
        // Do not release the global unlock while another fan needs it.
        for i in 0..<(try fanCount()) {
            if try modeValue(i) == 1 { return }
        }
        try clearUnlock()
    }

    public func resetAuto() throws {
        var firstError: Error?
        do {
            for i in 0..<(try fanCount()) {
                do { try releaseFan(i) } catch { if firstError == nil { firstError = error } }
            }
        } catch { firstError = error }
        // Even if one fan failed, resume Apple's thermal policy and attempt all
        // releases. Report the failure so the daemon can retry next tick.
        do { try clearUnlock() } catch { if firstError == nil { firstError = error } }
        if let error = firstError { throw error }
    }

    public func status() throws -> ThermalStatus {
        let fans = try (0..<fanCount()).map { try fanInfo($0) }
        return ThermalStatus(fans: fans, temperatures: readTemperatures())
    }

    public func readTemperatures() -> [String: Float] {
        if presentSensors == nil || presentSensors?.isEmpty == true {
            presentSensors = (SensorCatalog.floatKeys + SensorCatalog.ioftKeys).compactMap { key in
                guard let info = smc.getKeyInfo(key),
                      ["flt ", "sp78", "ioft"].contains(info.type) else { return nil }
                return (key, info.type)
            }
        }
        var temps: [String: Float] = [:]
        for sensor in presentSensors ?? [] {
            let result = smc.readKey(sensor.key)
            if result.success, let temp = smcNumber(result.bytes, type: sensor.type),
               temp > 0, temp < 150 {
                temps[sensor.key] = (temp * 10).rounded() / 10
            }
        }
        return temps
    }

    private func readFanFloat(_ fan: Int, template: String) throws -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard let info = smc.getKeyInfo(key), info.type == "flt ",
              result.success, let value = smcNumber(result.bytes, type: info.type), value >= 0 else {
            throw MacFanError.readFailed(key)
        }
        return value
    }
}
