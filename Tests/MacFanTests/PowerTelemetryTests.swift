import Foundation
import Testing
@testable import MacFanCore

@Suite struct PowerTelemetryTests {
    private func battery(_ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = [
            "ExternalConnected": false, "IsCharging": false,
            "CurrentCapacity": 60, "MaxCapacity": 100,
            "Voltage": 12_000, "InstantAmperage": -1_000,
            "AvgTimeToEmpty": 90, "TimeRemaining": 90,
            "BatteryData": ["RemainingCapacity": 3_000, "FullChargeCapacity": 5_000],
            "PowerTelemetryData": ["SystemLoad": 39_000, "BatteryPower": -39_000]
        ]
        p.merge(extra) { _, new in new }
        return p
    }

    @Test func liveSensorsWinOverStaleRegistryChannels() {
        let r = PowerReading(properties: battery(), live: .init(systemW: 14, batteryW: -15))
        #expect(r.systemW == 14)
        #expect(r.systemSource == .sensor)
        #expect(r.batteryW == -15)
        #expect(r.wallW == nil)
        #expect(r.batteryPercent == 60)
    }

    @Test func dischargeFallbackUsesVoltageAndCurrent() {
        let r = PowerReading(properties: battery())
        #expect(r.batteryW == -12)
        #expect(r.systemW == 12)
        #expect(r.systemSource == .battery)
    }

    @Test func chargingPowerIsNeverUsedAsWholeSystemPower() {
        let p: [String: Any] = ["ExternalConnected": true, "IsCharging": true,
                               "Voltage": 12_000, "Amperage": 2_000]
        let r = PowerReading(properties: p)
        #expect(r.batteryW == 24)
        #expect(r.systemW == nil)
        #expect(r.wallW == nil)
        let withInput = PowerReading(properties: p, live: .init(adapterW: 60, batteryW: 24))
        #expect(withInput.systemW == 36)
    }

    @Test func adapterCanBeSupplementedByBattery() {
        let r = PowerReading(properties: ["ExternalConnected": true],
                             live: .init(adapterW: 60, batteryW: -20))
        #expect(r.systemW == 80)
        #expect(r.batteryW == -20)
    }

