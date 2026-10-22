//
//  FanCurveTests.swift
//  Mac Fan
//

import Foundation
import Testing
@testable import MacFanCore

@Suite struct FanCurveTests {

    let curve = FanCurve(points: [
        CurvePoint(temp: 50, percent: 0),
        CurvePoint(temp: 60, percent: 0.5),
        CurvePoint(temp: 80, percent: 1.0),
    ])

    // MARK: - Interpolation

    @Test func belowFirstPoint() {
        #expect(curve.percent(at: 30) == 0)
    }

    @Test func aboveLastPoint() {
        #expect(curve.percent(at: 100) == 1.0)
    }

    @Test func atPoints() {
        #expect(curve.percent(at: 50) == 0)
        #expect(curve.percent(at: 60) == 0.5)
        #expect(curve.percent(at: 80) == 1.0)
    }

    @Test func interpolationBetweenPoints() {
        #expect(abs(curve.percent(at: 55) - 0.25) < 0.001)
        #expect(abs(curve.percent(at: 70) - 0.75) < 0.001)
    }

    @Test func pointsAreSortedOnInit() {
        let unsorted = FanCurve(points: [
            CurvePoint(temp: 80, percent: 1.0),
            CurvePoint(temp: 50, percent: 0),
        ])
        #expect(unsorted.points.first?.temp == 50)
    }

    @Test func onsetTemp() {
        #expect(curve.onsetTemp == 50)

        let alwaysOn = FanCurve(points: [CurvePoint(temp: 40, percent: 0.3)])
        #expect(alwaysOn.onsetTemp == 40)

        let neverOn = FanCurve(points: [CurvePoint(temp: 40, percent: 0)])
        #expect(neverOn.onsetTemp == nil)
    }

    // MARK: - Engine

    private func makeEngine(sustainSec: Float = 5) -> CurveEngine {
        CurveEngine(config: .init(
            curve: curve, hysteresis: 5, sustainSec: sustainSec,
            rampUpPerSec: 0.10, rampDownPerSec: 0.04
        ))
    }

    @Test func coldStaysAuto() {
        let engine = makeEngine()
        #expect(engine.tick(temp: 40, minRPM: 1000, maxRPM: 6000) == .auto)
    }

    @Test func sustainedTriggerDelaysEngagement() {
        let engine = makeEngine(sustainSec: 5)
        let t0 = Date()

        // Hot, but not sustained yet
        #expect(engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0) == .auto)
        #expect(engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(2)) == .auto)

        // After 5+ seconds sustained: engaged
        let action = engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(6))
        guard case .rpm(let rpm) = action else {
            Issue.record("expected engagement, got \(action)")
            return
        }
        #expect(rpm > 1000)
    }

    @Test func transientSpikeIsFiltered() {
        let engine = makeEngine(sustainSec: 5)
        let t0 = Date()

        #expect(engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0) == .auto)
        // Temp drops before sustain elapses — timer resets
        #expect(engine.tick(temp: 45, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(3)) == .auto)
        // Hot again — sustain restarts, still auto
        #expect(engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(6)) == .auto)
    }

    @Test func hysteresisKeepsFanRunning() throws {
        let engine = makeEngine(sustainSec: 0)
        let t0 = Date()

        _ = engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0)
        let engagedAction = engine.tick(temp: 70, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(1))
        guard case .rpm = engagedAction else {
            Issue.record("expected engagement, got \(engagedAction)")
            return
        }

        // Drop into hysteresis band (onset 50, hysteresis 5 -> stays on above 45)
        let inBand = engine.tick(temp: 47, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(2))
        guard case .rpm(let rpm) = inBand else {
            Issue.record("expected fan to stay on in hysteresis band, got \(inBand)")
            return
        }
        #expect(rpm >= 1000)

        // Below the band: back to auto
        let below = engine.tick(temp: 43, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(3))
        #expect(below == .auto)
    }

    @Test func rampUpIsGoverned() {
        let engine = makeEngine(sustainSec: 0)
        let t0 = Date()

        _ = engine.tick(temp: 80, minRPM: 1000, maxRPM: 6000, now: t0)
        // 1 second later at 100% target, ramp-up limit is 10%/s
        let action = engine.tick(temp: 80, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(1))
        guard case .rpm(let rpm) = action else {
            Issue.record("expected rpm, got \(action)")
            return
        }
        // percent should be ~0.10-0.20, nowhere near 1.0
        #expect(rpm < 1000 + 0.35 * 5000)
    }

    @Test func rpmMapsToMinMaxSpan() {
        let engine = makeEngine(sustainSec: 0)
        let t0 = Date()

        _ = engine.tick(temp: 80, minRPM: 1000, maxRPM: 6000, now: t0)
        // Long dt so ramp completes
        let action = engine.tick(temp: 80, minRPM: 1000, maxRPM: 6000, now: t0.addingTimeInterval(100))
        guard case .rpm(let rpm) = action else {
            Issue.record("expected rpm, got \(action)")
            return
        }
        #expect(abs(rpm - 6000) < 1)
    }
}
