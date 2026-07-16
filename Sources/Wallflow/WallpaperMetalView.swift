import AppKit
import MetalKit
import QuartzCore
import simd

private struct WallpaperUniforms {
    var resolution: SIMD2<Float>
    var mouse: SIMD2<Float>
    var time: Float
    var activity: Float
    var intensity: Float
    var padding: Float = 0
}

final class WallpaperMetalView: MTKView, MTKViewDelegate {
    private let context: MetalContext
    private let startTime = CACurrentMediaTime()
    private var desktopFrame: CGRect
    private var smoothedMouse = SIMD2<Float>(0.5, 0.5)
    private var lastMouse = SIMD2<Float>(0.5, 0.5)
    private var lastInteractionTime = CACurrentMediaTime()
    private var configuredFPS = 0
    private var frozenElapsedTime: Float?
    private let renderScale: CGFloat = 0.75

    init(
        frame: CGRect,
        desktopFrame: CGRect,
        context: MetalContext = .shared
    ) {
        self.context = context
        self.desktopFrame = desktopFrame
        super.init(frame: frame, device: context.device)
        configureMetalView()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        let isCurrentlyEnabled = !isPaused
        guard enabled != isCurrentlyEnabled else { return }
        if enabled {
            frozenElapsedTime = nil
        } else {
            frozenElapsedTime = Float(CACurrentMediaTime() - startTime)
        }
        isPaused = !enabled
        if enabled {
            lastInteractionTime = CACurrentMediaTime()
            draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        autoreleasepool {
            renderFrame()
        }
    }

    private func configureMetalView() {
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.01, green: 0.015, blue: 0.02, alpha: 1)
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = false
        presentsWithTransaction = false
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.allowsNextDrawableTimeout = true
        }
        updateDrawableSize()
        setPreferredFPS(60)
    }

    private func updateDrawableSize() {
        drawableSize = CGSize(
            width: max(1, bounds.width * renderScale),
            height: max(1, bounds.height * renderScale)
        )
    }

    private func renderFrame() {
        guard let renderPassDescriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                  descriptor: renderPassDescriptor
              ) else {
            return
        }

        let now = CACurrentMediaTime()
        let mouseState = updateMouseState(now: now)
        setPreferredFPS(mouseState.isActive ? 60 : 24)

        var uniforms = WallpaperUniforms(
            resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: smoothedMouse,
            time: frozenElapsedTime ?? Float(now - startTime),
            activity: mouseState.activity,
            intensity: 1
        )

        encoder.label = "Wallflow Frame"
        encoder.setRenderPipelineState(context.pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<WallpaperUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateMouseState(now: CFTimeInterval) -> (isActive: Bool, activity: Float) {
        let globalMouse = NSEvent.mouseLocation
        var target = smoothedMouse

        if desktopFrame.contains(globalMouse) {
            let normalizedX = (globalMouse.x - desktopFrame.minX) / desktopFrame.width
            let normalizedY = (globalMouse.y - desktopFrame.minY) / desktopFrame.height
            target = SIMD2(
                Float(min(max(normalizedX, 0), 1)),
                Float(1 - min(max(normalizedY, 0), 1))
            )

            if simd_distance(target, lastMouse) > 0.001 {
                lastInteractionTime = now
                lastMouse = target
            }
        }

        smoothedMouse += (target - smoothedMouse) * 0.12
        let elapsed = max(0, now - lastInteractionTime)
        let activity = Float(exp(-elapsed * 2.4))
        return (elapsed < 1.5, activity)
    }

    private func setPreferredFPS(_ fps: Int) {
        guard fps != configuredFPS else { return }
        configuredFPS = fps
        preferredFramesPerSecond = fps
    }
}
