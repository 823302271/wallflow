import AppKit
import Foundation
import QuartzCore

/// Headless particle render verification: force-emits, ticks, and dumps a PNG.
enum WallflowParticleDumpTest {
    static func run(projectPath: String, outputPath: String) throws {
        let project = try WallpaperProjectLoader.load(URL(fileURLWithPath: projectPath))
        guard project.kind == .scene else {
            throw WallflowSelfTestError.failed("Not a scene project: \(project.kind)")
        }

        let size = CGSize(width: 1280, height: 720)
        let frame = CGRect(origin: .zero, size: size)
        let view = SceneWallpaperView(
            frame: frame,
            desktopFrame: frame,
            project: project,
            playsAudio: false,
            fitMode: .fill
        )
        view.layoutSubtreeIfNeeded()
        view.setRenderingEnabled(true, completion: nil)

        // Drive particles without relying on real cursor / desktop coverage.
        let points: [CGPoint] = (0..<40).map { i in
            CGPoint(x: 200 + CGFloat(i) * 22, y: 360 + sin(CGFloat(i) * 0.4) * 80)
        }
        for (index, point) in points.enumerated() {
            view.debugDriveParticles(
                point: point,
                inDesktop: true,
                delta: 1.0 / 20.0
            )
            if index == 0 {
                // Bypass starttime for dump by advancing many ticks if needed
                for _ in 0..<30 {
                    view.debugDriveParticles(point: point, inDesktop: true, delta: 0.05)
                }
            }
        }

        let count = view.debugParticleCount()
        guard count > 0 else {
            throw WallflowSelfTestError.failed("No particles were spawned (count=0)")
        }

        // Dump raw sprite frames the runtime actually uses (prove texture fidelity).
        let framesDir = (outputPath as NSString).deletingLastPathComponent
        view.debugExportSpriteFrames(toDirectory: framesDir)

        // Dump particle host layer alone (proves CALayer petal presentation).
        if let onlyParticles = view.debugSnapshotParticlesOnly() {
            let particleOnlyPath = (outputPath as NSString).deletingPathExtension + "-particles-only.png"
            try writePNG(onlyParticles, to: particleOnlyPath)
            print("Wallflow particle-only dump: \(particleOnlyPath)")
        }

        guard let image = snapshot(view: view) else {
            throw WallflowSelfTestError.failed("Failed to snapshot SceneWallpaperView")
        }
        try writePNG(image, to: outputPath)
        print("Wallflow particle dump: particles=\(count) output=\(outputPath)")
    }

    private static func writePNG(_ image: NSImage, to path: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WallflowSelfTestError.failed("Failed to encode PNG")
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    private static func snapshot(view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
