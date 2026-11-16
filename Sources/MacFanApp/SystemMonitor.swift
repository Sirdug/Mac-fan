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
import IOKit.ps
import MacFanCore

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

    /// Whole-system sensor reading, with battery-controller fallbacks.
    var systemPowerW: Double?
    var systemPowerSource: SystemPowerSource = .unavailable
    /// CPU + GPU + ANE rail estimate from Apple's powermetrics sampler.
    var chipPowerW: Double?
    /// Estimated wall draw. Nil while no adapter is connected or unavailable.
    var wallPowerW: Double?
    /// Positive while charging, negative while discharging.
    var batteryPowerW: Double?
    var batteryPercent: Int?
    var batteryTimeMinutes: Int?
    var batteryEstimateSource: BatteryEstimateSource?
    var adapterConnected = false
    var isCharging = false
    var isFullyCharged = false
}

/// Samples cumulative CPU counters and live IOKit properties every poll.
/// Called only from AppState's serial I/O queue.
final class SystemMonitor {
    private var previousCoreTicks: [(used: UInt64, total: UInt64)] = []
    private let powerSensors = PowerSensorReader()
    private var batteryEstimator = BatteryTimeEstimator()
    private let cpuModel = SystemMonitor.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"

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
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let used = user + system + nice
            let total = used + idle
            current.append((used, total))

            var usage = 0.0
            if index < previousCoreTicks.count, used >= previousCoreTicks[index].used,
               total >= previousCoreTicks[index].total {
                let usedDelta = used - previousCoreTicks[index].used
                let totalDelta = total - previousCoreTicks[index].total
                if totalDelta > 0 {
                    usage = Double(usedDelta) / Double(totalDelta)
                    aggregateUsed += usedDelta
                    aggregateTotal += totalDelta
                }
            }
            // Mach CPU IDs are mapped to clusters by the powermetrics sample.
            let cluster = "Core"
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

        // Keep registry properties in one snapshot; prefer live SMC channels.
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(battery, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return }
        let reading = PowerReading(properties: values, live: powerSensors.sample())
        result.adapterConnected = reading.adapterConnected
        result.isCharging = reading.isCharging
        result.isFullyCharged = reading.isFullyCharged
        result.batteryPercent = reading.batteryPercent
        result.systemPowerW = reading.systemW
        result.systemPowerSource = reading.systemSource
        result.wallPowerW = reading.wallW
        result.batteryPowerW = reading.batteryW
        let estimate = batteryEstimator.update(
            reading, osSeconds: IOPSGetTimeRemainingEstimate(),
            now: ProcessInfo.processInfo.systemUptime
        )
        result.batteryTimeMinutes = estimate?.minutes
        result.batteryEstimateSource = estimate?.source
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

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
