import AppKit
import MetalKit
import QuartzCore
import simd

private struct CanvasUniforms {
    var canvasSize: SIMD2<Float>
}

private struct CanvasShapeInstance {
    var positionA: SIMD2<Float>
    var positionB: SIMD2<Float>
    var positionC: SIMD2<Float>
    var padding0 = SIMD2<Float>(repeating: 0)
    var color: SIMD4<Float>
    var width: Float
    var kind: UInt32
    var softness: Float
    var padding1: Float = 0
}

private struct CanvasDrawBatch {
    var start: Int
    var count: Int
    var overlay: Bool
}

final class CanvasMetalWallpaperView: MTKView, MTKViewDelegate, WallpaperRenderer {
    private static let framesPerSecond = 24

    private let metalContext: MetalContext
    private let runtime: CanvasMetalRuntime
    private let hasVignette: Bool
    private var desktopFrame: CGRect
    private var latestFrame: CanvasMetalFrame?
    private var frameTimer: Timer?
    private var globalMouseMonitor: Any?
    private var virtualTimeMilliseconds = 0.0
    private var lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    private var mouseWasInside = false
    private var isRenderingEnabled = true
    private var reportedRuntimeFailure = false
    private var shapeBuffers: [MTLBuffer] = []
    private var shapeBufferCapacity = 0
    private var shapeBufferIndex = 0
    private var renderSubmissionCount = 0

    var contentView: NSView { self }
    var commandCountForTesting: Int {
        (latestFrame?.commands.count ?? 0) / CanvasMetalFrame.commandWidth
    }
    var virtualTimeForTesting: Double { virtualTimeMilliseconds }
    var schedulerActiveForTesting: Bool { frameTimer != nil }
    var renderSubmissionCountForTesting: Int { renderSubmissionCount }

    static func makeIfSupported(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        context: MetalContext = .shared
    ) -> CanvasMetalWallpaperView? {
        guard let program = CanvasMetalProgramLoader.load(project: project) else {
            return nil
        }
        do {
            return try CanvasMetalWallpaperView(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project,
                program: program,
                context: context
            )
        } catch {
            fputs("Wallflow Canvas Metal fallback: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private init(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        program: CanvasMetalProgram,
        context: MetalContext
    ) throws {
        metalContext = context
        self.desktopFrame = desktopFrame
        hasVignette = program.hasVignette
        runtime = try CanvasMetalRuntime(program: program, size: frame.size)
        super.init(frame: frame, device: context.device)

        try runtime.applyUserProperties(project.userProperties)
        virtualTimeMilliseconds = 1_000.0 / Double(Self.framesPerSecond)
        latestFrame = try runtime.renderFrame(timeMilliseconds: virtualTimeMilliseconds)
        configureMetalView()
        startScheduler()
        startInputBridge()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopScheduler()
        stopInputBridge()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        do {
            try runtime.resize(to: bounds.size)
        } catch {
            reportRuntimeFailure(error)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != isRenderingEnabled else { return }
        isRenderingEnabled = enabled
        if enabled {
            startScheduler()
            startInputBridge()
        } else {
            stopScheduler()
            stopInputBridge()
        }
    }

    func updateDesktopFrame(_ frame: CGRect) {
        desktopFrame = frame
        lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
        mouseWasInside = false
    }

    func applyUserProperties(_ properties: JSONValue) {
        do {
            try runtime.applyUserProperties(properties)
            renderNextFrame()
        } catch {
            reportRuntimeFailure(error)
        }
    }

    func prepareForPresentation() {
        displayIfNeeded()
        draw()
    }

    func setAudioMuted(_ muted: Bool) {}
    func setPlaysAudio(_ enabled: Bool) {}

    func evaluateJavaScriptForTesting(_ script: String) throws -> Any? {
        try runtime.evaluateForTesting(script)
    }

    func dispatchMouseForTesting(type: String, x: CGFloat, y: CGFloat) {
        runtime.dispatchMouse(type: type, x: x, y: y)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = latestFrame else { return }
        render(frame)
    }

    private func configureMetalView() {
        delegate = self
        autoresizingMask = [.width, .height]
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = true
        isPaused = true
        presentsWithTransaction = false
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.allowsNextDrawableTimeout = true
        }
        updateDrawableSize()
        draw()
    }

    private func updateDrawableSize() {
        let backingBounds = convertToBacking(bounds)
        drawableSize = CGSize(
            width: max(1, backingBounds.width),
            height: max(1, backingBounds.height)
        )
    }

    private func startScheduler() {
        guard isRenderingEnabled, frameTimer == nil, !reportedRuntimeFailure else { return }
        let interval = 1.0 / Double(Self.framesPerSecond)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.renderNextFrame()
        }
        timer.tolerance = interval * 0.12
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopScheduler() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func renderNextFrame() {
        guard isRenderingEnabled, !reportedRuntimeFailure else { return }
        dispatchMouseMovement()
        virtualTimeMilliseconds += 1_000.0 / Double(Self.framesPerSecond)
        do {
            latestFrame = try runtime.renderFrame(
                timeMilliseconds: virtualTimeMilliseconds
            )
            draw()
        } catch {
            reportRuntimeFailure(error)
        }
    }

    private func startInputBridge() {
        guard isRenderingEnabled, globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleMouseButton(event)
            }
        }
    }

