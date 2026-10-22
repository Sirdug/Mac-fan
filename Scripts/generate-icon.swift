#!/usr/bin/swift
//
//  generate-icon.swift
//  Mac Fan
//
//  Renders the app icon (orange fan on dark glass) into MacFan.iconset/.
//  Run from the repo root:  swift Scripts/generate-icon.swift
//  Then:                    iconutil -c icns MacFan.iconset -o MacFan.icns
//

import AppKit

func draw(size s: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // Background: dark rounded square with a subtle vertical gradient
    let inset = s * 0.055
    let bgRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.21, yRadius: s * 0.21)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // Fan blades
    let center = CGPoint(x: s / 2, y: s / 2)
    let bladeColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1)

    for i in 0..<3 {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(i) * (2 * .pi / 3))

        // Teardrop blade: ellipse offset from the hub, slightly skewed
        let blade = NSBezierPath()
        blade.move(to: CGPoint(x: 0, y: s * 0.06))
        blade.curve(
            to: CGPoint(x: 0, y: s * 0.36),
            controlPoint1: CGPoint(x: s * 0.17, y: s * 0.10),
            controlPoint2: CGPoint(x: s * 0.15, y: s * 0.34)
        )
        blade.curve(
            to: CGPoint(x: 0, y: s * 0.06),
            controlPoint1: CGPoint(x: -s * 0.13, y: s * 0.35),
            controlPoint2: CGPoint(x: -s * 0.11, y: s * 0.10)
        )
        blade.close()
        bladeColor.setFill()
        blade.fill()
        ctx.restoreGState()
    }

    // Hub
    let hubRadius = s * 0.085
    let hub = NSBezierPath(ovalIn: CGRect(
        x: center.x - hubRadius, y: center.y - hubRadius,
        width: hubRadius * 2, height: hubRadius * 2))
    bladeColor.setFill()
    hub.fill()

    let holeRadius = s * 0.032
    let hole = NSBezierPath(ovalIn: CGRect(
        x: center.x - holeRadius, y: center.y - holeRadius,
        width: holeRadius * 2, height: holeRadius * 2))
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    hole.fill()
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    draw(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let iconset = "MacFan.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    guard let png = render(pixels: entry.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(entry.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(iconset)/\(entry.name).png")
    try png.write(to: url)
}

print("Wrote \(entries.count) images to \(iconset)/")
