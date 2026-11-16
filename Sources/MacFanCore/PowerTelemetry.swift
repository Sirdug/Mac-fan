import Foundation

/// Read-only SMC channels. Apple Silicon integer battery keys are little-endian;
/// their units differ from the floating-point system/adapter keys (watts).
public struct LivePowerSample {
    public var systemW: Double?
    public var adapterW: Double?
    public var batteryW: Double?
    public var batteryCurrentMA: Double?

    public init(systemW: Double? = nil, adapterW: Double? = nil,
                batteryW: Double? = nil, batteryCurrentMA: Double? = nil) {
        self.systemW = systemW
        self.adapterW = adapterW
        self.batteryW = batteryW
        self.batteryCurrentMA = batteryCurrentMA
    }
}

public final class PowerSensorReader {
    private let smc: SMCIO?

    public init() { smc = SMCConnection() }
    init(smc: SMCIO) { self.smc = smc }

    public func sample() -> LivePowerSample {
        let voltage = read("B0AV", type: "ui16", size: 2)
        let current = read("B0AC", type: "si16", size: 2)
        let batteryMW = read("B0AP", type: "si32", size: 4)
        let batteryW = batteryMW.map { $0 / 1_000 }
            ?? voltage.flatMap { v in current.map { v * $0 / 1_000_000 } }
        return LivePowerSample(
            systemW: read("PSTR", type: "flt ", size: 4),
            adapterW: read("PDTR", type: "flt ", size: 4),
            batteryW: batteryW,
            batteryCurrentMA: current
        )
    }

    private func read(_ key: String, type: String, size: UInt32) -> Double? {
        guard let smc, let info = smc.getKeyInfo(key),
              info.type == type, info.size == size else { return nil }
        let raw = smc.readKey(key)
        guard raw.success, raw.size == size, raw.bytes.count == Int(size) else { return nil }
        let bits = raw.bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        let value: Double
        switch type {
        case "flt ": value = Double(Float(bitPattern: bits))
        case "ui16": value = Double(UInt16(truncatingIfNeeded: bits))
        case "si16": value = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: bits)))
        case "si32": value = Double(Int32(bitPattern: bits))
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}

public enum SystemPowerSource: String {
    case sensor = "Live sensor"
    case battery = "Battery draw"
    case balance = "Input − battery"
    case controller = "Controller estimate"
    case unavailable = "Unavailable"
}

public enum BatteryEstimateSource: String {
    case macOS = "macOS estimate"
    case controller = "Battery controller estimate"
    case recentUsage = "Based on recent usage"
}

/// Calculation layer kept independent of IOKit so missing, stale and signed
/// telemetry can be exercised without changing the machine's power state.
public struct PowerReading {
    public var systemW: Double?
    public var systemSource: SystemPowerSource = .unavailable
    public var wallW: Double?
    public var batteryW: Double?
    public var currentMA: Double?
    public var batteryPercent: Int?
    public var remainingMAh: Double?
    public var adapterConnected: Bool
    public var isCharging: Bool
    public var isFullyCharged: Bool
    public var controllerMinutes: Int?

