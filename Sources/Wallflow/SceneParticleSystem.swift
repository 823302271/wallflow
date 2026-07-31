import AppKit
import CoreGraphics
import QuartzCore

// MARK: - Config model (Wallpaper Engine conventions)

/// Config-driven WE particle system. Runtime only applies fields present in
/// `scene.json` / `particles/*.json` / materials / texture metadata.
///
/// Texture resolution order (all wallpapers):
/// 1. `scene.pkg`  2. project folder  3. EngineAssets pack  4. placeholder
struct SceneParticleSystem: Equatable {
    struct Emitter: Equatable {
        let name: String
        let rate: Double
        let distanceMin: Double
        let distanceMax: Double
        let directions: [Double]
    }

    struct Range1D: Equatable {
        let min: Double
        let max: Double
        let exponent: Double
    }

    struct Range3D: Equatable {
        let min: [Double]
        let max: [Double]
    }

    struct AlphaFade: Equatable {
        let fadeIn: Double
        let fadeOut: Double
    }

    struct SizeChange: Equatable {
        let startScale: Double
        let endScale: Double
    }

    struct AngularMovement: Equatable {
        let force: [Double]
    }

    struct Visibility: Equatable {
        let userPropertyKey: String?
        let defaultValue: Bool
    }

    let id: Int
    let name: String
    let origin: [Double]
    let maxCount: Int
    let startTime: Double
    let followMouse: Bool
    let instanceSize: Double
    let randomFrame: Bool
    let emitter: Emitter
    let lifetime: Range1D
    let size: Range1D
    let velocity: Range3D
    let color: Range3D
    let rotation: Range1D?
    let angularVelocity: Range3D?
    let drag: Double
    let alphaFade: AlphaFade?
    let sizeChange: SizeChange?
    let angularMovement: AngularMovement?
    let materialPath: String?
    let textureHint: String?
    let visibility: Visibility
}

