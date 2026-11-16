//
//  MiniGraph.swift
//  Mac Fan
//
//  Smoothed history graph used by the dashboard tiles and the detail monitors.
//

import SwiftUI

struct MiniGraph: View {
    enum Style {
        /// Bare sparkline for the small dashboard tiles.
        case compact
        /// Gridlines, axis labels and a hover readout for the detail monitors.
        case detailed
    }

    let values: [Double]
    let color: Color
    /// Top of the scale. `nil` picks a round number above the recent peak.
    let fixedMaximum: Double?
    /// Number of samples a full history holds. Samples are pinned to the right
    /// edge, so the line grows in from "now" instead of stretching to fit.
    var capacity: Int? = nil
    var style: Style = .compact
    /// Seconds covered by a full history, for the time axis and hover readout.
    var span: Double = 60
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    @State private var hoverX: CGFloat?

    var body: some View {
        Canvas { context, size in
            let rect = plotRect(in: size)
            guard rect.width > 0, rect.height > 0 else { return }
            drawGrid(context, rect)
            let points = points(in: rect)
            drawSeries(context, rect, points)
            if style == .detailed, let hoverX {
                drawHover(context, rect, points, at: hoverX)
            }
        }
        .onContinuousHover { phase in
            guard style == .detailed else { return }
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    private func plotRect(in size: CGSize) -> CGRect {
        let insets: EdgeInsets = style == .detailed
            ? EdgeInsets(top: 5, leading: 0, bottom: 13, trailing: 27)
            : EdgeInsets(top: 4, leading: 0, bottom: 1, trailing: 5)
        return CGRect(
            x: insets.leading,
            y: insets.top,
            width: size.width - insets.leading - insets.trailing,
            height: size.height - insets.top - insets.bottom
        )
    }

    private var slots: Int {
        max(capacity ?? values.count, values.count, 2)
    }

    private var maximum: Double {
        if let fixedMaximum { return max(fixedMaximum, 0.001) }
        // Snap to a round ceiling so the scale holds still while values wobble.
        let peak = (values.filter(\.isFinite).max() ?? 0) * 1.1
        let ceilings: [Double] = [5, 10, 15, 20, 30, 40, 60, 80, 100, 150, 200, 300]
        return ceilings.first { $0 >= peak } ?? max(peak, 0.001)
    }

    private func points(in rect: CGRect) -> [CGPoint] {
        let step = rect.width / CGFloat(slots - 1)
        let top = maximum
        return values.enumerated().map { index, raw in
            let value = raw.isFinite ? min(max(raw / top, 0), 1) : 0
            return CGPoint(
                x: rect.maxX - CGFloat(values.count - 1 - index) * step,
                y: rect.maxY - CGFloat(value) * rect.height
            )
        }
    }

    /// Monotone cubic interpolation: rounds the corners without overshooting
    /// the samples, so the line never dips below zero or pokes above the scale.
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let count = points.count
        guard count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        let secants = (0..<count - 1).map { index in
            (points[index + 1].y - points[index].y) / (points[index + 1].x - points[index].x)
        }
        var slopes = [CGFloat](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        for index in 1..<count - 1 {
            let before = secants[index - 1], after = secants[index]
            slopes[index] = before * after <= 0 ? 0 : 2 * before * after / (before + after)
        }

        for index in 0..<count - 1 {
            let start = points[index], end = points[index + 1]
            let third = (end.x - start.x) / 3
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + third, y: start.y + slopes[index] * third),
                control2: CGPoint(x: end.x - third, y: end.y - slopes[index + 1] * third)
            )
        }
        return path
    }

    // MARK: - Drawing

    private func drawGrid(_ context: GraphicsContext, _ rect: CGRect) {
        func horizontal(_ fraction: CGFloat, opacity: Double, dashed: Bool = false) {
            let y = rect.maxY - fraction * rect.height
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(
                line,
                with: .color(.primary.opacity(opacity)),
                style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [2, 3] : [])
            )
        }

