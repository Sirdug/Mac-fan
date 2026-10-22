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
    }
}