enum SceneParticleParser {
    static func parse(
        object: [String: Any],
        package: ScenePackage
    ) -> SceneParticleSystem? {
        guard let particlePath = object["particle"] as? String else { return nil }
        guard let definition = jsonDictionary(package: package, path: particlePath) else {
            return nil
        }

        let visibility = parseVisibility(object["visible"])
        let controlPoints = definition["controlpoint"] as? [[String: Any]] ?? []
        let followMouse = controlPoints.contains {
            (($0["flags"] as? NSNumber)?.intValue ?? 0) != 0
        }

        let primary = (definition["emitter"] as? [[String: Any]])?.first
        let emitter = SceneParticleSystem.Emitter(
            name: (primary?["name"] as? String ?? "sphererandom").lowercased(),
            rate: max(double(primary?["rate"], fallback: 0), 0),
            distanceMin: max(double(primary?["distancemin"], fallback: 0), 0),
            distanceMax: max(
                double(primary?["distancemax"], fallback: 0),
                double(primary?["distancemin"], fallback: 0)
            ),
            directions: doubleArray(primary?["directions"], fallback: [1, 1, 1])
        )

        var lifetime = SceneParticleSystem.Range1D(min: 1, max: 1, exponent: 1)
        var size = SceneParticleSystem.Range1D(min: 20, max: 20, exponent: 1)
        var velocity = SceneParticleSystem.Range3D(min: [0, 0, 0], max: [0, 0, 0])
        var color = SceneParticleSystem.Range3D(min: [255, 255, 255], max: [255, 255, 255])
        var rotation: SceneParticleSystem.Range1D?
        var angularVelocity: SceneParticleSystem.Range3D?

        for initializer in definition["initializer"] as? [[String: Any]] ?? [] {
            switch (initializer["name"] as? String ?? "").lowercased() {
            case "lifetimerandom":
                lifetime = .init(
                    min: double(initializer["min"], fallback: 1),
                    max: double(initializer["max"], fallback: 1),
                    exponent: double(initializer["exponent"], fallback: 1)
                )
            case "sizerandom":
                size = .init(
                    min: double(initializer["min"], fallback: 20),
                    max: double(initializer["max"], fallback: 20),
                    exponent: double(initializer["exponent"], fallback: 1)
                )
            case "velocityrandom":
                velocity = .init(
                    min: doubleArray(initializer["min"], fallback: [0, 0, 0]),
                    max: doubleArray(initializer["max"], fallback: [0, 0, 0])
                )
            case "colorrandom":
                color = .init(
                    min: doubleArray(initializer["min"], fallback: [255, 255, 255]),
                    max: doubleArray(initializer["max"], fallback: [255, 255, 255])
                )
            case "rotationrandom":
                rotation = .init(
                    min: double(initializer["min"], fallback: 0),
                    max: double(initializer["max"], fallback: 0),
                    exponent: double(initializer["exponent"], fallback: 1)
                )
            case "angularvelocityrandom":
                angularVelocity = .init(
                    min: doubleArray(initializer["min"], fallback: [0, 0, 0]),
                    max: doubleArray(initializer["max"], fallback: [0, 0, 0])
                )
            default:
                break
            }
        }

        var drag = 0.0
        var alphaFade: SceneParticleSystem.AlphaFade?
        var sizeChange: SceneParticleSystem.SizeChange?
        var angularMovement: SceneParticleSystem.AngularMovement?

        for op in definition["operator"] as? [[String: Any]] ?? [] {
            switch (op["name"] as? String ?? "").lowercased() {
            case "movement":
                drag = min(max(double(op["drag"], fallback: 0), 0), 0.99)
            case "alphafade":
                alphaFade = .init(
                    fadeIn: max(double(op["fadeintime"], fallback: 0), 0),
                    fadeOut: max(double(op["fadeouttime"], fallback: 0), 0)
                )
            case "sizechange":
                let start = double(op["scale"] ?? op["startscale"] ?? op["start"], fallback: 1)
                let end = double(
                    op["endscale"] ?? op["scaleend"] ?? op["end"] ?? op["scale"],
                    fallback: start
                )
                sizeChange = .init(startScale: start, endScale: end)
            case "angularmovement":
                angularMovement = .init(force: doubleArray(op["force"], fallback: [0, 0, 0]))
            default:
                break
            }
        }

        let materialPath = definition["material"] as? String
        let textureHint = resolveTextureHint(materialPath: materialPath, package: package)
        let override = object["instanceoverride"] as? [String: Any]
        let instanceSize = max(double(override?["size"], fallback: 1), 0.01)
        let randomFrame = (definition["animationmode"] as? String ?? "")
            .lowercased()
            .contains("random")

        return SceneParticleSystem(
            id: (object["id"] as? NSNumber)?.intValue ?? 0,
            name: object["name"] as? String ?? particlePath,
            origin: doubleArray(object["origin"], fallback: [0, 0, 0]),
            maxCount: max((definition["maxcount"] as? NSNumber)?.intValue ?? 100, 1),
            startTime: max(double(definition["starttime"], fallback: 0), 0),
            followMouse: followMouse,
            instanceSize: instanceSize,
            randomFrame: randomFrame,
            emitter: emitter,
            lifetime: lifetime,
            size: size,
            velocity: velocity,
            color: color,
            rotation: rotation,
            angularVelocity: angularVelocity,
            drag: drag,
            alphaFade: alphaFade,
            sizeChange: sizeChange,
            angularMovement: angularMovement,
            materialPath: materialPath,
            textureHint: textureHint,
            visibility: visibility
        )
    }

    private static func parseVisibility(_ value: Any?) -> SceneParticleSystem.Visibility {
        if let number = value as? NSNumber {
            return .init(userPropertyKey: nil, defaultValue: number.boolValue)
        }
        if let object = value as? [String: Any] {
            return .init(
                userPropertyKey: object["user"] as? String,
                defaultValue: (object["value"] as? NSNumber)?.boolValue ?? true
            )
        }
        return .init(userPropertyKey: nil, defaultValue: true)
    }

