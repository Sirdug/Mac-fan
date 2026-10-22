//
//  PerformanceSnapshot.swift
//  Mac Fan
//
//  Optional high-detail frequency and power data supplied by the privileged
//  helper through Apple's powermetrics utility.
//

import Foundation

public struct PerformanceSnapshot: Codable, Equatable {
    public var clusterMHz: [String: Double]
    public var perCoreMHz: [String: Double]
    public var gpuMHz: Double?
    public var cpuUsage: Double?
    public var gpuUsage: Double?
    public var cpuPowerW: Double?
    public var gpuPowerW: Double?
    public var anePowerW: Double?
    public var combinedPowerW: Double?
    public var sampledAt: Date

    public init(
        clusterMHz: [String: Double] = [:],
        perCoreMHz: [String: Double] = [:],
        gpuMHz: Double? = nil,
        cpuUsage: Double? = nil,
        gpuUsage: Double? = nil,
        cpuPowerW: Double? = nil,
        gpuPowerW: Double? = nil,
        anePowerW: Double? = nil,
        combinedPowerW: Double? = nil,
        sampledAt: Date = Date()
    ) {
        self.clusterMHz = clusterMHz
        self.perCoreMHz = perCoreMHz
        self.gpuMHz = gpuMHz
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.cpuPowerW = cpuPowerW
        self.gpuPowerW = gpuPowerW
        self.anePowerW = anePowerW
        self.combinedPowerW = combinedPowerW
        self.sampledAt = sampledAt
    }

    /// Parse one or more NUL-separated property lists emitted by
    /// `powermetrics --format plist`. The last actual sample wins; the stream
    /// can also contain a hardware/header plist before its delta samples.
    public static func parsePowermetricsPlist(_ data: Data) throws -> PerformanceSnapshot {
        let chunks = data.split(separator: 0, omittingEmptySubsequences: true).map(Data.init)
        let candidates = chunks.isEmpty ? [data] : chunks
        var sample: [String: Any]?

        for chunk in candidates {
            guard let object = try? PropertyListSerialization.propertyList(
                from: chunk, options: [], format: nil
            ), let dictionary = object as? [String: Any],
               dictionary["processor"] != nil || dictionary["gpu"] != nil
            else { continue }
            sample = dictionary
        }

        guard let sample else { throw PowermetricsParseError.noSample }
        var snapshot = PerformanceSnapshot()
        snapshot.sampledAt = sample["timestamp"] as? Date ?? Date()

        if let processor = sample["processor"] as? [String: Any] {
            snapshot.cpuPowerW = wattsFromMilliwatts(processor["cpu_power"])
            snapshot.gpuPowerW = wattsFromMilliwatts(processor["gpu_power"])
            snapshot.anePowerW = wattsFromMilliwatts(processor["ane_power"])
            snapshot.combinedPowerW = wattsFromMilliwatts(processor["combined_power"])

            var coreUsages: [Double] = []
            if let clusters = processor["clusters"] as? [[String: Any]] {
                for cluster in clusters {
                    let name = cluster["name"] as? String ?? "Cluster"
                    if let hz = number(cluster["freq_hz"]), hz >= 0 {
                        snapshot.clusterMHz[name] = hz / 1_000_000
                    }
                    if let cpus = cluster["cpus"] as? [[String: Any]] {
                        for cpu in cpus {
                            guard let id = integer(cpu["cpu"]) else { continue }
                            if let hz = number(cpu["freq_hz"]), hz >= 0 {
                                snapshot.perCoreMHz["\(id)"] = hz / 1_000_000
                            }
                            if let idle = ratio(cpu["idle_ratio"]) {
                                coreUsages.append(1 - idle)
                            }
                        }
                    }
                }
            }
            if !coreUsages.isEmpty {
                snapshot.cpuUsage = coreUsages.reduce(0, +) / Double(coreUsages.count)
            }
        }

        if let gpu = sample["gpu"] as? [String: Any] {
            if let hz = number(gpu["freq_hz"]), hz >= 0 {
                snapshot.gpuMHz = hz / 1_000_000
            }
            if let idle = ratio(gpu["idle_ratio"]) {
                snapshot.gpuUsage = 1 - idle
            }
            if snapshot.gpuPowerW == nil {
                snapshot.gpuPowerW = wattsFromEnergy(
                    gpu["gpu_energy"], elapsedNanoseconds: sample["elapsed_ns"])
            }
        }

        return snapshot
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard var value = number(value), value.isFinite else { return nil }
        if value > 1 { value /= 100 }
        return min(max(value, 0), 1)
    }

    private static func wattsFromMilliwatts(_ value: Any?) -> Double? {
        guard let milliwatts = number(value), milliwatts.isFinite, milliwatts >= 0 else { return nil }
        return milliwatts / 1_000
    }

    /// `powermetrics` energy counters are nanojoules. This is only a fallback
    /// for releases that omit the processor-level GPU power field.
    private static func wattsFromEnergy(_ energy: Any?, elapsedNanoseconds: Any?) -> Double? {
        guard let nanojoules = number(energy),
              let nanoseconds = number(elapsedNanoseconds), nanoseconds > 0
        else { return nil }
        return nanojoules / nanoseconds
    }
}

public enum PowermetricsParseError: Error {
    case noSample
}
