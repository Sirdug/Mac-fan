//
//  Sensors.swift
//  Mac Fan
//
//  Catalog of Apple Silicon SMC temperature sensors, grouped by component.
//  Key list adapted from ThermalForge's verified M1-M5 probing set.
//

import Foundation

// MARK: - Sensor Groups

public enum SensorGroup: String, Codable, CaseIterable, Identifiable {
    case cpu
    case gpu
    case ram
    case ssd
    case ambient
    case battery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .ssd: return "SSD"
        case .ambient: return "Ambient"
        case .battery: return "Battery"
        }
    }
}

// MARK: - Sensor Source

/// What drives a temperature readout: a component group (max of its sensors)
/// or one specific SMC key.
public enum SensorSource: Codable, Equatable, Hashable {
    case group(SensorGroup)
    case key(String)

    public var displayName: String {
        switch self {
        case .group(let g): return g.displayName
        case .key(let k): return k
        }
    }

    /// Resolve this source against a temperature snapshot (SMC key -> °C).
    /// Groups resolve to the hottest sensor in the group.
    public func resolve(in temps: [String: Float]) -> Float? {
        switch self {
        case .key(let k):
            return temps[k]
        case .group(let g):
            let values = temps.compactMap { key, value in
                SensorCatalog.group(for: key) == g ? value : nil
            }
            return values.max()
        }
    }
}

// MARK: - Catalog

public enum SensorCatalog {

    /// flt-type temperature keys (4 bytes) known across M1-M5.
    /// Keys that don't exist on a given machine are skipped when probing.
    public static let floatKeys: [String] = [
        // CPU — aggregate
        "TCDX", "TCHP", "TCMb",
        // CPU — per-core (Tp prefix, mappings vary by generation)
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
        "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
        "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
        // GPU (flt type — M1 through M4)
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        // Memory
        "Tm02", "Tm06", "Tm08", "Tm09",
        "TRDX", "TMVR",
        // Power delivery
        "TPDX",
        // SSD
        "TH0x", "TH0A", "TH0B",
        // Ambient
        "TAOL", "TA0P",
        // Proximity
        "TS0P",
        // Battery
        "TB0T",
    ]

    /// ioft-type keys (16.16 fixed-point, 8 bytes) — GPU temps on the M5 family.
    public static let ioftKeys: [String] = ["TG0B", "TG0H", "TG0V"]

    /// Map an SMC key to its component group.
    public static func group(for key: String) -> SensorGroup? {
        switch key {
        case "TRDX", "TMVR": return .ram
        case "TPDX": return .cpu   // power delivery — count toward CPU thermals
        case "TAOL", "TA0P", "TS0P": return .ambient
        default: break
        }
        if key.hasPrefix("Tp") || key.hasPrefix("TC") { return .cpu }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") { return .gpu }
        if key.hasPrefix("Tm") { return .ram }
        if key.hasPrefix("TH") { return .ssd }
        if key.hasPrefix("TB") { return .battery }
        return nil
    }

    /// Group a temperature snapshot into per-component maxima, ordered for display.
    public static func groupedMaxima(_ temps: [String: Float]) -> [(group: SensorGroup, temp: Float)] {
        SensorGroup.allCases.compactMap { g in
            SensorSource.group(g).resolve(in: temps).map { (g, $0) }
        }
    }
}

// MARK: - Formatting

public func formatTemp(_ celsius: Float, fahrenheit: Bool, decimals: Int = 1) -> String {
    let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
    return String(format: "%.\(decimals)f°\(fahrenheit ? "F" : "C")", value)
}
