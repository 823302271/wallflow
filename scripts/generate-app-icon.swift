#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO

// Export the checked-in artwork without regenerating its design.
private let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

private func renderIcon(_ artwork: CGImage, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let context = graphics.cgContext
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.clear(bounds)
    context.interpolationQuality = .high
    context.draw(artwork, in: bounds)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appBundleSource = projectRoot.appendingPathComponent("AppBundle", isDirectory: true)
let artworkURL = appBundleSource.appendingPathComponent("AppIcon-artwork.png")
let iconsetURL = appBundleSource.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let masterURL = appBundleSource.appendingPathComponent("AppIcon-1024.png")
let icnsURL = appBundleSource.appendingPathComponent("AppIcon.icns")

guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else {
    fatalError("A square AppBundle/AppIcon-artwork.png is required.")
}

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }
for (fileName, pixels) in specs {
    let data = try renderIcon(artwork, pixels: pixels)
    try data.write(to: iconsetURL.appendingPathComponent(fileName), options: .atomic)
    if pixels == 1024 { try data.write(to: masterURL, options: .atomic) }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
print(masterURL.path)
print(icnsURL.path)