    @Test func wallRequiresLossEstimateAndAdapter() {
        let channels: [String: Any] = ["SystemPowerIn": 60_000, "AdapterEfficiencyLoss": 4_000]
        #expect(PowerReading(properties: battery(["ExternalConnected": true,
                    "PowerTelemetryData": channels])).wallW == 64)
        #expect(PowerReading(properties: battery(["PowerTelemetryData": channels])).wallW == nil)
        #expect(PowerReading(properties: battery(["ExternalConnected": true,
                    "PowerTelemetryData": ["SystemPowerIn": 60_000]])).wallW == nil)
        #expect(PowerReading(properties: battery(["ExternalConnected": true,
                    "PowerTelemetryData": ["SystemPowerIn": 60_000,
                                           "AdapterEfficiencyLoss": Double.infinity]])).wallW == nil)
    }

    @Test func unsignedRegistryCurrentIsDecodedAsSigned() {
        let r = PowerReading(properties: battery([
            "InstantAmperage": NSNumber(value: UInt64(bitPattern: -1_000))
        ]))
        #expect(r.batteryW == -12)
    }

    @Test func invalidSamplesDoNotProducePlausibleNumbers() {
        let r = PowerReading(properties: [:], live: .init(systemW: .nan, batteryW: .infinity))
        #expect(r.systemW == nil)
        #expect(r.batteryW == nil)
        #expect(r.batteryPercent == nil)
        let unplugged = PowerReading(properties: battery(), live: .init(batteryW: 20))
        #expect(unplugged.batteryW == nil)
        #expect(PowerReading(properties: battery(["CurrentCapacity": 3_000,
                                                "MaxCapacity": 5_000])).batteryPercent == 60)
    }

    @Test func osEstimateUsesSecondsAndDoesNotSwitchToRawControllerAfterFourPolls() {
        var estimator = BatteryTimeEstimator()
        for time in 0..<10 {
            let estimate = estimator.update(PowerReading(properties: battery()),
                                             osSeconds: 9_660, now: Double(time))
            #expect(estimate?.minutes == 161)
            #expect(estimate?.source == .macOS)
        }
    }

    @Test func unknownTimeFallsBackToCapacityAndRecentCurrent() {
        var estimator = BatteryTimeEstimator()
        let r = PowerReading(properties: battery())
        let estimate = estimator.update(r, osSeconds: -1, now: 0)
        #expect(estimate?.minutes == 180)
        #expect(estimate?.source == .recentUsage)
        let missing = estimator.update(PowerReading(properties: [:]), osSeconds: -1, now: 2)
        #expect(missing == nil)
    }

    @Test func chargingAndPausedChargingDoNotShowDischargeCountdown() {
        var estimator = BatteryTimeEstimator()
        let paused = PowerReading(properties: battery(["ExternalConnected": true]))
        #expect(estimator.update(paused, osSeconds: 9_660, now: 0) == nil)
        let charging = PowerReading(properties: battery(["ExternalConnected": true,
                        "IsCharging": true, "AvgTimeToFull": 65_535, "TimeRemaining": 45]))
        let estimate = estimator.update(charging, osSeconds: -2, now: 2)
        #expect(estimate?.minutes == 45)
        #expect(estimate?.source == .controller)
        let full = PowerReading(properties: battery(["ExternalConnected": true,
                "FullyCharged": true, "IsCharging": true, "AvgTimeToFull": 45]))
        #expect(estimator.update(full, osSeconds: -2, now: 4) == nil)
    }

    @Test func sleepAndPowerTransitionsResetRecentUsage() {
        var estimator = BatteryTimeEstimator()
        let low = PowerReading(properties: battery(), live: .init(batteryCurrentMA: -1_000))
        let high = PowerReading(properties: battery(), live: .init(batteryCurrentMA: -3_000))
        _ = estimator.update(low, osSeconds: -1, now: 0)
        #expect((estimator.update(high, osSeconds: -1, now: 2)?.minutes ?? 0) > 150)
        #expect(estimator.update(high, osSeconds: -1, now: 100)?.minutes == 60)
        _ = estimator.update(PowerReading(properties: battery(["ExternalConnected": true])), osSeconds: -2, now: 102)
        #expect(estimator.update(low, osSeconds: -1, now: 104)?.minutes == 180)
    }

    @Test func minuteSentinelsAreRejected() {
        for value in [0.0, -1, -2, 65_535, .infinity, .nan] {
            #expect(PowerReading.validMinutes(value) == nil)
        }
        #expect(PowerReading.validMinutes(0.1) == 1)
    }

    @Test func smcDecodesObservedAppleSiliconBytesWithoutWriting() {
        let smc = PowerSMCStub()
        smc.keys = [
            "PSTR": ("flt ", floatToSMCBytes(33.5)),
            "PDTR": ("flt ", floatToSMCBytes(0)),
            "B0AV": ("ui16", [0x78, 0x2d]), // 11,640 mV
            "B0AC": ("si16", [0x48, 0xf3]), // -3,256 mA
            "B0AP": ("si32", [0xf5, 0x6b, 0xff, 0xff]), // -37,899 mW
        ]
        let reader = PowerSensorReader(smc: smc)
        let r = reader.sample()
        #expect(r.systemW == 33.5)
        #expect(r.batteryW == -37.899)
        #expect(r.batteryCurrentMA == -3_256)
        smc.keys.removeValue(forKey: "B0AP")
        #expect(abs((reader.sample().batteryW ?? 0) - (-37.89984)) < 0.00001)
        smc.keys["PSTR"] = ("ui32", [0, 0, 0, 0])
        #expect(reader.sample().systemW == nil)
        #expect(smc.writeCount == 0)
    }
}

private final class PowerSMCStub: SMCIO {
    var keys: [String: (String, [UInt8])] = [:]
    var writeCount = 0
    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        guard let (_, bytes) = keys[key] else { return (false, [], 0) }
        return (true, bytes, UInt32(bytes.count))
    }
    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        writeCount += 1
        return false
    }
    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        keys[key].map { (UInt32($0.1.count), $0.0) }
    }
}
