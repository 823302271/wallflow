import AppKit
import QuartzCore

final class SceneWallpaperView: NSView, WallpaperRenderer {
    private struct RenderedLayer {
        let model: SceneImageLayer
        let layer: CALayer
        let automaticContentsGravity: CALayerContentsGravity
        var basePosition: CGPoint
    }

    private var desktopFrame: CGRect
    private let project: WallpaperProject
    private var playsAudio: Bool
    private let previewLayer = CALayer()
    private var renderedLayers: [RenderedLayer] = []
    private var particleRuntimes: [SceneParticleRuntime] = []
    private var mouseTimer: Timer?
    private var particleTimer: Timer?
    private var lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    private var lastParticleTick = CACurrentMediaTime()
    private var sceneDocument: SceneDocument?
    private var isRenderingEnabled = true
    private var isAudioMuted = false
    private var scenePackage: ScenePackage?
    private var sceneSounds: [SceneSoundObject] = []
    private var audioController: SceneAudioController?
    private var fitMode: WallpaperFitMode
    private var userProperties: JSONValue
    /// Locked layer time for the current pause session (Space flap safe).
    private var sessionPausedLayerTime: CFTimeInterval?

    var contentView: NSView { self }

    init(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        playsAudio: Bool,
        fitMode: WallpaperFitMode = .automatic
    ) {
        self.desktopFrame = desktopFrame
        self.project = project
        self.playsAudio = playsAudio
        self.fitMode = fitMode
        self.userProperties = project.userProperties
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsGravity = contentsGravity(for: .resizeAspectFill)
        previewLayer.masksToBounds = true
        previewLayer.isHidden = true
        layer?.addSublayer(previewLayer)

        loadScene()
        startMouseTracking()
        startParticleSimulation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        mouseTimer?.invalidate()
        particleTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        if fitMode == .automatic || fitMode == .fill {
            let overflow = max(bounds.width, bounds.height) * 0.035
            previewLayer.frame = bounds.insetBy(dx: -overflow, dy: -overflow)
        } else {
            previewLayer.frame = bounds
        }
        layoutSceneLayers()
    }