    private static func resolveTextureHint(
        materialPath: String?,
        package: ScenePackage
    ) -> String? {
        guard let materialPath,
              let material = jsonDictionary(package: package, path: materialPath) else {
            return nil
        }
        let names: [String]
        if let top = material["textures"] as? [Any] {
            names = top.compactMap { $0 as? String }
        } else if let passes = material["passes"] as? [[String: Any]] {
            names = passes.flatMap {
                ($0["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
            }
        } else {
            names = []
        }
        return names.first { !$0.isEmpty && !$0.hasPrefix("_rt_") }
    }

    private static func double(_ value: Any?, fallback: Double) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String,
           let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return fallback
    }

    private static func doubleArray(_ value: Any?, fallback: [Double]) -> [Double] {
        if let values = value as? [Any] {
            let result = values.map { double($0, fallback: .nan) }.filter { !$0.isNaN }
            if !result.isEmpty { return result }
        }
        if let string = value as? String {
            let parts = string
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                .compactMap { Double($0) }
            if !parts.isEmpty { return parts }
        }
        return fallback
    }

    private static func jsonDictionary(
        package: ScenePackage,
        path: String
    ) -> [String: Any]? {
        guard let data = try? package.data(forPath: path),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return value as? [String: Any]
    }
}

// MARK: - Runtime (CALayer presentation — reliable on desktop windows)

final class SceneParticleRuntime {
    private struct Particle {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var baseSize: CGFloat
        var life: CGFloat
        var maxLife: CGFloat
        var roll: CGFloat
        var rollSpeed: CGFloat
        var spriteIndex: Int
    }

    private let model: SceneParticleSystem
    private let hostLayer = CALayer()
    private var particleLayers: [CALayer] = []
    private var particles: [Particle] = []
    private var sprites: [CGImage]
    private var spritePixelSize: CGSize
    /// For `animationmode: randomframe`: draw without replacement so trails don't
    /// spam the same petal pose. Config mode is still random, just de-clustered.
    private var frameDrawBag: [Int] = []
    private var emitAccumulator: Double = 0
    private var mouseMovedThisTick = false
    private var hasMouseSample = false
    private var elapsed: Double = 0
    private var isEnabled = true
    private var isVisible = true
    private var mouseInDesktop = false
    private var mousePoint = CGPoint.zero
    private var sceneToViewScale: CGFloat = 1
    private var canvasSize = CGSize(width: 1920, height: 1080)
    private var viewBounds = CGRect.zero

    var layer: CALayer { hostLayer }