        guard style == .detailed else {
            horizontal(0, opacity: 0.14)
            horizontal(0.5, opacity: 0.08, dashed: true)
            return
        }

        for fraction in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let major = fraction == 0 || fraction == 0.5 || fraction == 1
            horizontal(fraction, opacity: major ? 0.14 : 0.07, dashed: fraction != 0)
            if major {
                context.draw(
                    axisLabel(format(maximum * Double(fraction))),
                    at: CGPoint(x: rect.maxX + 5, y: rect.maxY - fraction * rect.height),
                    anchor: .leading
                )
            }
        }

        for quarter in 0...4 {
            let fraction = CGFloat(quarter) / 4
            let x = rect.minX + fraction * rect.width
            if quarter > 0 && quarter < 4 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: rect.minY))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(line, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            }
            let secondsAgo = Int((span * Double(4 - quarter) / 4).rounded())
            let anchor: UnitPoint = quarter == 0 ? .topLeading : quarter == 4 ? .topTrailing : .top
            context.draw(
                axisLabel(secondsAgo == 0 ? "now" : "\(secondsAgo)s"),
                at: CGPoint(x: x, y: rect.maxY + 4),
                anchor: anchor
            )
        }
    }

    private func axisLabel(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func drawSeries(_ context: GraphicsContext, _ rect: CGRect, _ points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        let detailed = style == .detailed
        let line = smoothPath(points)

        if points.count > 1 {
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(0.34), location: 0),
                        .init(color: color.opacity(0.10), location: 0.6),
                        .init(color: color.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )

            // Soft glow under the line.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: detailed ? 4 : 2.5))
                layer.stroke(line, with: .color(color.opacity(0.5)), lineWidth: detailed ? 3 : 2)
            }

            // Older samples fade out towards the left edge.
            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.35), color]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                ),
                style: StrokeStyle(lineWidth: detailed ? 2 : 1.5, lineCap: .round, lineJoin: .round)
            )
        }

        // Marker on the newest sample.
        let radius: CGFloat = detailed ? 3 : 2
        context.fill(circle(at: last, radius: radius * 2.2), with: .color(color.opacity(0.22)))
        context.fill(circle(at: last, radius: radius), with: .color(color))
        context.fill(circle(at: last, radius: radius * 0.4), with: .color(.white.opacity(0.9)))
    }

    private func drawHover(_ context: GraphicsContext, _ rect: CGRect, _ points: [CGPoint], at x: CGFloat) {
        guard let first = points.first, !values.isEmpty else { return }
        let step = rect.width / CGFloat(slots - 1)
        let index = min(max(Int(((x - first.x) / step).rounded()), 0), points.count - 1)
        let point = points[index]

        var rule = Path()
        rule.move(to: CGPoint(x: point.x, y: rect.minY))
        rule.addLine(to: CGPoint(x: point.x, y: rect.maxY))
        context.stroke(rule, with: .color(.primary.opacity(0.35)), lineWidth: 0.75)
        context.fill(circle(at: point, radius: 4), with: .color(.white))
        context.fill(circle(at: point, radius: 2.5), with: .color(color))

        let secondsAgo = Int((Double(points.count - 1 - index) * span / Double(slots - 1)).rounded())
        let when = secondsAgo == 0 ? "now" : "\(secondsAgo)s ago"
        let label = context.resolve(
            Text("\(format(values[index])) · \(when)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        )
        let textSize = label.measure(in: rect.size)
        let pill = CGSize(width: textSize.width + 10, height: textSize.height + 5)
        let pillX = min(max(point.x - pill.width / 2, rect.minX), rect.maxX - pill.width)
        // Sit above the point, or below it when there is no room.
        let above = point.y - pill.height - 7
        let pillY = above >= 0 ? above : point.y + 7
        let pillRect = CGRect(origin: CGPoint(x: pillX, y: pillY), size: pill)
        context.fill(
            Path(roundedRect: pillRect, cornerRadius: pill.height / 2),
            with: .color(.black.opacity(0.72))
        )
        context.draw(label, at: CGPoint(x: pillRect.midX, y: pillRect.midY))
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}
