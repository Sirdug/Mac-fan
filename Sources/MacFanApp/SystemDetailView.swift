//
//  SystemDetailView.swift
//  Mac Fan
//
//  Expanded CPU, GPU, and unified-memory monitoring views.
//

import MacFanCore
import SwiftUI

enum SystemDetailKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case ram = "RAM"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up.fill"
        case .ram: return "memorychip.fill"
        }
    }
    var color: Color {
        switch self {
        case .cpu: return .orange
        case .gpu: return .purple
        case .ram: return .cyan
        }
    }
}

struct SystemDetailView: View {
    @EnvironmentObject var state: AppState
    let kind: SystemDetailKind
    var compact = false

    private var metrics: SystemMetrics { state.systemMetrics }

    var body: some View {
        Group {
            if compact {
                detailContent
                    .frame(width: 360)
            } else {
                ScrollView { detailContent }
                    .frame(minWidth: 660, minHeight: 560)
            }
        }
        .background(
            LinearGradient(
                colors: [kind.color.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        )
    }

    private var detailContent: some View {
        GlassEffectContainer(spacing: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                header
                switch kind {
                case .cpu: cpuView
                case .gpu: gpuView
                case .ram: memoryView
                }
            }
            .padding(compact ? 14 : 18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 0) {
        HStack(spacing: compact ? 8 : 12) {
            if compact {
                Button {
                    state.expandedDetail = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Back to Mac Fan")
            }
            Image(systemName: kind.icon)
                .font(.system(size: compact ? 15 : 22, weight: .semibold))
                .foregroundStyle(kind.color)
                .frame(width: compact ? 30 : 42, height: compact ? 30 : 42)
                .background(kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: compact ? 9 : 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind.rawValue) Monitor")
                    .font(.system(size: compact ? 16 : 22, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !compact {
            HStack(spacing: 4) {
                ForEach(SystemDetailKind.allCases) { target in
                    detailTab(target)
                }
            }
            }
        }
        if compact {
            HStack(spacing: 5) {
                ForEach(SystemDetailKind.allCases) { target in
                    detailTab(target)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        }
    }

    @ViewBuilder
    private func detailTab(_ target: SystemDetailKind) -> some View {
        if target == kind {
            Button {
            } label: {
                Label(target.rawValue, systemImage: target.icon)
            }
            .buttonStyle(.glassProminent)
            .tint(target.color)
            .controlSize(.small)
        } else {
            Button {
                if compact {
                    state.expandedDetail = target
                }
            } label: {
                Label(target.rawValue, systemImage: target.icon)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private var headerSubtitle: String {
        switch kind {
        case .cpu: return "\(metrics.cpuModel) · \(metrics.cpuCores.count) cores"
        case .gpu: return "Apple integrated GPU · shared unified memory"
        case .ram: return String(format: "%.0f GB unified memory", metrics.memoryTotalGB)
        }
    }

    // MARK: - CPU

    private var cpuView: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroAndGraph(
                value: percent(metrics.cpuUsage),
                caption: "TOTAL CPU USE",
                detail: componentTemperature(.cpu),
                history: state.cpuHistory,
                color: .orange
            )

            LazyVGrid(columns: statColumns, spacing: 8) {
                detailStat("Temperature", componentTemperature(.cpu), "thermometer.medium", .orange)
                detailStat("1 min load", format(metrics.loadAverage.first ?? 0, 2), "gauge.with.dots.needle.50percent", .yellow)
                detailStat("CPU power", watts(state.performanceSnapshot?.cpuPowerW), "bolt.fill", .green)
                detailStat("Active clock", aggregateCPUClock, "speedometer", .blue)
            }

            if let snapshot = state.performanceSnapshot, !snapshot.clusterMHz.isEmpty {
                sectionTitle("Cluster clocks")
                LazyVGrid(columns: statColumns, spacing: 8) {
                    ForEach(snapshot.clusterMHz.sorted(by: { $0.key < $1.key }), id: \.key) { name, mhz in
                        detailStat(
                            name.replacingOccurrences(of: "-Cluster", with: ""),
                            frequency(mhz), "waveform.path.ecg", .blue
                        )
                    }
                }
            }

            sectionTitle("Per-core activity")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 3 : 6), spacing: 8) {
                ForEach(metrics.cpuCores) { core in
                    coreCard(core)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                detailStat("1 minute", format(load(at: 0), 2), "chart.line.uptrend.xyaxis", .orange)
                detailStat("5 minutes", format(load(at: 1), 2), "chart.line.uptrend.xyaxis", .orange)
                detailStat("15 minutes", format(load(at: 2), 2), "chart.line.uptrend.xyaxis", .orange)
            }

            performanceNotice
        }
    }

    private func coreCard(_ core: CPUCoreMetric) -> some View {
        let color: Color = core.cluster == "Super" ? .orange : .yellow
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CORE \(core.id)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                Spacer()
                Text(core.cluster == "Super" ? "S" : "P")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
            }
            Text(percent(core.usage))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: core.usage)
                .progressViewStyle(.linear)
                .tint(color)
            Text(coreClock(core))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .help("\(core.cluster) core \(core.id)")
    }

    // MARK: - GPU

    private var gpuView: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroAndGraph(
                value: (metrics.gpuUsageIsEstimated ? "≈" : "") + percent(metrics.gpuUsage),
                caption: "GPU DEVICE USE",
                detail: componentTemperature(.gpu),
                history: state.gpuHistory,
                color: .purple
            )

            LazyVGrid(columns: statColumns, spacing: 8) {
                detailStat("Renderer", "≈" + percent(metrics.gpuRendererUsage), "paintbrush.pointed.fill", .purple)
                detailStat("Tiler", "≈" + percent(metrics.gpuTilerUsage), "square.grid.3x3.fill", .pink)
                detailStat("GPU clock", gpuClock, "speedometer", .blue)
                detailStat("GPU power", watts(state.performanceSnapshot?.gpuPowerW), "bolt.fill", .green)
            }

            sectionTitle("Unified-memory activity")
            LazyVGrid(columns: statColumns, spacing: 8) {
                detailStat("In use", format(metrics.gpuMemoryUsedGB, 2) + " GB", "memorychip.fill", .purple)
                detailStat("Allocated", format(metrics.gpuMemoryAllocatedGB, 2) + " GB", "square.stack.3d.up.fill", .indigo)
                detailStat("Parameter buffer", format(metrics.gpuParameterBufferMB, 0) + " MB", "shippingbox.fill", .pink)
                detailStat("Temperature", componentTemperature(.gpu), "thermometer.medium", .orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("GPU memory share", systemImage: "memorychip")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(percent(metrics.gpuMemoryUsedGB / max(metrics.memoryTotalGB, 0.001)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                ProgressView(value: metrics.gpuMemoryUsedGB, total: max(metrics.memoryTotalGB, 0.001))
                    .progressViewStyle(.linear)
                    .tint(.purple)
                Text("Apple Silicon GPUs share the Mac's unified memory instead of having separate VRAM.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

            performanceNotice
        }
    }

    // MARK: - Memory

    private var memoryView: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroAndGraph(
                value: String(format: "%.1f GB", metrics.memoryUsedGB),
                caption: "MEMORY IN USE · \(percent(metrics.memoryUsage))",
                detail: String(format: "%.1f GB available", max(metrics.memoryTotalGB - metrics.memoryUsedGB, 0)),
                history: state.memoryHistory,
                color: .cyan
            )

            sectionTitle("Memory composition")
            VStack(alignment: .leading, spacing: 10) {
                MemoryCompositionBar(metrics: metrics)
                    .frame(height: 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: compact ? 2 : 3), spacing: 8) {
                    memoryLegend("App memory", metrics.memoryAppGB, .cyan)
                    memoryLegend("Wired", metrics.memoryWiredGB, .orange)
                    memoryLegend("Compressed", metrics.memoryCompressedGB, .purple)
                    memoryLegend("Cache", metrics.memoryCachedGB, .blue)
                    memoryLegend("Free", metrics.memoryFreeGB, .green)
                    memoryLegend("Total", metrics.memoryTotalGB, .secondary)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

            LazyVGrid(columns: statColumns, spacing: 8) {
                detailStat("Swap used", String(format: "%.2f GB", metrics.swapUsedGB), "externaldrive.fill", .purple)
                detailStat("Swap total", String(format: "%.1f GB", metrics.swapTotalGB), "externaldrive", .secondary)
                detailStat("Page-ins", compact(metrics.pageIns), "arrow.down.to.line", .blue)
                detailStat("Page-outs", compact(metrics.pageOuts), "arrow.up.to.line", .orange)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Memory use", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(memoryHealth)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(memoryHealthColor)
                }
                ProgressView(value: metrics.memoryUsage)
                    .progressViewStyle(.linear)
                    .tint(memoryHealthColor)
                Text("Cache is reclaimable; compressed memory reduces swap activity under pressure.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Shared components

    private func heroAndGraph(
        value: String, caption: String, detail: String,
        history: [Double], color: Color
    ) -> some View {
        HStack(spacing: compact ? 10 : 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: compact ? 29 : 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .kerning(0.5)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: compact ? 112 : 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("60 SECOND HISTORY")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                }
                MiniGraph(values: history, color: color, fixedMaximum: 1)
                    .frame(height: compact ? 58 : 78)
            }
        }
        .padding(compact ? 12 : 16)
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func detailStat(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title.uppercased(), systemImage: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder private var performanceNotice: some View {
        if state.performanceSnapshot?.gpuUsage == nil {
            HStack(spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibrated GPU and rail telemetry needs the updated helper")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Run ./setup.sh once; CPU and memory readings already use the corrected local samplers.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }

    private var statColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: compact ? 2 : 4)
    }

    private func memoryLegend(_ name: String, _ gb: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(String(format: "%.2f GB", gb))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            Spacer()
        }
    }

    private func componentTemperature(_ group: SensorGroup) -> String {
        guard let temp = SensorSource.group(group).resolve(in: state.temps) else { return "—" }
        return formatTemp(temp, fahrenheit: state.useFahrenheit)
    }

    private func load(at index: Int) -> Double {
        index < metrics.loadAverage.count ? metrics.loadAverage[index] : 0
    }

    private var aggregateCPUClock: String {
        guard let values = state.performanceSnapshot?.clusterMHz.values, !values.isEmpty else { return "—" }
        return frequency(values.reduce(0, +) / Double(values.count))
    }

    private func coreClock(_ core: CPUCoreMetric) -> String {
        if let mhz = state.performanceSnapshot?.perCoreMHz["\(core.id)"] { return frequency(mhz) }
        guard let clusters = state.performanceSnapshot?.clusterMHz, !clusters.isEmpty else { return "Clock —" }
        let values = clusters.values.sorted()
        let mhz = core.cluster == "Super" ? values.last! : values.first!
        return frequency(mhz)
    }

    private var gpuClock: String {
        state.performanceSnapshot?.gpuMHz.map(frequency) ?? "—"
    }

    private func frequency(_ mhz: Double) -> String {
        mhz >= 1_000 ? String(format: "%.2f GHz", mhz / 1_000) : String(format: "%.0f MHz", mhz)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func format(_ value: Double, _ decimals: Int) -> String { String(format: "%.*f", decimals, value) }
    private func watts(_ value: Double?) -> String { value.map { String(format: "%.2f W", $0) } ?? "—" }
    private func compact(_ value: UInt64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private var memoryHealth: String {
        if metrics.memoryUsage > 0.9 { return "HIGH" }
        if metrics.memoryUsage > 0.75 { return "ELEVATED" }
        return "NORMAL"
    }
    private var memoryHealthColor: Color {
        if metrics.memoryUsage > 0.9 { return .red }
        if metrics.memoryUsage > 0.75 { return .orange }
        return .green
    }
}

private struct MemoryCompositionBar: View {
    let metrics: SystemMetrics

    var body: some View {
        GeometryReader { geometry in
            let segments: [(Double, Color)] = [
                (metrics.memoryAppGB, .cyan),
                (metrics.memoryWiredGB, .orange),
                (metrics.memoryCompressedGB, .purple),
                (metrics.memoryCachedGB, .blue),
                (metrics.memoryFreeGB, .green),
            ]
            let sum = max(segments.reduce(0) { $0 + max($1.0, 0) }, 0.001)
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.1)
                        .frame(width: max(1, geometry.size.width * segment.0 / sum))
                }
            }
        }
    }
}