    private func stopInputBridge() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func dispatchMouseMovement() {
        let global = NSEvent.mouseLocation
        let isInside = desktopFrame.contains(global)
        if !isInside {
            if mouseWasInside {
                runtime.dispatchMouse(type: "mouseout", x: 0, y: 0)
                mouseWasInside = false
            }
            return
        }
        mouseWasInside = true
        guard hypot(
            global.x - lastMouseLocation.x,
            global.y - lastMouseLocation.y
        ) >= 0.25 else {
            return
        }
        lastMouseLocation = global
        let point = localPoint(for: global)
        runtime.dispatchMouse(type: "mousemove", x: point.x, y: point.y)
    }

    private func handleMouseButton(_ event: NSEvent) {
        let global = NSEvent.mouseLocation
        guard desktopFrame.contains(global) else { return }
        let point = localPoint(for: global)
        switch event.type {
        case .leftMouseDown:
            runtime.dispatchMouse(type: "mousedown", x: point.x, y: point.y)
        case .leftMouseUp:
            runtime.dispatchMouse(type: "mouseup", x: point.x, y: point.y)
            runtime.dispatchMouse(type: "click", x: point.x, y: point.y)
        default:
            break
        }
    }

    private func localPoint(for global: CGPoint) -> CGPoint {
        CGPoint(
            x: global.x - desktopFrame.minX,
            y: desktopFrame.maxY - global.y
        )
    }

    private func reportRuntimeFailure(_ error: Error) {
        guard !reportedRuntimeFailure else { return }
        reportedRuntimeFailure = true
        stopScheduler()
        stopInputBridge()
        fputs("Wallflow Canvas Metal stopped: \(error.localizedDescription)\n", stderr)
    }

