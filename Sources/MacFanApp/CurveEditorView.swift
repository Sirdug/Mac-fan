//
//  CurveEditorView.swift
//  Mac Fan
//
//  Draggable-point fan curve editor. X: temperature (30-110 °C),
//  Y: fan speed (0-100% of the fan's min-max RPM span).
//

import MacFanCore
import SwiftUI

struct CurveEditorView: View {
    @EnvironmentObject var state: AppState

    @State private var selectedFan = 0
    /// Live curve while a drag is in flight (committed on drag end)
    @State private var draftCurve: FanCurve?
    @State private var draftName: String = ""

    private let tempRange: ClosedRange<Float> = 30...110

    // MARK: - Derived

    private var profile: Profile { state.activeProfile }

    private var targetFanIndex: Int { profile.linkFans ? 0 : selectedFan }

    private var curve: FanCurve {
        draftCurve ?? profile.config(for: targetFanIndex).curve
    }

    private var currentTemp: Float? {
        profile.sensorSource.resolve(in: state.temps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            if profile.config(for: targetFanIndex).mode != .curve {
                modeWarning
            }
            graph
                .frame(minWidth: 560, minHeight: 320)
            HStack(alignment: .top, spacing: 24) {
                tuningControls
                Spacer()
                legend
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 540)
        .onAppear { draftName = profile.name }
        .onChange(of: state.selectedProfileID) {
            draftName = profile.name
            draftCurve = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if profile.isBuiltIn {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Built-in — editing creates a copy")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Profile name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { state.renameActiveProfile(to: draftName) }
            }

            Spacer()

            Toggle("Link fans", isOn: Binding(
                get: { profile.linkFans },
                set: { linked in
                    state.updateActiveProfile { $0.linkFans = linked }
                    if linked { selectedFan = 0 }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            if !profile.linkFans && state.fanCount > 1 {
                Picker("", selection: $selectedFan) {
                    ForEach(0..<state.fanCount, id: \.self) { i in
                        Text("Fan \(i)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
                .onChange(of: selectedFan) { draftCurve = nil }
            }

            Picker("Sensor", selection: Binding(
                get: { profile.sensorSource },
                set: { source in state.updateActiveProfile { $0.sensorSource = source } }
            )) {
                ForEach(SensorGroup.allCases) { g in
                    Text(g.displayName).tag(SensorSource.group(g))
                }
                if !state.temps.isEmpty {
                    Divider()
                    ForEach(state.temps.keys.sorted(), id: \.self) { key in
                        Text(key).tag(SensorSource.key(key))
                    }
                }
            }
            .font(.system(size: 12))
            .frame(width: 170)
            .help("Which temperature drives this curve")
        }
    }

    private var modeWarning: some View {
        HStack(spacing: 8) {
            Label(
                "This fan is in \(profile.config(for: targetFanIndex).mode.displayName) mode — the curve is not driving it",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.yellow)
            Spacer()
            Button("Use Curve") {
                let target = targetFanIndex
                state.updateActiveProfile { $0.fans[target].mode = .curve }
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Graph

    private var graph: some View {
        GeometryReader { geo in
            let inset = EdgeInsets(top: 12, leading: 40, bottom: 26, trailing: 16)
            let plotRect = CGRect(
                x: inset.leading,
                y: inset.top,
                width: geo.size.width - inset.leading - inset.trailing,
                height: geo.size.height - inset.top - inset.bottom
            )

            ZStack {
                Canvas { ctx, _ in
                    drawGrid(ctx, plotRect)
                    drawCurve(ctx, plotRect)
                    drawCurrentTemp(ctx, plotRect)
                }

                // Draggable control points
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    let pos = position(of: point, in: plotRect)
                    Circle()
                        .fill(Color.orange)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: 13, height: 13)
                        .shadow(color: .orange.opacity(0.6), radius: 4)
                        .position(pos)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { drag in
                                    movePoint(index, to: drag.location, in: plotRect)
                                }
                                .onEnded { _ in commitDraft() }
                        )
                        .contextMenu {
                            Button("Delete Point", role: .destructive) {
                                deletePoint(index)
                            }
                            .disabled(curve.points.count <= 2)
                        }
                        .help(String(format: "%.0f°C → %.0f%%", point.temp, point.percent * 100))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                addPoint(at: location, in: plotRect)
            }
        }
        .background(.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ rect: CGRect) {
        let gridColor = Color.secondary.opacity(0.18)

        // Vertical lines + temp labels every 10°C
        var t = tempRange.lowerBound
        while t <= tempRange.upperBound {
            let x = xFor(t, rect)
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.stroke(line, with: .color(gridColor), lineWidth: 0.5)

            let label = state.useFahrenheit ? "\(Int(t * 9 / 5 + 32))°" : "\(Int(t))°"
            ctx.draw(
                Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: rect.maxY + 12)
            )
            t += 10
        }

        // Horizontal lines + percent labels every 20%
        for p in stride(from: 0, through: 100, by: 20) {
            let y = yFor(Float(p) / 100, rect)
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.stroke(line, with: .color(gridColor), lineWidth: 0.5)

            ctx.draw(
                Text("\(p)%").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                at: CGPoint(x: rect.minX - 20, y: y)
            )
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, _ rect: CGRect) {
        guard !curve.points.isEmpty else { return }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: yFor(curve.percent(at: tempRange.lowerBound), rect)))
        for point in curve.points where tempRange.contains(point.temp) {
            path.addLine(to: position(of: point, in: rect))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: yFor(curve.percent(at: tempRange.upperBound), rect)))

        // Gradient fill under the curve
        var fill = path
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        fill.closeSubpath()
        ctx.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        ctx.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }

    private func drawCurrentTemp(_ ctx: GraphicsContext, _ rect: CGRect) {
        guard let temp = currentTemp, tempRange.contains(temp) else { return }
        let x = xFor(temp, rect)

        var line = Path()
        line.move(to: CGPoint(x: x, y: rect.minY))
        line.addLine(to: CGPoint(x: x, y: rect.maxY))
        ctx.stroke(line, with: .color(.cyan.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        ctx.draw(
            Text(formatTemp(temp, fahrenheit: state.useFahrenheit, decimals: 0))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.cyan),
            at: CGPoint(x: x, y: rect.minY - 4)
        )
    }

    // MARK: - Coordinate Mapping

    private func xFor(_ temp: Float, _ rect: CGRect) -> CGFloat {
        let fraction = CGFloat((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound))
        return rect.minX + fraction * rect.width
    }

    private func yFor(_ percent: Float, _ rect: CGRect) -> CGFloat {
        rect.minY + CGFloat(1 - min(max(percent, 0), 1)) * rect.height
    }

    private func position(of point: CurvePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: xFor(point.temp, rect), y: yFor(point.percent, rect))
    }

    private func tempAt(_ x: CGFloat, _ rect: CGRect) -> Float {
        let fraction = Float((x - rect.minX) / rect.width)
        return tempRange.lowerBound + min(max(fraction, 0), 1) * (tempRange.upperBound - tempRange.lowerBound)
    }

    private func percentAt(_ y: CGFloat, _ rect: CGRect) -> Float {
        1 - Float(min(max((y - rect.minY) / rect.height, 0), 1))
    }

    // MARK: - Editing

    private func movePoint(_ index: Int, to location: CGPoint, in rect: CGRect) {
        var points = curve.points
        guard index < points.count else { return }

        var temp = tempAt(location.x, rect)
        // Keep points ordered with 1°C spacing
        if index > 0 { temp = max(temp, points[index - 1].temp + 1) }
        if index < points.count - 1 { temp = min(temp, points[index + 1].temp - 1) }

        points[index] = CurvePoint(temp: temp.rounded(), percent: percentAt(location.y, rect))
        var updated = curve
        updated.setPoints(points)
        draftCurve = updated
    }

    private func addPoint(at location: CGPoint, in rect: CGRect) {
        guard rect.insetBy(dx: -8, dy: -8).contains(location) else { return }
        var points = curve.points
        let temp = tempAt(location.x, rect).rounded()
        guard !points.contains(where: { abs($0.temp - temp) < 1 }) else { return }
        points.append(CurvePoint(temp: temp, percent: percentAt(location.y, rect)))
        var updated = curve
        updated.setPoints(points)
        draftCurve = updated
        commitDraft()
    }

    private func deletePoint(_ index: Int) {
        var points = curve.points
        guard points.count > 2, index < points.count else { return }
        points.remove(at: index)
        var updated = curve
        updated.setPoints(points)
        draftCurve = updated
        commitDraft()
    }

    private func commitDraft() {
        guard let newCurve = draftCurve else { return }
        let target = targetFanIndex
        state.updateActiveProfile {
            $0.fans[target].curve = newCurve
            // Editing a curve means you want it active — Auto would silently ignore it
            if $0.fans[target].mode == .auto { $0.fans[target].mode = .curve }
        }
        draftCurve = nil
    }

    // MARK: - Tuning + Legend

    private var tuningControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            tuningRow("Engage after", value: Binding(
                get: { profile.sustainSec },
                set: { v in state.updateActiveProfile(save: false) { $0.sustainSec = v } }
            ), range: 0...15, format: "%.0f s")

            tuningRow("Hysteresis", value: Binding(
                get: { profile.hysteresis },
                set: { v in state.updateActiveProfile(save: false) { $0.hysteresis = v } }
            ), range: 2...10, format: "%.0f °C")

            tuningRow("Ramp up", value: Binding(
                get: { profile.rampUpPerSec * 100 },
                set: { v in state.updateActiveProfile(save: false) { $0.rampUpPerSec = v / 100 } }
            ), range: 1...100, format: "%.0f %%/s")

            tuningRow("Ramp down", value: Binding(
                get: { profile.rampDownPerSec * 100 },
                set: { v in state.updateActiveProfile(save: false) { $0.rampDownPerSec = v / 100 } }
            ), range: 1...100, format: "%.0f %%/s")
        }
        .frame(width: 320)
    }

    private func tuningRow(_ label: String, value: Binding<Float>,
                           range: ClosedRange<Float>, format: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Slider(value: value, in: range) { editing in
                if !editing { state.updateActiveProfile { _ in } }
            }
            .controlSize(.mini)
            .frame(width: 150)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    private var legend: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label("Double-click to add a point", systemImage: "plus.circle")
            Label("Right-click a point to delete", systemImage: "minus.circle")
            Label("Dashed line = current temp", systemImage: "thermometer.medium")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
    }
}
