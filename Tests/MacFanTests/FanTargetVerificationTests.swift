import Foundation
import Testing
@testable import MacFanCore

/// Models M5 firmware that accepts target writes before exposing the new value.
/// Only the injected pause advances firmware, so these tests never sleep or
/// communicate with the real SMC.
private final class DelayedTargetSMC: SMCIO {
    let backing = TestSMC(lowercase: true, ftst: false)
    var delayByFan: [Int: Int] = [0: 2, 1: 3]
    var ignoredTargets: Set<Int> = []
    var revertModeOnNextPause: Int?
    var pauses: [TimeInterval] = []
    private var pending: [String: (bytes: [UInt8], pausesLeft: Int)] = [:]

    init() {
        backing.ignoredKeys = ["F0Tg", "F1Tg"]
    }

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        backing.readKey(key)
    }

    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        backing.getKeyInfo(key)
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        guard backing.writeKey(key, bytes: bytes) else { return false }
        for fan in 0..<2 where key == "F\(fan)Tg" {
            if !ignoredTargets.contains(fan) {
                pending[key] = (bytes, delayByFan[fan] ?? 2)
            }
        }
        return true
    }

    func advance(_ interval: TimeInterval) {
        pauses.append(interval)
        if let fan = revertModeOnNextPause {
            backing.values["F\(fan)md"] = [0]
            revertModeOnNextPause = nil
        }
        for key in Array(pending.keys) {
            guard var write = pending[key] else { continue }
            write.pausesLeft -= 1
            if write.pausesLeft == 0 {
                backing.values[key] = write.bytes
                pending.removeValue(forKey: key)
            } else {
                pending[key] = write
            }
        }
    }

    func targetWriteCount(_ fan: Int) -> Int {
        backing.writes.filter { $0.0 == "F\(fan)Tg" }.count
    }
}

@Suite struct FanTargetVerificationTests {
    @Test func delayedM5TargetConvergesWithoutRewritingOrUnlocking() throws {
        let smc = DelayedTargetSMC()
        let fans = FanControl(smc: smc, pause: smc.advance)

        try fans.setSpeed(fan: 0, rpm: 3000)

        #expect(try fans.fanInfo(0).targetRPM == 3000)
        #expect(try fans.fanInfo(0).mode == "manual")
        #expect(smc.pauses == [0.1, 0.1])
        #expect(smc.targetWriteCount(0) == 1)
        #expect(smc.backing.writes.filter { $0.0 == "F0md" }.count == 1)
        #expect(!smc.backing.writes.contains { $0.0 == "Ftst" })
    }

    @Test func sequentialFansEachWaitForTheirOwnTarget() throws {
        let smc = DelayedTargetSMC()
        let fans = FanControl(smc: smc, pause: smc.advance)

        try fans.setAllFans(rpm: 3500)

        #expect(try fans.status().fans.allSatisfy {
            $0.mode == "manual" && $0.targetRPM == 3500
        })
        #expect(smc.pauses.count == 5)
        #expect(smc.targetWriteCount(0) == 1)
        #expect(smc.targetWriteCount(1) == 1)
        #expect(!smc.backing.writes.contains { $0.0 == "Ftst" })
    }

    @Test func targetCanConvergeOnLastPermittedPoll() throws {
        let smc = DelayedTargetSMC()
        smc.delayByFan[0] = 10
        let fans = FanControl(smc: smc, pause: smc.advance)

        try fans.setSpeed(fan: 0, rpm: 3000)

        #expect(try fans.fanInfo(0).targetRPM == 3000)
        #expect(smc.pauses.count == 10)
        #expect(smc.targetWriteCount(0) == 1)
    }

    @Test func ignoredTargetTimesOutAndReturnsBothFansToApple() throws {
        let smc = DelayedTargetSMC()
        smc.ignoredTargets = [1]
        let fans = FanControl(smc: smc, pause: smc.advance)
        try fans.setSpeed(fan: 0, rpm: 3000)
        smc.pauses.removeAll()

        #expect(throws: MacFanError.self) { try fans.setSpeed(fan: 1, rpm: 3000) }

        #expect(smc.pauses.count == 10)
        #expect(abs(smc.pauses.reduce(0, +) - 1) < 0.0001)
        #expect(try fans.status().fans.allSatisfy { $0.mode == "auto" })
        #expect(smc.targetWriteCount(1) == 1)
        #expect(!smc.backing.writes.contains { $0.0 == "Ftst" })
    }

    @Test func targetConvergenceDoesNotHideLossOfManualMode() throws {
        let smc = DelayedTargetSMC()
        let fans = FanControl(smc: smc, pause: smc.advance)
        try fans.setSpeed(fan: 1, rpm: 3000)
        smc.pauses.removeAll()
        smc.revertModeOnNextPause = 0

        #expect(throws: MacFanError.self) { try fans.setSpeed(fan: 0, rpm: 3000) }

        #expect(smc.pauses.count <= 10)
        #expect(try fans.status().fans.allSatisfy { $0.mode == "auto" })
        #expect(smc.targetWriteCount(0) == 1)
        #expect(!smc.backing.writes.contains { $0.0 == "Ftst" })
    }
}
