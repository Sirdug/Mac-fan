import Foundation
import Testing
@testable import MacFanCore

/// Synthetic M1 Pro transport: two fans with different hardware limits,
/// uppercase mode keys, optional Ftst, and independently injectable failures.
final class TestSMC: SMCIO {
    var values: [String: [UInt8]] = [:]
    var types: [String: String] = [:]
    var writes: [(String, [UInt8])] = []
    var rejectedKeys: Set<String> = []
    var ignoredKeys: Set<String> = []
    var needsUnlock = false

    init(lowercase: Bool = false, ftst: Bool = true) {
        put("FNum", [2], "ui8 ")
        if ftst { put("Ftst", [0], "ui8 ") }
        for i in 0..<2 {
            put("F\(i)\(lowercase ? "md" : "Md")", [0], "ui8 ")
            putFloat("F\(i)Ac", 2000)
            putFloat("F\(i)Tg", 2000)
            putFloat("F\(i)Mn", i == 0 ? 1200 : 1300)
            putFloat("F\(i)Mx", i == 0 ? 5800 : 6240)
        }
        putFloat("Tp01", 45)
        putFloat("Tp09", 40)
        putFloat("Tg05", 42)
        putFloat("Tm02", 35)
        putFloat("TH0A", 32)
        putFloat("TA0P", 25)
        put("TB1T", [30, 128], "sp78")
    }

    func put(_ key: String, _ bytes: [UInt8], _ type: String) {
        values[key] = bytes
        types[key] = type
    }

    func putFloat(_ key: String, _ value: Float) { put(key, floatToSMCBytes(value), "flt ") }

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        guard let bytes = values[key] else { return (false, [], 0) }
        return (true, bytes, UInt32(bytes.count))
    }

    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        guard let bytes = values[key], let type = types[key] else { return nil }
        return (UInt32(bytes.count), type)
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        writes.append((key, bytes))
        guard values[key] != nil, !rejectedKeys.contains(key) else { return false }
        if needsUnlock, key.hasSuffix("Md"), bytes == [1], values["Ftst"] != [1] { return false }
        if !ignoredKeys.contains(key) { values[key] = bytes }
        return true
    }
}

@Suite struct FanControlTests {
    @Test func m1ProUsesDirectManualModeEvenWhenFtstIsReadOnly() throws {
        let smc = TestSMC()
        smc.rejectedKeys = ["Ftst"]
        let fans = FanControl(smc: smc, pause: { _ in })
        try fans.setSpeed(fan: 0, rpm: 3000)
        #expect(try fans.fanInfo(0).mode == "manual")
        #expect(try fans.fanInfo(0).targetRPM == 3000)
        #expect(try fans.fanInfo(1).mode == "auto")
        #expect(!smc.writes.contains { $0.0 == "Ftst" })
        try fans.resetAutoFan(0)
        #expect(try fans.fanInfo(0).mode == "auto")
    }

    @Test func maxUsesEachFansOwnLimitsAndFixedRPMClamps() throws {
        let fans = FanControl(smc: TestSMC(), pause: { _ in })
        try fans.setMax()
        #expect(try fans.fanInfo(0).targetRPM == 5800)
        #expect(try fans.fanInfo(1).targetRPM == 6240)
        try fans.setAllFans(rpm: 0)
        #expect(try fans.fanInfo(0).targetRPM == 1200)
        #expect(try fans.fanInfo(1).targetRPM == 1300)
    }

    @Test func lowercaseHardwareWithoutFtstStillWorks() throws {
        let fans = FanControl(smc: TestSMC(lowercase: true, ftst: false), pause: { _ in })
        try fans.setAllFans(rpm: 4000)
        #expect(try fans.status().fans.allSatisfy { $0.mode == "manual" })
        try fans.resetAuto()
        #expect(try fans.status().fans.allSatisfy { $0.mode == "auto" })
    }

