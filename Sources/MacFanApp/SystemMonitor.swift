//
//  SystemMonitor.swift
//  Mac Fan
//
//  Lightweight system utilization and power telemetry. Everything here is
//  read-only and available to the unprivileged menu bar process.
//

import Darwin
import Foundation
import IOKit

struct CPUCoreMetric: Equatable, Identifiable {
    let id: Int
    let usage: Double
    let cluster: String
}

struct SystemMetrics: Equatable {
    var cpuUsage: Double = 0
    var cpuCores: [CPUCoreMetric] = []
    var cpuModel = "Apple Silicon"
    var loadAverage: [Double] = [0, 0, 0]
    var gpuUsage: Double = 0
    var gpuUsageIsEstimated = true
    var gpuRendererUsage: Double = 0
    var gpuTilerUsage: Double = 0
    var gpuMemoryUsedGB: Double = 0
    var gpuMemoryAllocatedGB: Double = 0
    var gpuParameterBufferMB: Double = 0
    var memoryUsage: Double = 0
    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var memoryAppGB: Double = 0
    var memoryWiredGB: Double = 0
    var memoryCompressedGB: Double = 0
    var memoryCachedGB: Double = 0
    var memoryFreeGB: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0

    /// Estimated whole-system draw reported by the battery controller.
    var systemPowerW: Double?
    /// CPU + GPU + ANE rail estimate from Apple's powermetrics sampler.
    var chipPowerW: Double?
    /// Estimated wall draw. Nil while no adapter is connected or unavailable.
    var wallPowerW: Double?
    /// Positive while charging, negative while discharging.
    var batteryPowerW: Double?
    var batteryPercent: Int?
    var batteryTimeMinutes: Int?
    var batteryEstimateIsQuick = false
    var adapterConnected = false
    var isCharging = false
    var isFullyCharged = false
}

/// Samples cumulative CPU counters and live IOKit properties every poll.
/// Called only from AppState's serial I/O queue.
final class SystemMonitor {
    private var previousCoreTicks: [(used: UInt64, total: UInt64)] = []
    private var estimateModeKey = ""
    private var stableControllerSamples = 0
    private var powerModeKey = ""
    private var systemPowerSamples: [Double] = []
    private var wallPowerSamples: [Double] = []
    private var batteryPowerSamples: [Double] = []
    private let cpuModel = SystemMonitor.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
    private let coreClusters = SystemMonitor.readCoreClusters()

    func sample() -> SystemMetrics {
        var result = SystemMetrics()
        result.cpuModel = cpuModel
        let cpu = readCPUUsage()
        result.cpuUsage = cpu.total
        result.cpuCores = cpu.cores
        result.loadAverage = readLoadAverage()
        readMemoryUsage(into: &result)
        readGPUUsage(into: &result)
        readPower(into: &result)
        return result
    }