    init(model: SceneParticleSystem, package: ScenePackage?, rootURL: URL?) {
        self.model = model
        if let loaded = Self.loadSprites(model: model, package: package, rootURL: rootURL),
           !loaded.isEmpty {
            sprites = Self.deduplicateFrames(loaded)
        } else {
            sprites = Self.makePlaceholderFrames()
        }
        if let first = sprites.first {
            spritePixelSize = CGSize(width: first.width, height: first.height)
        } else {
            spritePixelSize = CGSize(width: 64, height: 64)
        }
        frameDrawBag = Array(0..<sprites.count).shuffled()

        hostLayer.name = "wallflow.particles.\(model.id)"
        hostLayer.isOpaque = false
        hostLayer.backgroundColor = NSColor.clear.cgColor
        hostLayer.masksToBounds = false
        hostLayer.zPosition = 10_000
        hostLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        hostLayer.actions = [
            "contents": NSNull(),
            "sublayers": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]

        isVisible = model.visibility.defaultValue
        hostLayer.isHidden = !isVisible
        NSLog(
            "Wallflow particles '%@': %d unique frame(s), randomFrame=%d, followMouse=%d, rate=%.1f",
            model.name,
            sprites.count,
            model.randomFrame ? 1 : 0,
            model.followMouse ? 1 : 0,
            model.emitter.rate
        )
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        hostLayer.isHidden = !visible || !isEnabled
        if !visible {
            particles.removeAll(keepingCapacity: true)
            clearLayers()
            emitAccumulator = 0
            mouseMovedThisTick = false
            hasMouseSample = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        hostLayer.isHidden = !enabled || !isVisible
        if !enabled {
            // Keep last frame visually frozen under host freeze overlay.
        }
    }

    func updateLayout(
        viewBounds: CGRect,
        canvasSize: CGSize,
        sceneScale: CGFloat
    ) {
        self.viewBounds = viewBounds
        self.canvasSize = canvasSize
        self.sceneToViewScale = sceneScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.frame = viewBounds
        hostLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func updateMouse(desktopPoint: CGPoint?, inDesktop: Bool) {
        mouseInDesktop = inDesktop
        if let desktopPoint {
            if model.followMouse, hasMouseSample, inDesktop {
                let step = hypot(desktopPoint.x - mousePoint.x, desktopPoint.y - mousePoint.y)
                if step >= 1.0 {
                    mouseMovedThisTick = true
                }
            }
            mousePoint = desktopPoint
            hasMouseSample = true
        }
        if !inDesktop {
            mouseMovedThisTick = false
            hasMouseSample = false
            emitAccumulator = 0
        }
    }

    func tick(delta: TimeInterval) {
        guard isEnabled, isVisible else { return }
        elapsed += delta
        if elapsed < model.startTime {
            mouseMovedThisTick = false
            return
        }
        let dt = CGFloat(delta)
        emit(delta: delta)
        mouseMovedThisTick = false
        integrate(delta: dt)
        syncLayers()
    }

    func debugBypassStartTime() {
        elapsed = max(elapsed, model.startTime + 0.01)
    }

    func debugParticleCount() -> Int { particles.count }

    func debugExportFrames(toDirectory directory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (index, cg) in sprites.enumerated() {
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                continue
            }
            let path = (directory as NSString).appendingPathComponent("runtime_frame_\(index).png")
            try? png.write(to: URL(fileURLWithPath: path))
            print("exported \(path) \(cg.width)x\(cg.height)")
        }
    }

    // MARK: - Simulation (config only)

    private func emit(delta: TimeInterval) {
        let origin: CGPoint
        if model.followMouse {
            guard mouseInDesktop, hasMouseSample else { return }
            origin = mousePoint
            // Moving: use config rate; idle: almost no emit (avoids pile + CPU).
            let rateScale = mouseMovedThisTick ? 0.45 : 0.0
            emitAccumulator += model.emitter.rate * delta * rateScale
        } else {
            origin = fixedOriginInView()
            emitAccumulator += model.emitter.rate * delta * 0.45
        }
        // Hard cap: at most 1 spawn per tick (~12 Hz).
        let budget = min(Int(emitAccumulator), 1)
        guard budget > 0 else { return }
        emitAccumulator -= Double(budget)
        for _ in 0..<budget {
            spawn(at: origin)
        }
    }

    private func integrate(delta dt: CGFloat) {
        // movement.drag: continuous exponential damping (not per-frame * (1-drag)).
        let drag = min(max(model.drag, 0), 0.99)
        let damping = CGFloat(exp(-drag * 2.0 * Double(dt)))
        let forceZ = CGFloat(model.angularMovement?.force[safe: 2] ?? 0)

        var next: [Particle] = []
        next.reserveCapacity(particles.count)
        for var p in particles {
            p.life -= dt
            guard p.life > 0 else { continue }
            p.vx *= damping
            p.vy *= damping
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.rollSpeed += forceZ * dt
            p.roll += p.rollSpeed * dt
            next.append(p)
        }
        particles = next
    }

    func clearParticles() {
        particles.removeAll(keepingCapacity: true)
        clearLayers()
        emitAccumulator = 0
        frameDrawBag = Array(0..<sprites.count).shuffled()
    }

    /// `randomframe`: random order without immediate repeats (reshuffle bag).
    /// Other modes: always frame 0 (WE default first frame).
    private func nextSpriteIndex() -> Int {
        guard sprites.count > 1 else { return 0 }
        guard model.randomFrame else { return 0 }
        if frameDrawBag.isEmpty {
            frameDrawBag = Array(0..<sprites.count).shuffled()
        }
        return frameDrawBag.removeLast()
    }

    /// Drop near-duplicate crops (invalid TEXS frames that clamped to the same region).
    private static func deduplicateFrames(_ frames: [CGImage]) -> [CGImage] {
        guard frames.count > 1 else { return frames }
        var unique: [CGImage] = []
        for frame in frames {
            let isDup = unique.contains { existing in
                existing.width == frame.width
                    && existing.height == frame.height
                    && framesLookSimilar(existing, frame)
            }
            if !isDup {
                unique.append(frame)
            }
        }
        return unique.isEmpty ? frames : unique
    }

    private static func framesLookSimilar(_ a: CGImage, _ b: CGImage) -> Bool {
        let w = 16
        let h = 16
        guard let ca = downsampleAlpha(a, width: w, height: h),
              let cb = downsampleAlpha(b, width: w, height: h) else {
            return false
        }
        var same = 0
        for i in 0..<(w * h) {
            let da = ca[i] > 20
            let db = cb[i] > 20
            if da == db { same += 1 }
        }
        return Double(same) / Double(w * h) > 0.92
    }

    private static func downsampleAlpha(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alpha[i] = buffer[i * 4 + 3]
        }
        return alpha
    }

