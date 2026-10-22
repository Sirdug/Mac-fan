//
//  Profile.swift
//  Mac Fan
//
//  A profile bundles per-fan control settings (mode, curve, fixed RPM),
//  the sensor that drives the curves, and engine tuning. Built-ins are
//  immutable; editing one forks it into a user profile saved as JSON.
//

import Foundation

// MARK: - Per-Fan Config

public enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto       // Apple controls this fan
    case curve      // Mac Fan drives it from the profile's curve
    case fixed      // manual RPM

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .curve: return "Curve"
        case .fixed: return "Fixed"
        }
    }
}

public struct FanConfig: Codable, Equatable {
    public var mode: FanMode
    public var curve: FanCurve
    public var fixedRPM: Float

    public init(mode: FanMode, curve: FanCurve, fixedRPM: Float = 2000) {
        self.mode = mode
        self.curve = curve
        self.fixedRPM = fixedRPM
    }
}

// MARK: - Profile

public struct Profile: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// When true, fan 0's config drives every fan.
    public var linkFans: Bool
    public var fans: [FanConfig]
    /// Which temperature drives the curves.
    public var sensorSource: SensorSource
    // Engine tuning
    public var hysteresis: Float
    public var sustainSec: Float
    public var rampUpPerSec: Float
    public var rampDownPerSec: Float

    public init(id: String, name: String, linkFans: Bool = true,
                fans: [FanConfig], sensorSource: SensorSource = .group(.cpu),
                hysteresis: Float = 5, sustainSec: Float = 5,
                rampUpPerSec: Float = 0.10, rampDownPerSec: Float = 0.04) {
        self.id = id
        self.name = name
        self.linkFans = linkFans
        self.fans = fans
        self.sensorSource = sensorSource
        self.hysteresis = hysteresis
        self.sustainSec = sustainSec
        self.rampUpPerSec = rampUpPerSec
        self.rampDownPerSec = rampDownPerSec
    }

    public var isBuiltIn: Bool { Self.builtinIDs.contains(id) }

    /// Config for a fan index, honoring linkFans and padding for machines
    /// with more fans than the profile was saved with.
    public func config(for index: Int) -> FanConfig {
        if linkFans || fans.isEmpty {
            return fans.first ?? FanConfig(mode: .auto, curve: .defaultCurve)
        }
        return index < fans.count ? fans[index] : fans[fans.count - 1]
    }

    /// Grow the fans array to cover `count` fans (repeating the last config).
    public mutating func ensureFanCount(_ count: Int) {
        guard fans.count < count else { return }
        let template = fans.last ?? FanConfig(mode: .auto, curve: .defaultCurve)
        while fans.count < count { fans.append(template) }
    }

    /// Fork into an editable user profile.
    public func forked() -> Profile {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = name + " (custom)"
        return copy
    }
}

// MARK: - Built-ins

extension FanCurve {
    public static let defaultCurve = FanCurve(points: [
        CurvePoint(temp: 50, percent: 0),
        CurvePoint(temp: 55, percent: 0.25),
        CurvePoint(temp: 70, percent: 0.60),
        CurvePoint(temp: 85, percent: 1.0),
    ])
}

extension Profile {
    public static let builtinIDs: Set<String> = ["silent", "balanced", "performance", "max"]

    /// Silent: hands-off — Apple controls the fans, Mac Fan only monitors.
    public static let silent = Profile(
        id: "silent", name: "Silent (Apple Default)",
        fans: [FanConfig(mode: .auto, curve: .defaultCurve)]
    )

    /// Balanced: gentle curve for everyday use.
    public static let balanced = Profile(
        id: "balanced", name: "Balanced",
        fans: [FanConfig(mode: .curve, curve: .defaultCurve)],
        rampUpPerSec: 0.05, rampDownPerSec: 0.025
    )

    /// Performance: earlier, steeper ramp — thermals over noise.
    public static let performance = Profile(
        id: "performance", name: "Performance",
        fans: [FanConfig(mode: .curve, curve: FanCurve(points: [
            CurvePoint(temp: 45, percent: 0),
            CurvePoint(temp: 50, percent: 0.30),
            CurvePoint(temp: 65, percent: 0.85),
            CurvePoint(temp: 80, percent: 1.0),
        ]))],
        sustainSec: 3
    )

    /// Max: fans pinned at 100%.
    public static let max = Profile(
        id: "max", name: "Max",
        fans: [FanConfig(mode: .fixed, curve: .defaultCurve, fixedRPM: 99999)]
    )

    public static let builtIn: [Profile] = [silent, balanced, performance, max]
}

// MARK: - Persistence

extension Profile {
    public static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Fan/profiles")
    }

    public func save() throws {
        guard !isBuiltIn else { return }
        let dir = Self.profilesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    public func delete() {
        guard !isBuiltIn else { return }
        try? FileManager.default.removeItem(
            at: Self.profilesDirectory.appendingPathComponent("\(id).json"))
    }

    /// Built-ins first, then user profiles sorted by name.
    public static func loadAll() -> [Profile] {
        var profiles = builtIn
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory, includingPropertiesForKeys: nil
        ) else {
            return profiles
        }

        var custom: [Profile] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? JSONDecoder().decode(Profile.self, from: data),
               !profile.isBuiltIn
            {
                custom.append(profile)
            }
        }
        profiles.append(contentsOf: custom.sorted { $0.name < $1.name })
        return profiles
    }
}

// MARK: - Safety

public enum ThermalSafety {
    /// Any sensor at or above this forces max fans, overriding everything.
    public static let failsafeTemp: Float = 95.0
    /// Failsafe releases once the hottest sensor drops below this.
    public static let failsafeClearTemp: Float = 85.0
}