    func setRenderingEnabled(_ enabled: Bool, completion: (() -> Void)?) {
        if enabled == isRenderingEnabled {
            if !enabled {
                pinToPauseSession(completion: completion)
            } else {
                completion?()
            }
            return
        }
        isRenderingEnabled = enabled
        if enabled {
            // Freeze-frame path only freezes scene layers / audio — particles keep
            // their own active flag (setParticlesActive).
            completion?()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRenderingEnabled else { return }
                self.resumeLayerAnimations()
                self.startMouseTracking()
                self.startParticleSimulation()
                self.audioController?.setRenderingEnabled(true)
            }
        } else {
            pinToPauseSession(completion: completion)
        }
    }

    func pinToPauseSession(completion: (() -> Void)?) {
        // Scene freeze for video-like checkpoint: pause image layers + audio only.
        // Particles are independent and keep simulating unless setParticlesActive(false).
        isRenderingEnabled = false
        pauseLayerAnimations()
        audioController?.setRenderingEnabled(false)
        completion?()
    }

    func commitPauseSession() {
        guard isRenderingEnabled else { return }
        sessionPausedLayerTime = nil
    }

    func setParticlesActive(_ active: Bool) {
        if active {
            particleRuntimes.forEach { $0.setEnabled(true) }
            startMouseTracking()
            startParticleSimulation()
        } else {
            // Desktop not visible: stop particle CPU work, clear particles so
            // resume starts clean (not a frozen mid-air trail under freeze still).
            particleTimer?.invalidate()
            particleTimer = nil
            // Keep mouse timer if parallax needs it; stop only when no particles need it.
            if sceneDocument?.general.cameraParallax != true {
                mouseTimer?.invalidate()
                mouseTimer = nil
            }
            particleRuntimes.forEach {
                $0.setEnabled(false)
                $0.clearParticles()
            }
        }
    }

    func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        audioController?.setMuted(muted)
    }

    func setPlaysAudio(_ enabled: Bool) {
        guard enabled != playsAudio else { return }
        playsAudio = enabled
        if enabled {
            configureAudioIfNeeded()
        } else {
            audioController?.setRenderingEnabled(false)
            audioController = nil
        }
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        guard fitMode != self.fitMode else { return }
        self.fitMode = fitMode
        previewLayer.contentsGravity = contentsGravity(for: .resizeAspectFill)
        for rendered in renderedLayers {
            rendered.layer.contentsGravity = contentsGravity(
                for: rendered.automaticContentsGravity
            )
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func applyUserProperties(_ properties: JSONValue) {
        guard let changed = properties.objectValue else { return }
        var all = userProperties.objectValue ?? [:]
        for (key, value) in changed {
            all[key] = value
        }
        userProperties = .object(all)
        applyParticleVisibilityFromUserProperties()
    }

    func updateDesktopFrame(_ frame: CGRect) {
        desktopFrame = frame
        lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    }

    private func loadScene() {
        guard let packageURL = project.entryURL else { return }
        do {
            let package = try ScenePackage(url: packageURL)
            let document = try SceneDocument(package: package)
            scenePackage = package
            sceneSounds = document.sounds
            sceneDocument = document
            applyClearColor(document.general.clearColor)
            loadSceneLayers(package: package, document: document)
            loadParticleSystems(package: package, document: document)
            configureAudioIfNeeded()
            if renderedLayers.isEmpty {
                loadPreviewImage(package: package)
            }
            NSLog(
                "Wallflow loaded %@: %d/%d image layers, %d/%d particles, %d sounds, %d lights",
                package.version,
                renderedLayers.count,
                document.compatibility.imageObjects,
                particleRuntimes.count,
                document.compatibility.particleObjects,
                document.compatibility.soundObjects,
                document.compatibility.lightObjects
            )
        } catch {
            NSLog("Wallflow scene load failed: %@", error.localizedDescription)
        }
    }

    private func configureAudioIfNeeded() {
        guard playsAudio,
              audioController == nil,
              let scenePackage,
              !sceneSounds.isEmpty else {
            return
        }
        let controller = SceneAudioController(
            package: scenePackage,
            sounds: sceneSounds
        )
        controller.setMuted(isAudioMuted)
        controller.setRenderingEnabled(isRenderingEnabled)
        audioController = controller
    }

    private func loadSceneLayers(package: ScenePackage, document: SceneDocument) {
        for model in document.imageLayers {
            guard let texturePath = model.texturePath else { continue }
            do {
                let data = try package.data(forPath: texturePath)
                let texture = try WallpaperTextureDecoder.decode(data)
                let imageLayer = CALayer()
                imageLayer.name = model.name
                imageLayer.contents = texture.image
                let automaticContentsGravity: CALayerContentsGravity = texture.isSprite
                    ? .resizeAspect
                    : .resizeAspectFill
                imageLayer.contentsGravity = contentsGravity(for: automaticContentsGravity)
                imageLayer.masksToBounds = true
                imageLayer.opacity = Float(min(max(model.alpha, 0), 1))
                imageLayer.minificationFilter = .linear
                imageLayer.magnificationFilter = .linear
                addSpriteAnimation(texture.animationFrames, to: imageLayer)
                layer?.addSublayer(imageLayer)
                renderedLayers.append(
                    RenderedLayer(
                        model: model,
                        layer: imageLayer,
                        automaticContentsGravity: automaticContentsGravity,
                        basePosition: .zero
                    )
                )
            } catch {
                NSLog(
                    "Wallflow skipped scene texture %@: %@",
                    texturePath,
                    error.localizedDescription
                )
            }
        }
        needsLayout = true
    }

    private func loadParticleSystems(package: ScenePackage, document: SceneDocument) {
        particleRuntimes.forEach { $0.layer.removeFromSuperlayer() }
        particleRuntimes.removeAll()
        for model in document.particleSystems {
            let runtime = SceneParticleRuntime(
                model: model,
                package: package,
                rootURL: project.rootURL
            )
            // Metal renders offscreen; present via CALayer on the scene layer tree.
            layer?.addSublayer(runtime.layer)
            particleRuntimes.append(runtime)
        }
        applyParticleVisibilityFromUserProperties()
        needsLayout = true
    }

    private func applyParticleVisibilityFromUserProperties() {
        let properties = userProperties.objectValue ?? [:]
        guard let document = sceneDocument else { return }
        for (index, model) in document.particleSystems.enumerated() {
            guard index < particleRuntimes.count else { break }
            let visible: Bool
            if let key = model.visibility.userPropertyKey,
               let definition = properties[key]?.objectValue,
               let value = definition["value"] {
                switch value {
                case .bool(let flag):
                    visible = flag
                case .number(let number):
                    visible = number != 0
                default:
                    visible = model.visibility.defaultValue
                }
            } else {
                visible = model.visibility.defaultValue
            }
            particleRuntimes[index].setVisible(visible)
        }
    }

    private func loadPreviewImage(package: ScenePackage) {
        if let rootURL = project.rootURL {
            let previewName = project.manifest?.preview ?? "preview.jpg"
            let previewURL = rootURL.appendingPathComponent(previewName)
            if let image = NSImage(contentsOf: previewURL) {
                setImage(image)
                return
            }
        }

        let imageEntry = package.entries.first {
            ["png", "jpg", "jpeg", "webp"].contains(
                URL(fileURLWithPath: $0.path).pathExtension.lowercased()
            )
        }
        if let imageEntry,
           let data = try? package.data(forPath: imageEntry.path),
           let image = NSImage(data: data) {
            setImage(image)
        }
    }

    private func setImage(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        previewLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        previewLayer.isHidden = false
    }

    private func applyClearColor(_ values: [Double]) {
        guard values.count >= 3 else { return }
        layer?.backgroundColor = NSColor(
            calibratedRed: values[0],
            green: values[1],
            blue: values[2],
            alpha: 1
        ).cgColor
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let needsMouse = sceneDocument?.general.cameraParallax == true
            || !(sceneDocument?.particleSystems.isEmpty ?? true)
        guard needsMouse else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateMouseDrivenEffects()
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func startParticleSimulation() {
        guard particleTimer == nil, !particleRuntimes.isEmpty else { return }
        lastParticleTick = CACurrentMediaTime()
        // 12 FPS is enough for soft petals; lower than scene freeze path.
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.tickParticles()
        }
        timer.tolerance = 1.0 / 24.0
        RunLoop.main.add(timer, forMode: .common)
        particleTimer = timer
    }

    private func tickParticles() {
        // Independent of scene freeze (isRenderingEnabled): only runtimes that
        // are enabled tick. Desktop-hidden path calls setParticlesActive(false).
        let now = CACurrentMediaTime()
        let delta = min(max(now - lastParticleTick, 1.0 / 30.0), 0.15)
        lastParticleTick = now
        for runtime in particleRuntimes {
            runtime.tick(delta: delta)
        }
    }

    /// Test/debug: drive particle systems with a synthetic cursor sample.
    func debugDriveParticles(point: CGPoint, inDesktop: Bool, delta: TimeInterval) {
        isRenderingEnabled = true
        for runtime in particleRuntimes {
            runtime.setEnabled(true)
            runtime.setVisible(true)
            runtime.debugBypassStartTime()
            runtime.updateMouse(desktopPoint: point, inDesktop: inDesktop)
            runtime.tick(delta: delta)
        }
    }

    func debugParticleCount() -> Int {
        particleRuntimes.reduce(0) { $0 + $1.debugParticleCount() }
    }

    func debugExportSpriteFrames(toDirectory directory: String) {
        particleRuntimes.first?.debugExportFrames(toDirectory: directory)
    }

    /// Snapshot only particle host layers (transparent background).
    func debugSnapshotParticlesOnly() -> NSImage? {
        layoutSubtreeIfNeeded()
        // Force particle hosts on top.
        for runtime in particleRuntimes {
            runtime.layer.zPosition = 10_000
        }
        guard let host = particleRuntimes.first?.layer else { return nil }
        let bounds = host.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            // Fall back to view bounds if host not laid out.
            let b = self.bounds
            guard let rep = bitmapImageRepForCachingDisplay(in: b) else { return nil }
            // Hide image layers temporarily
            let hidden = renderedLayers.map(\.layer.isHidden)
            renderedLayers.forEach { $0.layer.isHidden = true }
            previewLayer.isHidden = true
            cacheDisplay(in: b, to: rep)
            for (i, layer) in renderedLayers.map(\.layer).enumerated() {
                layer.isHidden = hidden[i]
            }
            previewLayer.isHidden = renderedLayers.isEmpty ? false : true
            let image = NSImage(size: b.size)
            image.addRepresentation(rep)
            return image
        }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixels.width),
            height: Int(pixels.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        host.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: bounds.size)
    }

    private func updateMouseDrivenEffects() {
        let global = NSEvent.mouseLocation
        let inDesktop = desktopFrame.contains(global)
        // Map desktop global point into this view's coordinates.
        let viewPoint: CGPoint?
        if inDesktop, let window {
            let windowPoint = window.convertPoint(fromScreen: global)
            viewPoint = convert(windowPoint, from: nil)
        } else if inDesktop {
            // Borderless desktop window: global ≈ window base coords for primary layouts.
            viewPoint = CGPoint(
                x: global.x - desktopFrame.minX,
                y: global.y - desktopFrame.minY
            )
        } else {
            viewPoint = nil
        }

        for runtime in particleRuntimes {
            runtime.updateMouse(desktopPoint: viewPoint, inDesktop: inDesktop)
        }

        guard let document = sceneDocument,
              document.general.cameraParallax,
              inDesktop,
              hypot(global.x - lastMouseLocation.x, global.y - lastMouseLocation.y) >= 0.25 else {
            return
        }
        lastMouseLocation = global

        let normalizedX = (global.x - desktopFrame.midX) / (desktopFrame.width * 0.5)
        let normalizedY = (global.y - desktopFrame.midY) / (desktopFrame.height * 0.5)
        let authoredAmount = abs(document.general.cameraParallaxAmount)
        let influence = max(0, document.general.cameraParallaxMouseInfluence)
        let distance = min(max(bounds.width, bounds.height) * 0.06, 72)
            * min(max(authoredAmount, 0.1), 2)
            * influence

        CATransaction.begin()
        CATransaction.setAnimationDuration(
            min(max(document.general.cameraParallaxDelay, 0.04), 0.8)
        )
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeOut)
        )
        if renderedLayers.isEmpty {
            previewLayer.setAffineTransform(
                CGAffineTransform(
                    translationX: -normalizedX * distance,
                    y: -normalizedY * distance
                )
            )
        } else {
            for rendered in renderedLayers {
                let depthMultiplier = min(max(1 + rendered.model.parallaxDepth * 0.02, 0.1), 4)
                rendered.layer.position = CGPoint(
                    x: rendered.basePosition.x - normalizedX * distance * depthMultiplier,
                    y: rendered.basePosition.y - normalizedY * distance * depthMultiplier
                )
            }
        }
        CATransaction.commit()
    }

    private func layoutSceneLayers() {
        guard let document = sceneDocument else { return }
        let canvasWidth = max(document.general.canvasWidth, 1)
        let canvasHeight = max(document.general.canvasHeight, 1)
        let widthScale = bounds.width / canvasWidth
        let heightScale = bounds.height / canvasHeight
        let sceneScaleX: CGFloat
        let sceneScaleY: CGFloat
        switch fitMode {
        case .automatic, .fill:
            let scale = max(widthScale, heightScale)
            sceneScaleX = scale
            sceneScaleY = scale
        case .fit:
            let scale = min(widthScale, heightScale)
            sceneScaleX = scale
            sceneScaleY = scale
        case .stretch:
            sceneScaleX = widthScale
            sceneScaleY = heightScale
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in renderedLayers.indices {
            let model = renderedLayers[index].model
            let imageLayer = renderedLayers[index].layer
            if model.fullscreen {
                imageLayer.bounds = CGRect(origin: .zero, size: bounds.size)
                imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                let scaleX = abs(model.scale.first ?? 1)
                let scaleY = abs(model.scale.dropFirst().first ?? 1)
                imageLayer.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: max(1, model.width * scaleX * sceneScaleX),
                    height: max(1, model.height * scaleY * sceneScaleY)
                )
                let originX = model.origin.first ?? canvasWidth * 0.5
                let originY = model.origin.dropFirst().first ?? canvasHeight * 0.5
                imageLayer.position = CGPoint(
                    x: bounds.midX + (originX - canvasWidth * 0.5) * sceneScaleX,
                    y: bounds.midY - (originY - canvasHeight * 0.5) * sceneScaleY
                )
            }

            let angle = model.angles.count > 2 ? model.angles[2] : 0
            imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -angle))
            renderedLayers[index].basePosition = imageLayer.position
        }
        let uniformScale = (sceneScaleX + sceneScaleY) * 0.5
        for runtime in particleRuntimes {
            if runtime.layer.superlayer !== layer {
                layer?.addSublayer(runtime.layer)
            }
            runtime.updateLayout(
                viewBounds: bounds,
                canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
                sceneScale: uniformScale
            )
        }
        CATransaction.commit()
    }

    private func contentsGravity(
        for automaticGravity: CALayerContentsGravity
    ) -> CALayerContentsGravity {
        switch fitMode {
        case .automatic: automaticGravity
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }

    private func addSpriteAnimation(
        _ frames: [WallpaperAnimationFrame],
        to imageLayer: CALayer
    ) {
        guard frames.count > 1 else { return }
        let totalDuration = frames.reduce(0) { $0 + $1.duration }
        guard totalDuration > 0 else { return }

        var elapsed: TimeInterval = 0
        var keyTimes: [NSNumber] = []
        keyTimes.reserveCapacity(frames.count)
        for frame in frames {
            keyTimes.append(NSNumber(value: elapsed / totalDuration))
            elapsed += frame.duration
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.map { $0.image as Any }
        animation.keyTimes = keyTimes
        animation.duration = totalDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        imageLayer.contents = frames[0].image
        imageLayer.add(animation, forKey: "wallflow.sprite")
    }

    private func pauseLayerAnimations() {
        guard let layer else { return }
        if layer.speed != 0 {
            let pausedTime = sessionPausedLayerTime
                ?? layer.convertTime(CACurrentMediaTime(), from: nil)
            if sessionPausedLayerTime == nil {
                sessionPausedLayerTime = pausedTime
            }
            layer.speed = 0
            layer.timeOffset = sessionPausedLayerTime ?? pausedTime
            return
        }
        // Already paused: snap back to the session lock if a false resume advanced time.
        if let locked = sessionPausedLayerTime {
            layer.timeOffset = locked
        } else {
            sessionPausedLayerTime = layer.timeOffset
        }
    }

    private func resumeLayerAnimations() {
        guard let layer, layer.speed == 0 else { return }
        let pausedTime = sessionPausedLayerTime ?? layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }
}