    private func spawn(at point: CGPoint) {
        // Soft global cap for CPU (config maxcount can be 666).
        let cap = min(max(model.maxCount, 1), 48)
        guard particles.count < cap else { return }
        let scale = max(sceneToViewScale, 0.001)

        // emitter sphererandom + directions + distance (scene units)
        let dist = sample1D(
            min: model.emitter.distanceMin,
            max: model.emitter.distanceMax,
            exponent: 1
        )
        let dir = model.emitter.directions
        let sx = dir[safe: 0] ?? 1
        let sy = max(dir[safe: 1] ?? 1, 0.05)
        let sz = dir[safe: 2] ?? 1
        let u = Double.random(in: -1...1)
        let theta = Double.random(in: 0..<(2 * .pi))
        let radial = sqrt(max(0, 1 - u * u))
        var ox = radial * cos(theta) * sx
        var oy = u * sy
        let oz = radial * sin(theta) * sz
        let len = max(sqrt(ox * ox + oy * oy + oz * oz), 1e-6)
        ox = ox / len * dist
        oy = oy / len * dist
        _ = oz

        let life = sample1D(
            min: model.lifetime.min,
            max: model.lifetime.max,
            exponent: model.lifetime.exponent
        )
        let sizeScene = sample1D(
            min: model.size.min,
            max: model.size.max,
            exponent: model.size.exponent
        ) * model.instanceSize
        // Size is in orthographic scene units. Pure `size * sceneScale` on a
        // 5120×2880 canvas turns 36–72 into a few points (pink flecks). WE
        // particle sizes are typically authored around ~1080p preview weight;
        // when the ortho canvas is taller than 1080, scale size up so visual
        // weight stays consistent: sizeView = size × sceneScale × (canvasH/1080).
        let canvasHeightFactor = max(canvasSize.height / 1080.0, 1.0)
        let sizeView = CGFloat(sizeScene) * scale * CGFloat(canvasHeightFactor)

        let vx = CGFloat(sampleAxis(model.velocity, 0)) * scale
        let vy = CGFloat(sampleAxis(model.velocity, 1)) * scale

        let roll0: CGFloat
        if let rotation = model.rotation {
            let deg = sample1D(min: rotation.min, max: rotation.max, exponent: rotation.exponent)
            roll0 = CGFloat(deg * .pi / 180)
        } else {
            // No rotationrandom in config → start at 0 (billboard).
            roll0 = 0
        }

        var rollSpeed: CGFloat = 0
        if let angularVelocity = model.angularVelocity {
            rollSpeed = CGFloat(sampleAxis(angularVelocity, 2) * .pi / 180)
        }

        let spriteIndex = nextSpriteIndex()

        particles.append(
            Particle(
                x: point.x + CGFloat(ox) * scale,
                y: point.y + CGFloat(oy) * scale,
                vx: vx,
                vy: vy,
                baseSize: max(sizeView, 1),
                life: CGFloat(life),
                maxLife: max(CGFloat(life), 0.001),
                roll: roll0,
                rollSpeed: rollSpeed,
                spriteIndex: spriteIndex
            )
        )
    }

