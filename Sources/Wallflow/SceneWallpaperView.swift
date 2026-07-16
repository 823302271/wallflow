import AppKit
import QuartzCore

final class SceneWallpaperView: NSView, WallpaperRenderer {
    private struct RenderedLayer {
        let model: SceneImageLayer
        let layer: CALayer
        var basePosition: CGPoint
    }

    private let desktopFrame: CGRect
    private let project: WallpaperProject
    private let playsAudio: Bool
    private let previewLayer = CALayer()
    private var renderedLayers: [RenderedLayer] = []
    private var mouseTimer: Timer?
    private var lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    private var sceneDocument: SceneDocument?
    private var isRenderingEnabled = true
    private var audioController: SceneAudioController?

    var contentView: NSView { self }

    init(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        playsAudio: Bool
    ) {
        self.desktopFrame = desktopFrame
        self.project = project
        self.playsAudio = playsAudio
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsGravity = .resizeAspectFill
        previewLayer.masksToBounds = true
        previewLayer.isHidden = true
        layer?.addSublayer(previewLayer)

        loadScene()
        startMouseTracking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        mouseTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        let overflow = max(bounds.width, bounds.height) * 0.035
        previewLayer.frame = bounds.insetBy(dx: -overflow, dy: -overflow)
        layoutSceneLayers()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != isRenderingEnabled else { return }
        isRenderingEnabled = enabled
        if enabled {
            resumeLayerAnimations()
            startMouseTracking()
            audioController?.setRenderingEnabled(true)
        } else {
            mouseTimer?.invalidate()
            mouseTimer = nil
            pauseLayerAnimations()
            audioController?.setRenderingEnabled(false)
        }
    }

    func setAudioMuted(_ muted: Bool) {
        audioController?.setMuted(muted)
    }

    private func loadScene() {
        guard let packageURL = project.entryURL else { return }
        do {
            let package = try ScenePackage(url: packageURL)
            let document = try SceneDocument(package: package)
            sceneDocument = document
            applyClearColor(document.general.clearColor)
            loadSceneLayers(package: package, document: document)
            if playsAudio, !document.sounds.isEmpty {
                audioController = SceneAudioController(
                    package: package,
                    sounds: document.sounds
                )
            }
            if renderedLayers.isEmpty {
                loadPreviewImage(package: package)
            }
            NSLog(
                "Wallflow loaded %@: %d/%d image layers, %d particles, %d sounds, %d lights",
                package.version,
                renderedLayers.count,
                document.compatibility.imageObjects,
                document.compatibility.particleObjects,
                document.compatibility.soundObjects,
                document.compatibility.lightObjects
            )
        } catch {
            NSLog("Wallflow scene load failed: %@", error.localizedDescription)
        }
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
                imageLayer.contentsGravity = texture.isSprite ? .resizeAspect : .resizeAspectFill
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
        guard mouseTimer == nil, sceneDocument?.general.cameraParallax == true else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateParallax()
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func updateParallax() {
        guard let document = sceneDocument,
              document.general.cameraParallax else {
            return
        }

        let global = NSEvent.mouseLocation
        guard desktopFrame.contains(global),
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
        let sceneScale = max(
            bounds.width / canvasWidth,
            bounds.height / canvasHeight
        )

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
                    width: max(1, model.width * scaleX * sceneScale),
                    height: max(1, model.height * scaleY * sceneScale)
                )
                let originX = model.origin.first ?? canvasWidth * 0.5
                let originY = model.origin.dropFirst().first ?? canvasHeight * 0.5
                imageLayer.position = CGPoint(
                    x: bounds.midX + (originX - canvasWidth * 0.5) * sceneScale,
                    y: bounds.midY - (originY - canvasHeight * 0.5) * sceneScale
                )
            }

            let angle = model.angles.count > 2 ? model.angles[2] : 0
            imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -angle))
            renderedLayers[index].basePosition = imageLayer.position
        }
        CATransaction.commit()
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
        guard let layer, layer.speed != 0 else { return }
        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = pausedTime
    }

    private func resumeLayerAnimations() {
        guard let layer, layer.speed == 0 else { return }
        let pausedTime = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
    }
}
