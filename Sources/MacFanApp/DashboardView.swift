//
//  DashboardView.swift
//  Mac Fan
//
//  Compact 60-second system dashboard for the menu bar popover.
//

import MacFanCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    private var metrics: SystemMetrics { state.systemMetrics }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metricTile(
                    kind: .cpu,
                    title: "CPU",
                    icon: "cpu",
                    value: percent(metrics.cpuUsage),
                    detail: cpuTemperature,
                    history: state.cpuHistory,
                    color: .orange
                )
                metricTile(
                    kind: .gpu,
                    title: "GPU",
                    icon: "square.stack.3d.up.fill",
                    value: (metrics.gpuUsageIsEstimated ? "≈" : "") + percent(metrics.gpuUsage),
                    detail: gpuTemperature,
                    history: state.gpuHistory,
                    color: .purple
                )
                metricTile(
                    kind: .ram,
                    title: "RAM",
                    icon: "memorychip.fill",
                    value: percent(metrics.memoryUsage),
                    detail: String(format: "%.1f / %.0f GB", metrics.memoryUsedGB, metrics.memoryTotalGB),
                    history: state.memoryHistory,
                    color: .cyan
                )
            }

            powerCard
        }
    }

    private func metricTile(
        kind: SystemDetailKind,
        title: String,
        icon: String,
        value: String,
        detail: String,
        history: [Double],
        color: Color
    ) -> some View {
        Button {
            state.expandedDetail = kind
        } label: {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.4)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(color)

            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(detail)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            MiniGraph(values: history, color: color, fixedMaximum: 1)
                .frame(height: 25)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.055))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [color.opacity(0.16), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Show detailed \(title) monitor in this panel")
    }

    private var powerCard: some View {
        VStack(spacing: 7) {
            HStack(alignment: .top, spacing: 0) {
                powerValue(
                    title: "SYSTEM",
                    icon: "bolt.fill",
                    value: watts(metrics.systemPowerW),
                    subtitle: systemPowerSubtitle,
                    color: .orange
                )
                powerDivider
                powerValue(
                    title: "WALL",
                    icon: "powerplug.fill",
                    value: metrics.adapterConnected ? watts(metrics.wallPowerW) : "—",
                    subtitle: metrics.adapterConnected ? "AC input" : "Unplugged",
                    color: .green
                )
                powerDivider
                powerValue(
                    title: "BATTERY",
                    icon: batteryIcon,
                    value: batteryWatts,
                    subtitle: batterySubtitle,
                    color: metrics.isCharging ? .green : .blue
                )
            }

            batteryEstimate

            HStack(spacing: 7) {
                MiniGraph(values: state.powerHistory, color: .orange, fixedMaximum: nil)
                    .frame(height: 27)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("POWER HISTORY")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text("60 SEC")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.035))
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .help("Whole-Mac, wall, and battery values use Apple battery-controller telemetry. The system value is cross-checked against Apple's CPU + GPU + ANE powermetrics estimate when the updated helper is installed. These remain estimates, not utility-grade measurements.")
    }

    private var batteryEstimate: some View {
        HStack(spacing: 6) {
            Image(systemName: metrics.batteryEstimateIsQuick
                  ? "bolt.fill"
                  : (metrics.isCharging ? "clock.badge.checkmark" : "clock"))
                .font(.system(size: 9, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(batteryEstimateText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                if metrics.batteryEstimateIsQuick {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 8, height: 8)
                        Text("Working on a better estimate…")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let percent = metrics.batteryPercent {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(metrics.isCharging ? .green : .blue)
                    .frame(width: 78)
            }
        }
        .foregroundStyle(metrics.isCharging ? Color.green : Color.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            (metrics.isCharging ? Color.green : Color.blue).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func powerValue(
        title: String,
        icon: String,
        value: String,
        subtitle: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(subtitle)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var powerDivider: some View {
        Divider()
            .frame(height: 43)
            .padding(.horizontal, 8)
    }

    private var cpuTemperature: String {
        componentTemperature(.cpu)
    }

    private var gpuTemperature: String {
        componentTemperature(.gpu)
    }

    private func componentTemperature(_ group: SensorGroup) -> String {
        guard let temp = SensorSource.group(group).resolve(in: state.temps) else { return "No sensor" }
        let display = state.useFahrenheit ? temp * 9 / 5 + 32 : temp
        return String(format: "%.1f°%@", display, state.useFahrenheit ? "F" : "C")
    }

    private var batteryIcon: String {
        guard let percent = metrics.batteryPercent else { return "battery.0percent" }
        if metrics.isCharging { return "battery.100percent.bolt" }
        switch percent {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryWatts: String {
        guard let value = metrics.batteryPowerW else { return "—" }
        return String(format: "%.1f W", abs(value))
    }

    private var systemPowerSubtitle: String {
        guard let chipPower = metrics.chipPowerW else { return "Estimated total" }
        return String(format: "SoC %.1f W", chipPower)
    }

    private var batterySubtitle: String {
        let percent = metrics.batteryPercent.map { "\($0)%" } ?? ""
        if metrics.isCharging { return percent.isEmpty ? "Charging" : "\(percent) · charging" }
        if let power = metrics.batteryPowerW, power < -0.2 {
            return percent.isEmpty ? "Discharging" : "\(percent) · battery"
        }
        return percent.isEmpty ? "Idle" : "\(percent) · idle"
    }

    private var batteryEstimateText: String {
        if metrics.isFullyCharged { return "Battery fully charged" }
        if let minutes = metrics.batteryTimeMinutes {
            let estimate = metrics.isCharging
                ? "Full in \(formatDuration(minutes))"
                : "\(formatDuration(minutes)) remaining"
            return metrics.batteryEstimateIsQuick ? "Quick estimate · \(estimate)" : estimate
        }
        if metrics.isCharging { return "Calculating time to full…" }
        if metrics.adapterConnected { return "Connected · not charging" }
        return "Calculating battery time…"
    }

    private func formatDuration(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) hr" }
        return "\(hours) hr \(minutes) min"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f W", max(0, value))
    }
}

struct MiniGraph: View {
    let values: [Double]
    let color: Color
    let fixedMaximum: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                graphPath(in: geometry.size, closeBottom: true)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.28), color.opacity(0.015)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                graphPath(in: geometry.size, closeBottom: false)
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func graphPath(in size: CGSize, closeBottom: Bool) -> Path {
        var path = Path()
        guard !values.isEmpty, size.width > 0, size.height > 0 else { return path }
        let maximum = max(fixedMaximum ?? ((values.max() ?? 1) * 1.15), 0.001)
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : size.width

        for (index, rawValue) in values.enumerated() {
            let value = min(max(rawValue / maximum, 0), 1)
            let point = CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat(value) * size.height
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        if closeBottom {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}