    private func currentSize(for p: Particle) -> CGFloat {
        guard let sizeChange = model.sizeChange, p.maxLife > 0 else {
            return p.baseSize
        }
        let t = 1 - (p.life / p.maxLife)
        let s = sizeChange.startScale
            + (sizeChange.endScale - sizeChange.startScale) * Double(t)
        return p.baseSize * CGFloat(s)
    }

    private func alpha(for p: Particle) -> CGFloat {
        guard let fade = model.alphaFade else { return 1 }
        let fadeIn = CGFloat(max(fade.fadeIn, 0.0001))
        let fadeOut = CGFloat(max(fade.fadeOut, 0.0001))
        let age = p.maxLife - p.life
        return min(min(max(age / fadeIn, 0), 1), min(max(p.life / fadeOut, 0), 1))
    }

    private func fixedOriginInView() -> CGPoint {
        let ox = model.origin.first ?? canvasSize.width * 0.5
        let oy = model.origin.dropFirst().first ?? canvasSize.height * 0.5
        return CGPoint(
            x: viewBounds.midX + (ox - canvasSize.width * 0.5) * sceneToViewScale,
            y: viewBounds.midY - (oy - canvasSize.height * 0.5) * sceneToViewScale
        )
    }

    // MARK: - CALayer sync (desktop-safe presentation)

    private func clearLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        particleLayers.forEach { $0.removeFromSuperlayer() }
        particleLayers.removeAll(keepingCapacity: true)
        CATransaction.commit()
    }

    private func syncLayers() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let aspect = max(spritePixelSize.width, 1) / max(spritePixelSize.height, 1)

