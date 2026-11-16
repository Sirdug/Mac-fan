//
//  SMCKeys.swift
//  Mac Fan
//
//  SMC key constants and data conversion for Apple Silicon.
//  Adapted from ThermalForge (MIT, github.com/ProducerGuy/ThermalForge).
//

import Foundation

// MARK: - Fan Keys

public enum SMCFanKey {
    /// Number of fans (uint8)
    public static let count = "FNum"
    /// Force test / diagnostic unlock flag (uint8: 0=off, 1=on)
    /// Optional diagnostic unlock. Probe at runtime; M1 Pro normally needs no unlock.
    public static let forceTest = "Ftst"

    // Templated keys — use key(_:fan:) to format with fan index
    /// Actual RPM (read-only, flt)
    public static let actual = "F%dAc"
    /// Target RPM (flt)
    public static let target = "F%dTg"
    /// Minimum RPM recommendation (flt)
    public static let minimum = "F%dMn"
    /// Maximum RPM recommendation (flt)
    public static let maximum = "F%dMx"
    /// Fan mode — lowercase on some firmware (ui8: 0=auto, 1=manual)
    public static let modeLower = "F%dmd"
    /// Fan mode — uppercase on M1 Pro (ui8: 0=auto, 1=manual, 3=system)
    public static let modeUpper = "F%dMd"
    /// Fan status (ui8, read-only: 3=system-controlled)
    public static let status = "F%dSt"

    public static func key(_ template: String, fan: Int) -> String {
        String(format: template, fan)
    }
}

// MARK: - Data Conversion

/// Decode according to the reported SMC type, never just the byte count.
func smcNumber(_ bytes: [UInt8], type: String) -> Float? {
    let value: Float
    switch type {
    case "flt " where bytes.count == 4:
        value = smcBytesToFloat(bytes, size: 4)
    case "ioft" where bytes.count == 8:
        value = ioftBytesToFloat(bytes)
    case "sp78" where bytes.count == 2:
        value = Float(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
    case "fpe2" where bytes.count == 2:
        value = Float(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
    default:
        return nil
    }
    return value.isFinite ? value : nil
}

/// Convert SMC bytes to Float.
/// Apple Silicon uses IEEE 754 little-endian (4 bytes).
public func smcBytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
    guard size == 4, bytes.count >= 4 else { return 0 }
    var value: Float = 0
    memcpy(&value, bytes, 4)
    return value
}

/// Convert Float to SMC bytes (IEEE 754 little-endian, 4 bytes).
public func floatToSMCBytes(_ value: Float) -> [UInt8] {
    var v = value
    return withUnsafeBytes(of: &v) { Array($0) }
}

/// Convert ioft (IOKit fixed-point) bytes to Float.
/// Format: little-endian UInt32, 16.16 fixed-point (upper 16 = integer, lower 16 = fraction).
/// First 4 of 8 bytes used; last 4 are metadata/padding.
public func ioftBytesToFloat(_ bytes: [UInt8]) -> Float {
    guard bytes.count >= 4 else { return 0 }
    var raw: UInt32 = 0
    memcpy(&raw, bytes, 4)
    let integer = Float(raw >> 16)
    let fraction = Float(raw & 0xFFFF) / 65536.0
    return integer + fraction
}
