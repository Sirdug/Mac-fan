//
//  ProfileTests.swift
//  Mac Fan
//

import Foundation
import Testing
@testable import MacFanCore

@Suite struct ProfileTests {

    @Test func profileRoundTrip() throws {
        let profile = Profile(
            id: "test-id", name: "Test", linkFans: false,
            fans: [
                FanConfig(mode: .curve, curve: .defaultCurve),
                FanConfig(mode: .fixed, curve: .defaultCurve, fixedRPM: 3200),
            ],
            sensorSource: .key("TCDX"),
            hysteresis: 4, sustainSec: 6, rampUpPerSec: 0.2, rampDownPerSec: 0.05
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func sensorSourceCodable() throws {
        for source in [SensorSource.group(.gpu), SensorSource.key("Tp01")] {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(SensorSource.self, from: data)
            #expect(decoded == source)
        }
    }

    @Test func linkFansUsesFanZero() {
        var profile = Profile.balanced
        profile.linkFans = true
        #expect(profile.config(for: 1) == profile.fans[0])
    }

    @Test func configPadsForExtraFans() {
        var profile = Profile.balanced
        profile.linkFans = false
        // Profile saved with 1 fan, machine has 2 — falls back to last config
        #expect(profile.config(for: 1) == profile.fans[0])

        profile.ensureFanCount(2)
        #expect(profile.fans.count == 2)
    }

    @Test func forkedProfileIsCustom() {
        let fork = Profile.balanced.forked()
        #expect(!fork.isBuiltIn)
        #expect(fork.id != Profile.balanced.id)
        #expect(fork.name.contains("Balanced"))
    }

    @Test func builtinsAreBuiltIn() {
        for p in Profile.builtIn {
            #expect(p.isBuiltIn, "\(p.name) should be built-in")
        }
    }

    @Test func sensorSourceResolvesGroupMax() {
        let temps: [String: Float] = ["Tp01": 55, "Tp02": 61.5, "Tg05": 48, "TH0x": 30]
        #expect(SensorSource.group(.cpu).resolve(in: temps) == 61.5)
        #expect(SensorSource.group(.gpu).resolve(in: temps) == 48)
        #expect(SensorSource.key("TH0x").resolve(in: temps) == 30)
        #expect(SensorSource.group(.battery).resolve(in: temps) == nil)
    }
}
