import Foundation
import Testing
@testable import MacFanCore

@Suite struct DaemonSafetyTests {
    private func server(_ smc: TestSMC) throws -> DaemonServer {
        try DaemonServer(fanControl: FanControl(smc: smc, pause: { _ in }),
                         socketPath: "/tmp/macfan-test-\(UUID().uuidString).sock")
    }

    @Test func watchdogReleasesManualFansAfterLostHeartbeat() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        #expect(daemon.process("set 3000") == "ok")
        daemon.watchdogTick(now: Date().addingTimeInterval(16))
        #expect(smc.values["F0Md"] == [0])
        #expect(smc.values["F1Md"] == [0])
    }

    @Test func sensorLossReleasesFansAndRejectsFixedSpeed() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        #expect(daemon.process("set 3000") == "ok")
        for key in smc.values.keys.filter({ $0.hasPrefix("T") }) { smc.values.removeValue(forKey: key) }
        daemon.watchdogTick()
        #expect(smc.values["F0Md"] == [0])
        #expect(daemon.process("setfan 0 3000").hasPrefix("error:"))
    }

    @Test func failsafeUsesBothHardwareMaximaAndHysteresis() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        smc.putFloat("Tp01", 96)
        daemon.watchdogTick()
        #expect(smcNumber(smc.values["F0Tg"]!, type: "flt ") == 5800)
        #expect(smcNumber(smc.values["F1Tg"]!, type: "flt ") == 6240)
        #expect(daemon.process("set 1500").hasPrefix("error:"))
        smc.putFloat("Tp01", 90)
        daemon.watchdogTick()
        #expect(daemon.process("auto").hasPrefix("error:"))
        smc.putFloat("Tp01", 84)
        daemon.watchdogTick()
        #expect(smc.values["F0Md"] == [0])
        #expect(smc.values["F1Md"] == [0])
    }

    @Test func watchdogRetriesFailedReset() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        #expect(daemon.process("set 3000") == "ok")
        smc.rejectedKeys = ["F0Md"]
        daemon.watchdogTick(now: Date().addingTimeInterval(16))
        #expect(smc.values["F1Md"] == [0])
        smc.rejectedKeys = []
        daemon.watchdogTick()
        #expect(smc.values["F0Md"] == [0])
    }

    @Test func wakeReturnsToAppleUntilAppReappliesProfile() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        #expect(daemon.process("setfan 1 4000") == "ok")
        daemon.handleWake()
        #expect(smc.values["F1Md"] == [0])
    }

    @Test func daemonRejectsNonfiniteRPMAndInvalidFanIndices() throws {
        let smc = TestSMC()
        let daemon = try server(smc)
        for command in ["set nan", "set inf", "set -1", "setfan -1 3000", "autofan 999"] {
            #expect(daemon.process(command).hasPrefix("error:"))
        }
        #expect(!smc.writes.contains { $0.0.hasSuffix("Tg") })
    }
}