    /// One `host_processor_info` read drives both aggregate and per-core CPU
    /// percentages, so every number uses exactly the same counter window.
    private func readCPUUsage() -> (total: Double, cores: [CPUCoreMetric]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &cpuCount, &info, &infoCount
        )
        guard status == KERN_SUCCESS, let info else { return (0, []) }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        var current: [(used: UInt64, total: UInt64)] = []
        var metrics: [CPUCoreMetric] = []
        var aggregateUsed: UInt64 = 0
        var aggregateTotal: UInt64 = 0
        for index in 0..<Int(cpuCount) {
            let base = index * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let used = user + system + nice
            let total = used + idle
            current.append((used, total))

            var usage = 0.0
            if index < previousCoreTicks.count {
                let usedDelta = used &- previousCoreTicks[index].used
                let totalDelta = total &- previousCoreTicks[index].total
                if totalDelta > 0 {
                    usage = Double(usedDelta) / Double(totalDelta)
                    aggregateUsed += usedDelta
                    aggregateTotal += totalDelta
                }
            }
            let cluster = index < coreClusters.count ? coreClusters[index] : "Core"
            metrics.append(.init(id: index, usage: min(max(usage, 0), 1), cluster: cluster))
        }
        previousCoreTicks = current
        let totalUsage = aggregateTotal > 0
            ? Double(aggregateUsed) / Double(aggregateTotal)
            : 0
        return (min(max(totalUsage, 0), 1), metrics)
    }

    private func readLoadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        _ = getloadavg(&values, 3)
        return values
    }

    // MARK: - Memory

    private func readMemoryUsage(into metrics: inout SystemMetrics) {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var info = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, total > 0 else { return }
        let page = Double(vm_kernel_page_size)
        // Match Activity Monitor's definition: app/anonymous memory + wired
        // memory + the physical pages occupied by the compressor. File-backed
        // pages remain in the separate cache bucket because they are reusable.
        let app = Double(info.internal_page_count) * page
        let wired = Double(info.wire_count) * page
        let compressed = Double(info.compressor_page_count) * page
        let used = min(max(app + wired + compressed, 0), total)
        let gib = 1_073_741_824.0
        metrics.memoryUsage = min(used / total, 1)
        metrics.memoryUsedGB = used / gib
        metrics.memoryTotalGB = total / gib
        metrics.memoryAppGB = app / gib
        metrics.memoryWiredGB = wired / gib
        metrics.memoryCompressedGB = compressed / gib
        metrics.memoryCachedGB = Double(info.external_page_count) * page / gib
        metrics.memoryFreeGB = Double(info.free_count) * page / gib
        metrics.pageIns = info.pageins
        metrics.pageOuts = info.pageouts

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            metrics.swapUsedGB = Double(swap.xsu_used) / gib
            metrics.swapTotalGB = Double(swap.xsu_total) / gib
        }
    }

    // MARK: - GPU

    private func readGPUUsage(into metrics: inout SystemMetrics) {
        guard let service = firstService(className: "AGXAccelerator") else { return }
        defer { IOObjectRelease(service) }
        guard let stats = property(service, key: "PerformanceStatistics") as? [String: Any]
        else { return }

        let device = number(stats["Device Utilization %"])
            ?? number(stats["Renderer Utilization %"])
            ?? 0
        metrics.gpuUsage = min(max(device / 100, 0), 1)
        metrics.gpuRendererUsage = min(max((number(stats["Renderer Utilization %"]) ?? 0) / 100, 0), 1)
        metrics.gpuTilerUsage = min(max((number(stats["Tiler Utilization %"]) ?? 0) / 100, 0), 1)
        let gib = 1_073_741_824.0
        metrics.gpuMemoryUsedGB = (number(stats["In use system memory"]) ?? 0) / gib
        metrics.gpuMemoryAllocatedGB = (number(stats["Alloc system memory"]) ?? 0) / gib
        metrics.gpuParameterBufferMB = (number(stats["Allocated PB Size"]) ?? 0) / 1_048_576
    }

    // MARK: - Power

    private func readPower(into result: inout SystemMetrics) {
        guard let battery = firstService(className: "AppleSmartBattery") else { return }
        defer { IOObjectRelease(battery) }

        result.adapterConnected = bool(property(battery, key: "ExternalConnected"))
        result.isCharging = bool(property(battery, key: "IsCharging"))
        result.isFullyCharged = bool(property(battery, key: "FullyCharged"))
        if let capacity = number(property(battery, key: "CurrentCapacity")) {
            result.batteryPercent = Int(capacity.rounded())
        }

        let modeEstimateKey = result.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        let controllerValue = number(property(battery, key: modeEstimateKey))
            ?? number(property(battery, key: "TimeRemaining"))
        let controllerEstimate = controllerValue.flatMap(validMinutes)
        let batteryData = property(battery, key: "BatteryData") as? [String: Any]

        // Voltage is millivolts and amperage is milliamps. Apple publishes
        // negative values as two's-complement UInt64 on some machines.
        let instantCurrent = property(battery, key: "InstantAmperage")
            ?? property(battery, key: "Amperage")
        var batteryVoltageMV: Double?
        if let voltageNumber = property(battery, key: "Voltage") as? NSNumber,
           let currentNumber = instantCurrent as? NSNumber {
            let millivolts = voltageNumber.doubleValue
            batteryVoltageMV = millivolts
            let milliamps = signedNumber(currentNumber)
            result.batteryPowerW = millivolts * milliamps / 1_000_000
        }

        if let telemetry = property(battery, key: "PowerTelemetryData") as? [String: Any] {
            // These M5 controller values are instantaneous milliwatts.
            if let milliwatts = number(telemetry["SystemLoad"]), milliwatts > 0, milliwatts < 500_000 {
                result.systemPowerW = milliwatts / 1_000
            }
            // SystemPowerIn is measured adapter output (voltage × current).
            // Add the controller's adapter-loss estimate for approximate AC
            // wall draw. WallEnergyEstimate is not an instantaneous wattage.
            if result.adapterConnected,
               let input = number(telemetry["SystemPowerIn"]), input > 0, input < 500_000 {
                let loss = number(telemetry["AdapterEfficiencyLoss"]) ?? 0
                result.wallPowerW = (input + max(0, loss)) / 1_000
            }
            // Prefer the controller's filtered battery-power channel over
            // instantaneous voltage × current when it is present.
            if let batteryNumber = telemetry["BatteryPower"] as? NSNumber {
                let milliwatts = signedNumber(batteryNumber)
                if abs(milliwatts) < 300_000 {
                    result.batteryPowerW = milliwatts / 1_000
                }
            }
        }

        // Battery discharge is a useful fallback for system draw while unplugged.
        if result.systemPowerW == nil, let batteryW = result.batteryPowerW {
            result.systemPowerW = abs(batteryW)
        }

        smoothPowerReadings(into: &result)

        updateBatteryEstimate(
            result: &result,
            controllerEstimate: controllerEstimate,
            batteryData: batteryData,
            voltageMV: batteryVoltageMV
        )
    }

    /// Battery-controller channels are bursty. A short median filter removes
    /// single-sample spikes without making the selected refresh interval feel
    /// sluggish. Plug/charge state changes reset the window immediately.
    private func smoothPowerReadings(into result: inout SystemMetrics) {
        let mode = "\(result.adapterConnected)-\(result.isCharging)"
        if mode != powerModeKey {
            powerModeKey = mode
            systemPowerSamples.removeAll()
            wallPowerSamples.removeAll()
            batteryPowerSamples.removeAll()
        }
        result.systemPowerW = smoothed(result.systemPowerW, samples: &systemPowerSamples)
        result.wallPowerW = smoothed(result.wallPowerW, samples: &wallPowerSamples)
        result.batteryPowerW = smoothed(result.batteryPowerW, samples: &batteryPowerSamples)
    }

    private func smoothed(_ value: Double?, samples: inout [Double]) -> Double? {
        guard let value, value.isFinite else { return samples.last }
        samples.append(value)
        if samples.count > 3 { samples.removeFirst(samples.count - 3) }
        let sorted = samples.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    /// First show a local capacity ÷ power estimate. After four consecutive
    /// controller samples (~6 seconds), replace it with macOS's refined value.
    /// Plugging/unplugging resets the sequence because the power model changed.
    private func updateBatteryEstimate(
        result: inout SystemMetrics,
        controllerEstimate: Int?,
        batteryData: [String: Any]?,
        voltageMV: Double?
    ) {
        guard !result.isFullyCharged else { return }

        let modeKey = "\(result.adapterConnected)-\(result.isCharging)"
        if modeKey != estimateModeKey {
            estimateModeKey = modeKey
            stableControllerSamples = 0
        }
        if controllerEstimate != nil {
            stableControllerSamples += 1
        } else {
            stableControllerSamples = 0
        }

        let quick = quickBatteryEstimate(
            charging: result.isCharging,
            batteryData: batteryData,
            voltageMV: voltageMV,
            batteryPowerW: result.batteryPowerW
        )

        if stableControllerSamples >= 4, let controllerEstimate {
            result.batteryTimeMinutes = controllerEstimate
            result.batteryEstimateIsQuick = false
        } else if let quick {
            result.batteryTimeMinutes = quick
            result.batteryEstimateIsQuick = true
        } else if let controllerEstimate {
            // If capacity telemetry is absent, don't hide the only estimate.
            result.batteryTimeMinutes = controllerEstimate
            result.batteryEstimateIsQuick = false
        }
    }

    private func quickBatteryEstimate(
        charging: Bool,
        batteryData: [String: Any]?,
        voltageMV: Double?,
        batteryPowerW: Double?
    ) -> Int? {
        guard let batteryData,
              let voltageMV,
              let batteryPowerW,
              abs(batteryPowerW) > 1,
              let remainingMAh = number(batteryData["RemainingCapacity"])
                    ?? number(batteryData["AppleRawCurrentCapacity"]),
              let fullMAh = number(batteryData["FullChargeCapacity"])
                    ?? number(batteryData["AppleRawMaxCapacity"])
        else { return nil }

        let capacityMAh = charging ? max(fullMAh - remainingMAh, 0) : remainingMAh
        guard capacityMAh > 0 else { return nil }
        let wattHours = capacityMAh * voltageMV / 1_000_000
        // Charging slows near full; a small taper allowance makes the quick
        // estimate less optimistic. Discharge keeps a reserve allowance.
        let adjustment = charging ? 1.15 : 0.95
        let minutes = wattHours / abs(batteryPowerW) * 60 * adjustment
        return validMinutes(minutes)
    }

    private func validMinutes(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value < 65_535 else { return nil }
        return Int(value.rounded())
    }

    // MARK: - IOKit helpers

    private func firstService(className: String) -> io_registry_entry_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(className), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    private func property(_ service: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private func signedNumber(_ value: NSNumber) -> Double {
        Double(Int64(bitPattern: value.uint64Value))
    }

    private static func readCoreClusters() -> [String] {
        let levelCount = sysctlInt("hw.nperflevels") ?? 0
        var result: [String] = []
        for level in 0..<levelCount {
            let count = sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            let name = sysctlString("hw.perflevel\(level).name") ?? "Cluster \(level)"
            result.append(contentsOf: repeatElement(name, count: max(0, count)))
        }
        return result
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