    @Test func unlockFallbackPreservesOtherManualFanUntilFinalRelease() throws {
        let smc = TestSMC()
        smc.needsUnlock = true
        let fans = FanControl(smc: smc, pause: { _ in })
        try fans.setAllFans(rpm: 3000)
        #expect(smc.values["Ftst"] == [1])
        try fans.resetAutoFan(0)
        #expect(smc.values["Ftst"] == [1])
        #expect(try fans.fanInfo(1).mode == "manual")
        try fans.resetAutoFan(1)
        #expect(smc.values["Ftst"] == [0])
    }

    @Test func acknowledgedButIgnoredModeWriteIsNotSuccess() throws {
        let smc = TestSMC()
        smc.ignoredKeys = ["F0Md"]
        let fans = FanControl(smc: smc, pause: { _ in })
        #expect(throws: MacFanError.self) { try fans.setSpeed(fan: 0, rpm: 3000) }
        #expect(smc.values["Ftst"] == [0])
        #expect(!smc.writes.contains { $0.0 == "F0Tg" })
    }

    @Test func failedSecondFanWriteRollsBothFansBackToApple() throws {
        let smc = TestSMC()
        smc.rejectedKeys = ["F1Tg"]
        let fans = FanControl(smc: smc, pause: { _ in })
        #expect(throws: MacFanError.self) { try fans.setAllFans(rpm: 3000) }
        #expect(try fans.status().fans.allSatisfy { $0.mode == "auto" })
        #expect(smc.values["Ftst"] == [0])
    }

    @Test func failedResetStillReleasesOtherFanAndGlobalUnlock() throws {
        let smc = TestSMC()
        smc.needsUnlock = true
        let fans = FanControl(smc: smc, pause: { _ in })
        try fans.setAllFans(rpm: 3000)
        smc.rejectedKeys = ["F0Md"]
        #expect(throws: MacFanError.self) { try fans.resetAuto() }
        #expect(try fans.fanInfo(1).mode == "auto")
        #expect(smc.values["Ftst"] == [0])
    }

    @Test func invalidRequestsNeverWriteHardware() throws {
        let smc = TestSMC()
        let fans = FanControl(smc: smc)
        for rpm: Float in [.nan, .infinity, -.infinity, -1] {
            #expect(throws: MacFanError.self) { try fans.setSpeed(fan: 0, rpm: rpm) }
        }
        for index in [-1, 2, 999] {
            #expect(throws: MacFanError.self) { try fans.setSpeed(fan: index, rpm: 3000) }
            #expect(throws: MacFanError.self) { try fans.resetAutoFan(index) }
        }
        #expect(smc.writes.isEmpty)
    }

    @Test func missingOrInvalidMaximumDoesNotUseAnInventedSpeed() throws {
        let smc = TestSMC()
        smc.putFloat("F0Mx", .nan)
        let fans = FanControl(smc: smc)
        #expect(throws: MacFanError.self) { try fans.setMax() }
        #expect(!smc.writes.contains { $0.0 == "F0Tg" })
    }

    @Test func m1TemperatureGroupsIncludeFixedPointBattery() {
        let fans = FanControl(smc: TestSMC())
        let temps = fans.readTemperatures()
        #expect(SensorCatalog.groupedMaxima(temps).count == 6)
        #expect(SensorSource.group(.cpu).resolve(in: temps) == 45)
        #expect(SensorSource.group(.gpu).resolve(in: temps) == 42)
        #expect(SensorSource.group(.battery).resolve(in: temps) == 30.5)
        #expect(SensorSource.key("Tp09").resolve(in: temps) == 40)
    }

    @Test func wrongTypesAndNonfiniteSensorsAreIgnored() {
        let smc = TestSMC()
        smc.put("Tp01", floatToSMCBytes(90), "ui32")
        smc.putFloat("Tp09", .infinity)
        #expect(SensorSource.group(.cpu).resolve(in: FanControl(smc: smc).readTemperatures()) == nil)
    }

    @Test func smcKernelStructureLayoutIsUnchanged() {
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.bytes) == 48)
    }
}