        while particleLayers.count < particles.count {
            let layer = CALayer()
            layer.isOpaque = false
            layer.backgroundColor = NSColor.clear.cgColor
            layer.masksToBounds = true
            layer.contentsGravity = .resize
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            layer.allowsEdgeAntialiasing = true
            layer.contentsScale = scale
            layer.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "opacity": NSNull()
            ]
            hostLayer.addSublayer(layer)
            particleLayers.append(layer)
        }
        if particleLayers.count > particles.count {
            for layer in particleLayers.suffix(from: particles.count) {
                layer.removeFromSuperlayer()
            }
            particleLayers.removeLast(particleLayers.count - particles.count)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, p) in particles.enumerated() {
            let layer = particleLayers[index]
            let size = currentSize(for: p)
            let width: CGFloat
            let height: CGFloat
            if aspect >= 1 {
                width = size
                height = size / aspect
            } else {
                height = size
                width = size * aspect
            }
            let frame = sprites.isEmpty ? nil : sprites[p.spriteIndex % sprites.count]
            layer.contents = frame
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            layer.position = CGPoint(x: p.x, y: p.y)
            layer.opacity = Float(alpha(for: p))
            layer.transform = CATransform3DMakeRotation(p.roll, 0, 0, 1)
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    // MARK: - Sampling helpers

    private func sample1D(min: Double, max: Double, exponent: Double) -> Double {
        let lo = Swift.min(min, max)
        let hi = Swift.max(min, max)
        let t = pow(Double.random(in: 0...1), Swift.max(exponent, 0.01))
        return lo + (hi - lo) * t
    }

    private func sampleAxis(_ range: SceneParticleSystem.Range3D, _ axis: Int) -> Double {
        sample1D(
            min: range.min[safe: axis] ?? 0,
            max: range.max[safe: axis] ?? 0,
            exponent: 1
        )
    }

    // MARK: - Texture loading (all wallpapers)

    private static func loadSprites(
        model: SceneParticleSystem,
        package: ScenePackage?,
        rootURL: URL?
    ) -> [CGImage]? {
        let hints = textureHints(model: model, package: package)
        if let package {
            for name in hints {
                if let images = decodeFromPackage(package, hint: name), !images.isEmpty {
                    return images
                }
            }
        }
        if let rootURL {
            for name in hints {
                if let images = decodeFromFiles(root: rootURL, hint: name), !images.isEmpty {
                    return images
                }
            }
        }
        for name in hints {
            if let url = EngineAssetStore.shared.resolveTextureFile(hint: name),
               let images = decodeTextureURL(url),
               !images.isEmpty {
                NSLog(
                    "Wallflow loaded engine particle texture: %@ (%d frames, first %dx%d)",
                    url.path,
                    images.count,
                    images[0].width,
                    images[0].height
                )
                return images
            }
        }
        return nil
    }

    private static func textureHints(
        model: SceneParticleSystem,
        package: ScenePackage?
    ) -> [String] {
        var names: [String] = []
        if let hint = model.textureHint { names.append(hint) }
        if let package, let materialPath = model.materialPath,
           let data = try? package.data(forPath: materialPath),
           let material = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let top = material["textures"] as? [Any] {
                names.append(contentsOf: top.compactMap { $0 as? String })
            }
            if let passes = material["passes"] as? [[String: Any]] {
                for pass in passes {
                    if let textures = pass["textures"] as? [Any] {
                        names.append(contentsOf: textures.compactMap { $0 as? String })
                    }
                }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted && !$0.isEmpty && !$0.hasPrefix("_rt_") }
    }

    private static func decodeFromPackage(_ package: ScenePackage, hint: String) -> [CGImage]? {
        var path = hint.replacingOccurrences(of: "\\", with: "/")
        if !path.hasPrefix("materials/") { path = "materials/" + path }
        if URL(fileURLWithPath: path).pathExtension.isEmpty { path += ".tex" }
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let data = try? package.data(forPath: normalized),
              let texture = try? WallpaperTextureDecoder.decode(data) else {
            return nil
        }
        return spriteImages(from: texture)
    }

    private static func decodeFromFiles(root: URL, hint: String) -> [CGImage]? {
        let cleaned = hint.replacingOccurrences(of: "\\", with: "/")
        let stripped = cleaned.replacingOccurrences(of: "particle/", with: "")
        let candidates = [
            root.appendingPathComponent(cleaned),
            root.appendingPathComponent(cleaned + ".tex"),
            root.appendingPathComponent("materials/\(cleaned)"),
            root.appendingPathComponent("materials/\(cleaned).tex"),
            root.appendingPathComponent("materials/particle/\(stripped)"),
            root.appendingPathComponent("materials/particle/\(stripped).tex")
        ]
        for url in candidates {
            if let images = decodeTextureURL(url) { return images }
        }
        return nil
    }

    private static func decodeTextureURL(_ url: URL) -> [CGImage]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "tex" || ext.isEmpty {
            do {
                let data = try Data(contentsOf: url)
                let texture = try WallpaperTextureDecoder.decode(data)
                var frames = spriteImages(from: texture)
                if frames.count <= 1,
                   let split = splitUsingTexJSON(atlas: texture.image, texURL: url),
                   split.count > 1 {
                    frames = split.map { sanitizeFrame($0) ?? $0 }
                }
                return frames.isEmpty ? nil : frames
            } catch {
                NSLog(
                    "Wallflow particle texture decode failed %@: %@",
                    url.lastPathComponent,
                    error.localizedDescription
                )
            }
        }
        if let image = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return [sanitizeFrame(cg) ?? cg]
            }
        }
        return nil
    }

    private static func spriteImages(from texture: WallpaperTexture) -> [CGImage] {
        let raw: [CGImage]
        if texture.isSprite, !texture.animationFrames.isEmpty {
            raw = texture.animationFrames.map(\.image)
            NSLog(
                "Wallflow particle texture: atlas %dx%d → %d frames (TEXS)",
                texture.textureWidth,
                texture.textureHeight,
                raw.count
            )
        } else if !texture.images.isEmpty {
            raw = texture.images
        } else {
            raw = [texture.image]
        }
        // Never drop frames to empty — if sanitize fails, keep the original crop.
        let cleaned = raw.map { sanitizeFrame($0) ?? $0 }
        for (index, image) in cleaned.enumerated() {
            NSLog(
                "Wallflow particle frame %d: %dx%d",
                index,
                image.width,
                image.height
            )
        }
        let usable = cleaned.filter { hasCoverage($0) }
        return usable.isEmpty ? cleaned : usable
    }

    private static func splitUsingTexJSON(atlas: CGImage, texURL: URL) -> [CGImage]? {
        let alt = URL(fileURLWithPath: texURL.path + "-json")
        guard FileManager.default.fileExists(atPath: alt.path),
              let data = try? Data(contentsOf: alt),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sequences = root["spritesheetsequences"] as? [[String: Any]],
              let seq = sequences.first else {
            return nil
        }
        let frames = max((seq["frames"] as? NSNumber)?.intValue ?? 0, 0)
        let frameW = (seq["width"] as? NSNumber)?.doubleValue ?? 0
        let frameH = (seq["height"] as? NSNumber)?.doubleValue ?? 0
        guard frames > 1, frameW >= 1, frameH >= 1 else { return nil }
        var result: [CGImage] = []
        let atlasW = Double(atlas.width)
        let atlasH = Double(atlas.height)
        let cols = max(Int((atlasW / frameW).rounded(.down)), 1)
        for index in 0..<frames {
            let col = index % cols
            let row = index / cols
            let x = Double(col) * frameW
            let yFromTop = Double(row) * frameH
            let crop = CGRect(
                x: x,
                y: atlasH - yFromTop - frameH,
                width: min(frameW, atlasW - x),
                height: min(frameH, atlasH - yFromTop)
            ).integral
            if crop.width >= 1, crop.height >= 1, let piece = atlas.cropping(to: crop) {
                result.append(piece)
            }
        }
        return result.count > 1 ? result : nil
    }

    /// Keep petal RGB detail. Only zero RGB under fully transparent texels and
    /// premultiply for CALayer. Never invent solid-pink ellipses.
    private static func sanitizeFrame(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bpr = width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = Data(count: bpr * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            // Draw source; context premultiplies. Then force RGB=0 where a=0.
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * height) {
                let o = i * 4
                let a = ptr[o + 3]
                if a == 0 {
                    ptr[o] = 0
                    ptr[o + 1] = 0
                    ptr[o + 2] = 0
                } else {
                    // Clamp channels to alpha (valid premultiplied).
                    ptr[o] = min(ptr[o], a)
                    ptr[o + 1] = min(ptr[o + 1], a)
                    ptr[o + 2] = min(ptr[o + 2], a)
                }
            }
            return true
        }
        guard ok else { return image }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let out = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bpr,
                space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return image
        }
        return out
    }

    private static func hasCoverage(_ image: CGImage) -> Bool {
        let w = min(image.width, 48)
        let h = min(image.height, 48)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return true
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return true }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var visible = 0
        for i in 0..<(w * h) where ptr[i * 4 + 3] > 20 {
            visible += 1
        }
        return Double(visible) / Double(w * h) > 0.02
    }

    private static func makePlaceholderFrames() -> [CGImage] {
        (0..<4).compactMap { seed -> CGImage? in
            let size = 96
            guard let ctx = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
            ctx.rotate(by: CGFloat(seed) * 0.3)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.7, blue: 0.85, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: -14, y: -18, width: 28, height: 40))
            return ctx.makeImage()
        }
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
