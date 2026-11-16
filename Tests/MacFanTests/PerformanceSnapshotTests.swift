//
//  PerformanceSnapshotTests.swift
//  Mac Fan
//

import Foundation
import Testing
@testable import MacFanCore

@Suite struct PerformanceSnapshotTests {

    @Test func parsesMachineReadablePowermetricsSample() throws {
        let header: [String: Any] = ["hw_model": "Mac17,9"]
        let sample: [String: Any] = [
            "is_delta": true,
            "elapsed_ns": 500_000_000,
            "processor": [
                "cpu_power": 12_500.0,
                "gpu_power": 4_250.0,
                "ane_power": 250.0,
                "combined_power": 17_000.0,
                "clusters": [[
                    "name": "Super",
                    "freq_hz": 3_200_000_000.0,
                    "cpus": [
                        ["cpu": 0, "freq_hz": 3_100_000_000.0, "idle_ratio": 0.9],
                        ["cpu": 1, "freq_hz": 2_900_000_000.0, "idle_ratio": 0.5],
                    ],
                ]],
            ],
            "gpu": [
                "freq_hz": 1_400_000_000.0,
                "idle_ratio": 0.25,
            ],
        ]

        var stream = try PropertyListSerialization.data(
            fromPropertyList: header, format: .xml, options: 0)
        stream.append(0)
        stream.append(try PropertyListSerialization.data(
            fromPropertyList: sample, format: .xml, options: 0))
        stream.append(0)

        let snapshot = try PerformanceSnapshot.parsePowermetricsPlist(stream)
        #expect(abs((snapshot.cpuUsage ?? 0) - 0.30) < 0.0001)
        #expect(abs((snapshot.gpuUsage ?? 0) - 0.75) < 0.0001)
        #expect(snapshot.clusterMHz["Super"] == 3_200)
        #expect(snapshot.perCoreMHz["0"] == 3_100)
        #expect(snapshot.gpuMHz == 1_400)
        #expect(snapshot.cpuPowerW == 12.5)
        #expect(snapshot.gpuPowerW == 4.25)
        #expect(snapshot.anePowerW == 0.25)
        #expect(snapshot.combinedPowerW == 17)
    }

    @Test func newFieldsDecodeFromAnOlderHelperPayload() throws {
        let data = #"{"clusterMHz":{},"perCoreMHz":{},"sampledAt":0}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(PerformanceSnapshot.self, from: data)
        #expect(snapshot.cpuUsage == nil)
        #expect(snapshot.gpuUsage == nil)
        #expect(snapshot.combinedPowerW == nil)
        #expect(snapshot.perCoreClusters == nil)
    }

    @Test(arguments: [8, 10]) func m1ProCoreIDsAndOlderPowerFormat(coreCount: Int) throws {
        let secondPerformanceCluster = 2 + (coreCount - 2) / 2
        let clusters: [[String: Any]] = [
            ["name": "E-Cluster", "freq_hz": 2_064_000_000.0,
             "cpus": (0..<2).map { ["cpu": $0, "freq_hz": 2_064_000_000.0, "idle_ratio": 0.75] }],
            ["name": "P0-Cluster", "freq_hz": 3_228_000_000.0,
             "cpus": (2..<secondPerformanceCluster).map { ["cpu": $0, "freq_hz": 3_228_000_000.0, "idle_ratio": 0.5] }],
            ["name": "P1-Cluster", "freq_hz": 3_228_000_000.0,
             "cpus": (secondPerformanceCluster..<coreCount).map { ["cpu": $0, "freq_hz": 3_228_000_000.0, "idle_ratio": 0.5] }],
        ]
        let sample: [String: Any] = [
            "is_delta": true, "elapsed_ns": 500_000_000,
            "processor": ["clusters": clusters, "cpu_energy": 6_000,
                          "gpu_energy": 2_000, "ane_energy": 250],
            "gpu": ["freq_hz": 1_296, "idle_ratio": 0.25],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: sample, format: .xml, options: 0)
        let snapshot = try PerformanceSnapshot.parsePowermetricsPlist(data)
        #expect(snapshot.perCoreMHz.count == coreCount)
        #expect(snapshot.perCoreClusters?["0"] == "E-Cluster")
        #expect(snapshot.perCoreClusters?["2"] == "P0-Cluster")
        #expect(snapshot.perCoreClusters?["\(coreCount - 1)"] == "P1-Cluster")
        #expect(snapshot.gpuMHz == 1_296)
        #expect(snapshot.cpuPowerW == 12)
        #expect(snapshot.gpuPowerW == 4)
        #expect(snapshot.anePowerW == 0.5)
        #expect(snapshot.combinedPowerW == 16.5)
    }

    @Test func binaryPlistAndGPUOnlyEnergyFallback() throws {
        let sample: [String: Any] = ["elapsed_ns": 250_000_000,
                                     "gpu": ["gpu_energy": 500, "freq_hz": 900, "idle_ratio": 0.5]]
        let data = try PropertyListSerialization.data(fromPropertyList: sample, format: .binary, options: 0)
        let snapshot = try PerformanceSnapshot.parsePowermetricsPlist(data)
        #expect(snapshot.gpuPowerW == 2)
        #expect(snapshot.gpuMHz == 900)
    }

    @Test func invalidSampleDoesNotBecomeZeroTelemetry() throws {
        let sample: [String: Any] = ["invalid": true, "processor": ["cpu_power": 0]]
        let data = try PropertyListSerialization.data(fromPropertyList: sample, format: .xml, options: 0)
        #expect(throws: PowermetricsParseError.self) { try PerformanceSnapshot.parsePowermetricsPlist(data) }
    }

    @Test func efficiencyPerformanceAndSuperBadges() {
        #expect(CPUClusterKind(clusterName: "E-Cluster").badge == "E")
        #expect(CPUClusterKind(clusterName: "E0-Cluster").badge == "E")
        #expect(CPUClusterKind(clusterName: "P1-Cluster").badge == "P")
        #expect(CPUClusterKind(clusterName: "Super").badge == "S")
        #expect(CPUClusterKind(clusterName: "Core").badge == "—")
    }
}
