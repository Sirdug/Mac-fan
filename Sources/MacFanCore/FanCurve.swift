//
//  FanCurve.swift
//  Mac Fan
//
//  Point-based fan curve: a sorted list of (temperature, fan %) control
//  points with linear interpolation between them. Fan % is 0.0-1.0 of the
//  fan's min-max RPM span; 0 means "fan off / Apple auto".
//

import Foundation

// MARK: - Curve

public struct CurvePoint: Codable, Equatable, Hashable, Identifiable {
    public var temp: Float      // °C
    public var percent: Float   // 0.0 ... 1.0

    public var id: String { "\(temp)-\(percent)" }

    public init(temp: Float, percent: Float) {
        self.temp = temp
        self.percent = min(max(percent, 0), 1)
    }
}

public struct FanCurve: Codable, Equatable {
    /// Control points, kept sorted by temperature.
    public private(set) var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points.sorted { $0.temp < $1.temp }
    }

    public mutating func setPoints(_ newPoints: [CurvePoint]) {
        points = newPoints.sorted { $0.temp < $1.temp }
    }

    /// Interpolated fan percent (0-1) at a temperature.
    /// Below the first point: the first point's percent.
    /// Above the last point: the last point's percent.
    public func percent(at temp: Float) -> Float {
        guard let first = points.first, let last = points.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }

        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if temp <= b.temp {
                guard b.temp > a.temp else { return b.percent }
                let t = (temp - a.temp) / (b.temp - a.temp)
                return a.percent + t * (b.percent - a.percent)
            }
        }
        return last.percent
    }

    /// Lowest temperature at which the curve produces a non-zero percent,
    /// or nil if the curve is entirely zero. Used for the hysteresis band.
    public var onsetTemp: Float? {
        guard let first = points.first else { return nil }
        if first.percent > 0 { return first.temp }
        // Find the zero point directly before the first non-zero point:
        // interpolation rises above 0 immediately past it.
        for i in 1..<points.count where points[i].percent > 0 {
            return points[i - 1].temp
        }
        return nil
    }
}

// MARK: - Engine

/// What the engine wants a fan to do this tick.
public enum FanAction: Equatable {
    case auto             // release to Apple's control
    case rpm(Float)       // hold at this RPM (absolute)
}

/// Per-fan curve state machine: engagement with sustained trigger,
/// hysteresis on disengage, and ramp governors for acoustic comfort.
/// Pure logic — no SMC access — so it is fully unit-testable.
public final class CurveEngine {

    public struct Config {
        public var curve: FanCurve
        public var hysteresis: Float        // °C below onset before disengaging
        public var sustainSec: Float        // seconds above onset before engaging
        public var rampUpPerSec: Float      // max % increase per second
        public var rampDownPerSec: Float    // max % decrease per second

        public init(curve: FanCurve, hysteresis: Float = 5, sustainSec: Float = 5,
                    rampUpPerSec: Float = 0.10, rampDownPerSec: Float = 0.04) {
            self.curve = curve
            self.hysteresis = hysteresis
            self.sustainSec = sustainSec
            self.rampUpPerSec = rampUpPerSec
            self.rampDownPerSec = rampDownPerSec
        }
    }

    public var config: Config

    private(set) var engaged = false
    private var currentPercent: Float = 0
    private var aboveOnsetSince: Date?
    private var lastTick: Date?

    public init(config: Config) {
        self.config = config
    }

    public func reset() {
        engaged = false
        currentPercent = 0
        aboveOnsetSince = nil
        lastTick = nil
    }

    /// Advance the state machine one tick.
    /// - Returns: the action for this fan given the current temperature.
    public func tick(temp: Float, minRPM: Float, maxRPM: Float, now: Date = Date()) -> FanAction {
        defer { lastTick = now }
        let dt = Float(lastTick.map { now.timeIntervalSince($0) } ?? 0)

        guard let onset = config.curve.onsetTemp else {
            // Curve never turns the fan on
            engaged = false
            currentPercent = 0
            return .auto
        }

        let target = config.curve.percent(at: temp)

        if !engaged {
            currentPercent = 0
            if target > 0 && temp >= onset {
                if let since = aboveOnsetSince {
                    if Float(now.timeIntervalSince(since)) >= config.sustainSec {
                        engaged = true
                        aboveOnsetSince = nil
                    }
                } else {
                    aboveOnsetSince = now
                }
            } else {
                aboveOnsetSince = nil
            }
            if !engaged { return .auto }
        }

        // Disengage only after dropping below the hysteresis band
        if temp < onset - config.hysteresis {
            engaged = false
            currentPercent = 0
            aboveOnsetSince = nil
            return .auto
        }

        // Ramp toward target; while engaged never fall below a floor that
        // keeps the fan at its minimum RPM (avoids start/stop bearing wear).
        let goal = max(target, 0.001)
        if dt > 0 {
            let delta = goal - currentPercent
            let limited = min(max(delta, -config.rampDownPerSec * dt), config.rampUpPerSec * dt)
            currentPercent += limited
        } else {
            currentPercent = goal
        }
        currentPercent = min(max(currentPercent, 0.001), 1)

        let span = max(maxRPM - minRPM, 0)
        return .rpm(minRPM + currentPercent * span)
    }
}