    private func render(_ frame: CanvasMetalFrame) {
        guard bounds.width > 0,
              bounds.height > 0,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable else {
            return
        }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(frame.background.x),
            green: Double(frame.background.y),
            blue: Double(frame.background.z),
            alpha: Double(frame.background.w)
        )
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let (instances, batches) = makeInstances(frame.commands)
        if !instances.isEmpty {
            ensureShapeBufferCapacity(instances.count)
            let buffer = shapeBuffers[shapeBufferIndex]
            shapeBufferIndex = (shapeBufferIndex + 1) % shapeBuffers.count
            instances.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    memcpy(buffer.contents(), baseAddress, bytes.count)
                }
            }

            var uniforms = CanvasUniforms(
                canvasSize: SIMD2(Float(bounds.width), Float(bounds.height))
            )
            encoder.label = "Wallflow Canvas Metal Frame"
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<CanvasUniforms>.stride,
                index: 0
            )
            for batch in batches {
                encoder.setRenderPipelineState(
                    batch.overlay
                        ? metalContext.canvasOverlayPipeline
                        : metalContext.canvasSourcePipeline
                )
                encoder.setVertexBuffer(
                    buffer,
                    offset: batch.start * MemoryLayout<CanvasShapeInstance>.stride,
                    index: 1
                )
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: batch.count
                )
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderSubmissionCount += 1
    }

    private func makeInstances(
        _ commands: [Float]
    ) -> ([CanvasShapeInstance], [CanvasDrawBatch]) {
        var instances: [CanvasShapeInstance] = []
        var batches: [CanvasDrawBatch] = []
        instances.reserveCapacity(commands.count / CanvasMetalFrame.commandWidth * 2 + 1)

        func append(_ instance: CanvasShapeInstance, overlay: Bool) {
            if let last = batches.indices.last, batches[last].overlay == overlay {
                batches[last].count += 1
            } else {
                batches.append(
                    CanvasDrawBatch(start: instances.count, count: 1, overlay: overlay)
                )
            }
            instances.append(instance)
        }

        for offset in stride(
            from: 0,
            to: commands.count,
            by: CanvasMetalFrame.commandWidth
        ) {
            let kind = UInt32(max(commands[offset], 0))
            let positionA = SIMD2(commands[offset + 1], commands[offset + 2])
            let positionB = SIMD2(commands[offset + 3], commands[offset + 4])
            let positionC = SIMD2(commands[offset + 5], commands[offset + 6])
            let width = commands[offset + 7]
            let color = SIMD4(
                commands[offset + 8], commands[offset + 9],
                commands[offset + 10], commands[offset + 11]
            )
            let overlay = commands[offset + 12] > 0.5
            let shadowBlur = commands[offset + 13]
            let shadowOffset = SIMD2(commands[offset + 14], commands[offset + 15])
            let shadowColor = SIMD4(
                commands[offset + 16], commands[offset + 17],
                commands[offset + 18], commands[offset + 19]
            )

            if shadowColor.w > 0.001
                && (shadowBlur > 0.001 || simd_length(shadowOffset) > 0.001) {
                append(
                    CanvasShapeInstance(
                        positionA: positionA + shadowOffset,
                        positionB: kind == 1 ? positionB : positionB + shadowOffset,
                        positionC: positionC + shadowOffset,
                        color: shadowColor,
                        width: width,
                        kind: kind,
                        softness: max(shadowBlur * 0.7, 1)
                    ),
                    overlay: overlay
                )
            }
            append(
                CanvasShapeInstance(
                    positionA: positionA,
                    positionB: positionB,
                    positionC: positionC,
                    color: color,
                    width: width,
                    kind: kind,
                    softness: 1
                ),
                overlay: overlay
            )
        }

        if hasVignette {
            append(
                CanvasShapeInstance(
                    positionA: .zero,
                    positionB: .zero,
                    positionC: .zero,
                    color: SIMD4(0, 0, 0, 0.6),
                    width: 0,
                    kind: 3,
                    softness: 1
                ),
                overlay: false
            )
        }
        return (instances, batches)
    }

    private func ensureShapeBufferCapacity(_ count: Int) {
        guard count > shapeBufferCapacity else { return }
        var capacity = max(shapeBufferCapacity, 256)
        while capacity < count {
            capacity *= 2
        }
        let length = capacity * MemoryLayout<CanvasShapeInstance>.stride
        shapeBuffers = (0..<3).compactMap { index in
            let buffer = metalContext.device.makeBuffer(
                length: length,
                options: .storageModeShared
            )
            buffer?.label = "Wallflow Canvas Shapes \(index)"
            return buffer
        }
        precondition(shapeBuffers.count == 3)
        shapeBufferCapacity = capacity
        shapeBufferIndex = 0
    }
}
