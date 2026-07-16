#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconSpec {
    let fileName: String
    let pixels: Int
}

private let specs = [
    IconSpec(fileName: "icon_16x16.png", pixels: 16),
    IconSpec(fileName: "icon_16x16@2x.png", pixels: 32),
    IconSpec(fileName: "icon_32x32.png", pixels: 32),
    IconSpec(fileName: "icon_32x32@2x.png", pixels: 64),
    IconSpec(fileName: "icon_128x128.png", pixels: 128),
    IconSpec(fileName: "icon_128x128@2x.png", pixels: 256),
    IconSpec(fileName: "icon_256x256.png", pixels: 256),
    IconSpec(fileName: "icon_256x256@2x.png", pixels: 512),
    IconSpec(fileName: "icon_512x512.png", pixels: 512),
    IconSpec(fileName: "icon_512x512@2x.png", pixels: 1024)
]

private func color(
    _ red: CGFloat,
    _ green: CGFloat,
    _ blue: CGFloat,
    _ alpha: CGFloat = 1
) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func wavePath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 175, y: 420))
    path.addCurve(
        to: CGPoint(x: 405, y: 310),
        control1: CGPoint(x: 255, y: 420),
        control2: CGPoint(x: 290, y: 300)
    )
    path.addCurve(
        to: CGPoint(x: 610, y: 670),
        control1: CGPoint(x: 505, y: 320),
        control2: CGPoint(x: 515, y: 670)
    )
    path.addCurve(
        to: CGPoint(x: 842, y: 550),
        control1: CGPoint(x: 700, y: 670),
        control2: CGPoint(x: 748, y: 545)
    )
    return path
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let tile = CGPath(
        roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880),
        cornerWidth: 205,
        cornerHeight: 205,
        transform: nil
    )
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            color(9, 18, 22),
            color(18, 48, 54),
            color(12, 29, 35)
        ] as CFArray,
        locations: [0, 0.56, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 150, y: 110),
        end: CGPoint(x: 850, y: 930),
        options: []
    )
    context.setFillColor(color(255, 255, 255, 0.04))
    context.fillEllipse(in: CGRect(x: 120, y: 600, width: 500, height: 500))
    context.setFillColor(color(0, 0, 0, 0.13))
    context.fillEllipse(in: CGRect(x: 500, y: -40, width: 620, height: 620))
    context.restoreGState()

    context.addPath(tile)
    context.setStrokeColor(color(255, 255, 255, 0.10))
    context.setLineWidth(8)
    context.strokePath()

    let wave = wavePath()
    context.saveGState()
    context.translateBy(x: 0, y: -22)
    context.addPath(wave)
    context.setStrokeColor(color(0, 0, 0, 0.34))
    context.setLineWidth(142)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    context.addPath(wave)
    context.setStrokeColor(color(35, 157, 176))
    context.setLineWidth(128)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    context.addPath(wave)
    context.setStrokeColor(color(116, 240, 194))
    context.setLineWidth(72)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    context.setStrokeColor(color(255, 118, 108, 0.30))
    context.setLineWidth(18)
    context.strokeEllipse(in: CGRect(x: 678, y: 706, width: 178, height: 178))
    context.setStrokeColor(color(255, 118, 108, 0.55))
    context.setLineWidth(20)
    context.strokeEllipse(in: CGRect(x: 708, y: 736, width: 118, height: 118))
    context.setFillColor(color(255, 118, 108))
    context.fillEllipse(in: CGRect(x: 748, y: 776, width: 38, height: 38))
    context.setFillColor(color(255, 244, 222, 0.92))
    context.fillEllipse(in: CGRect(x: 758, y: 786, width: 14, height: 14))

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

private func runIconUtil(iconsetURL: URL, outputURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appBundleSource = projectRoot.appendingPathComponent("AppBundle", isDirectory: true)
let iconsetURL = appBundleSource.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let masterURL = appBundleSource.appendingPathComponent("AppIcon-1024.png")
let icnsURL = appBundleSource.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for spec in specs {
    let data = try renderIcon(pixels: spec.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(spec.fileName), options: .atomic)
    if spec.pixels == 1024 {
        try data.write(to: masterURL, options: .atomic)
    }
}

try runIconUtil(iconsetURL: iconsetURL, outputURL: icnsURL)
try FileManager.default.removeItem(at: iconsetURL)
print(masterURL.path)
print(icnsURL.path)