    public init(properties p: [String: Any], live: LivePowerSample = .init()) {
        adapterConnected = (p["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        isCharging = adapterConnected && ((p["IsCharging"] as? NSNumber)?.boolValue ?? false)
        isFullyCharged = (p["FullyCharged"] as? NSNumber)?.boolValue ?? false
        let telemetry = p["PowerTelemetryData"] as? [String: Any] ?? [:]
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        if let current = Self.number(p["CurrentCapacity"]),
           let maximum = Self.number(p["MaxCapacity"]), maximum > 0, current >= 0 {
            batteryPercent = Int(min(100, current / maximum * 100).rounded())
        }
        remainingMAh = Self.bounded(Self.number(data["RemainingCapacity"]), 0...30_000)
            ?? Self.bounded(Self.number(p["AppleRawCurrentCapacity"]), 0...30_000)
            ?? Self.bounded(Self.number(data["AppleRawCurrentCapacity"]), 0...30_000)

        currentMA = Self.bounded(live.batteryCurrentMA, -30_000...30_000)
            ?? Self.bounded(Self.signed(p["InstantAmperage"]), -30_000...30_000)
            ?? Self.bounded(Self.signed(p["Amperage"]), -30_000...30_000)
        let registryW = Self.bounded(Self.number(p["Voltage"]), 5_000...30_000).flatMap { voltage in
            // Keep voltage/current from the same registry snapshot together.
            (Self.bounded(Self.signed(p["InstantAmperage"]), -30_000...30_000)
                ?? Self.bounded(Self.signed(p["Amperage"]), -30_000...30_000))
                .map { voltage * $0 / 1_000_000 }
        }
        batteryW = Self.bounded(live.batteryW, -300...300)
            ?? Self.bounded(registryW, -300...300)
            ?? Self.bounded(Self.signed(telemetry["BatteryPower"]).map { $0 / 1_000 }, -300...300)
        // Positive charging values can linger briefly after unplugging.
        if !adapterConnected, let watts = batteryW, watts > 0 { batteryW = nil }

        if let watts = Self.bounded(live.systemW, 0.01...500) {
            systemW = watts
            systemSource = .sensor
        } else if !adapterConnected, let watts = batteryW, watts <= 0 {
            systemW = -watts
            systemSource = .battery
        } else if adapterConnected,
                  let input = Self.bounded(live.adapterW, 0...500),
                  let battery = Self.bounded(live.batteryW, -300...300),
                  let watts = Self.bounded(input - battery, 0...500) {
            systemW = watts
            systemSource = .balance
        } else if let watts = Self.bounded(Self.number(telemetry["SystemLoad"]).map { $0 / 1_000 }, 0.01...500) {
            systemW = watts
            systemSource = .controller
        }
        // Wall power is only an estimate. Do not label DC adapter output as
        // AC consumption when the loss channel is missing or invalid.
        if adapterConnected,
           let input = Self.bounded(Self.number(telemetry["SystemPowerIn"]), 1...500_000),
           let loss = Self.bounded(Self.number(telemetry["AdapterEfficiencyLoss"]), 0...(input * 0.5)) {
            wallW = (input + loss) / 1_000
        }
        if isCharging {
            controllerMinutes = Self.validMinutes(Self.number(p["AvgTimeToFull"]))
                ?? Self.validMinutes(Self.number(p["TimeRemaining"]))
        }
    }

    public static func validMinutes(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value > 0, value < 65_535 else { return nil }
        return max(1, Int(value.rounded()))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func signed(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return Double(Int64(bitPattern: n.uint64Value))
    }

    private static func bounded(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
}

public struct BatteryTimeEstimate {
    public let minutes: Int
    public let source: BatteryEstimateSource
}

public struct BatteryTimeEstimator {
    private var mode: String?
    private var lastTime: TimeInterval?
    private var averageCurrent: Double?

    public init() {}

    public mutating func update(_ reading: PowerReading, osSeconds: Double,
                                now: TimeInterval) -> BatteryTimeEstimate? {
        let newMode = "\(reading.adapterConnected)-\(reading.isCharging)-\(reading.isFullyCharged)"
        let elapsed = lastTime.map { now - $0 }
        if mode != newMode || elapsed.map({ $0 <= 0 || $0 > 30 }) == true {
            averageCurrent = nil
        }
        mode = newMode
        lastTime = now
        if let current = reading.currentMA, current < -50 {
            let alpha = 1 - exp(-max(0, elapsed ?? 0) / 60)
            averageCurrent = averageCurrent.map { $0 + alpha * (current - $0) } ?? current
        } else {
            averageCurrent = nil
        }

        if reading.adapterConnected && reading.isFullyCharged { return nil }
        if reading.isCharging {
            return reading.controllerMinutes.map { .init(minutes: $0, source: .controller) }
        }
        // A paused/limited charge is not a countdown to empty or full.
        guard !reading.adapterConnected else { return nil }
        // IOPSGetTimeRemainingEstimate returns seconds; -1/-2 are sentinels.
        if let minutes = PowerReading.validMinutes(osSeconds / 60) {
            return .init(minutes: minutes, source: .macOS)
        }
        guard let capacity = reading.remainingMAh, capacity > 0,
              let current = averageCurrent,
              let minutes = PowerReading.validMinutes(capacity / -current * 60) else { return nil }
        return .init(minutes: minutes, source: .recentUsage)
    }
}
