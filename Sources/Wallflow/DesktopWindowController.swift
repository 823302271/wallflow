import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Still-frame overlay that matches typical wallpaper fill (aspect-fill / crop),
/// not stretch — so Space resume does not flash a re-stretched frame before play.
private final class FrozenFrameView: NSView {
    private let imageLayer = CALayer()

    override var isOpaque: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer?.addSublayer(imageLayer)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        CATransaction.commit()
    }

    func show(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cgImage
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        imageLayer.frame = bounds
        CATransaction.commit()
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }

    var hasImage: Bool {
        imageLayer.contents != nil && !isHidden
    }
}

private final class DesktopPresentationView: NSView {
    private let rendererView: NSView
    private let frozenFrameView: FrozenFrameView

    override var isOpaque: Bool { true }

    init(frame: CGRect, rendererView: NSView) {
        self.rendererView = rendererView
        frozenFrameView = FrozenFrameView(frame: frame)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]

        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        frozenFrameView.frame = bounds
        frozenFrameView.autoresizingMask = [.width, .height]

        addSubview(rendererView)
        addSubview(frozenFrameView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showFrozenFrame(_ image: NSImage) {
        frozenFrameView.show(image)
        // Keep the paused renderer attached beneath the still. Hiding and unhiding
        // an MTKView tears down its drawable; returning from Space could then expose
        // an older drawable before the restored pause frame was presented.
    }

    func hideFrozenFrame() {
        frozenFrameView.hide()
    }

    var isShowingFrozenFrame: Bool {
        frozenFrameView.hasImage
    }
}

final class DesktopWindowController {
    private static let wallpaperLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
    )
    private let window: DesktopWindow
    private let wallpaperRenderer: WallpaperRenderer
    private let presentationView: DesktopPresentationView
    private var requestedRenderingEnabled = true
    /// Live surface (video/canvas) only runs when this is true.
    /// Kept false under the freeze overlay so playhead cannot advance ahead of the still.
    private var isLiveSurfaceEnabled = true
    private var frozenFrame: NSImage?
    /// Freeze image locked while a paused renderer prepares its matching live frame.
    private var pauseSessionFrozenFrame: NSImage?
    private var presentationGeneration = 0
    private var frameCaptureGeneration = 0
    private(set) var isDesktopHidden = false
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    private(set) var displayBounds: CGRect
    private(set) var desktopVisibilityBounds: CGRect
    /// Opaque token for the wallpaper project rendered on this display so the
    /// host can reuse controllers only when the assignment is unchanged.
    var projectIdentity: String = ""

    /// Invoked when this display pauses and a fresh still frame is available.
    var onPausedFrameCaptured: ((NSImage) -> Void)?

    init(
        screen: NSScreen,
        project: WallpaperProject,
        playsAudio: Bool,
        fitMode: WallpaperFitMode
    ) {
        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let wallpaperRenderer = WallpaperRendererFactory.make(
            project: project,
            frame: CGRect(origin: .zero, size: screen.frame.size),
            desktopFrame: screen.frame,
            playsAudio: playsAudio,
            fitMode: fitMode
        )
        let displayID = Self.displayID(for: screen)
        let presentationView = DesktopPresentationView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            rendererView: wallpaperRenderer.contentView
        )
        self.window = window
        self.wallpaperRenderer = wallpaperRenderer
        self.presentationView = presentationView
        self.screen = screen
        self.displayID = displayID
        displayBounds = CGDisplayBounds(displayID)
        desktopVisibilityBounds = DesktopVisibility.desktopQuartzBounds(
            displayID: displayID,
            screen: screen
        )

        window.title = "Wallflow Renderer"
        window.contentView = presentationView
        configureDesktopWindow(window)
        window.orderFrontRegardless()
    }

    private func configureDesktopWindow(_ window: DesktopWindow) {
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.canHide = false
        window.level = Self.wallpaperLevel
        // Do NOT use .fullScreenAuxiliary — that keeps the wallpaper alive on
        // full-screen Spaces so it never pauses.
        // Join desktop Spaces so each one gets the live renderer. Per-display
        // occlusion/coverage decides when a full-screen Space should pause it.
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .ignoresCycle,
            .stationary
        ]
        window.setFrame(screen.frame, display: true)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard requestedRenderingEnabled != enabled else { return }
        requestedRenderingEnabled = enabled
        presentationGeneration += 1
        let generation = presentationGeneration
        if enabled {
            if !isDesktopHidden {
                beginLiveReveal(generation: generation)
            } else {
                isLiveSurfaceEnabled = false
                applyRenderingState()
            }
        } else {
            // Pause the live surface, then capture once the renderer confirms freeze.
            isLiveSurfaceEnabled = false
            beginPausedCapture(generation: generation, publishDesktopFallback: true)
        }
    }

    @discardableResult
    func setDesktopHidden(_ hidden: Bool) -> Bool {
        guard hidden != isDesktopHidden else { return false }
        if hidden {
            isDesktopHidden = true
            presentationGeneration += 1
            let generation = presentationGeneration
            isLiveSurfaceEnabled = false
            // Freeze particle state before capturing the same frame as the scene.
            wallpaperRenderer.setParticlesActive(false)
            // The system desktop picture is what the Space transition animation
            // actually shows — our window does not participate in that animation.
            // Left unpublished it holds a frame from minutes ago and the return to
            // the desktop cuts straight from it to the live frame.
            //
            // It has to be republished, but setDesktopImageURL refreshes WindowServer
            // globally and hitches unrelated displays, so the host delays it well
            // past the transition instead of firing during the animation.
            beginPausedCapture(generation: generation, publishDesktopFallback: true)
            return true
        }

        isDesktopHidden = false
        presentationGeneration += 1
        let generation = presentationGeneration
        // Identical to the manual-resume path in setRenderingEnabled(_:). A Space
        // hop must not take a different route than an ordinary unpause: the extra
        // applyRenderingState()/prepareForPresentation() that used to run here
        // re-entered the renderer's pause/present machinery on the way out.
        if requestedRenderingEnabled {
            beginLiveReveal(generation: generation)
        } else {
            isLiveSurfaceEnabled = false
            applyRenderingState()
        }
        return true
    }

    private func commitPauseSession() {
        guard !isDesktopHidden, isLiveSurfaceEnabled, requestedRenderingEnabled else {
            return
        }
        pauseSessionFrozenFrame = nil
        frozenFrame = nil
        wallpaperRenderer.commitPauseSession()
    }

    func setAudioMuted(_ muted: Bool) {
        wallpaperRenderer.setAudioMuted(muted)
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        wallpaperRenderer.setFitMode(fitMode)
    }

    func update(screen: NSScreen, playsAudio: Bool) {
        self.screen = screen
        displayBounds = CGDisplayBounds(displayID)
        desktopVisibilityBounds = DesktopVisibility.desktopQuartzBounds(
            displayID: displayID,
            screen: screen
        )
        wallpaperRenderer.setPlaysAudio(playsAudio)
        wallpaperRenderer.updateDesktopFrame(screen.frame)
        presentationView.frame = CGRect(
            origin: .zero,
            size: screen.frame.size
        )
        wallpaperRenderer.contentView.frame = presentationView.bounds
        window.ignoresMouseEvents = true
        window.setFrame(screen.frame, display: true)
        prepareForPresentation()
    }

    func applyUserProperties(_ properties: JSONValue) {
        wallpaperRenderer.applyUserProperties(properties)
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        if (isDesktopHidden || !requestedRenderingEnabled || !isLiveSurfaceEnabled),
           let frozenFrame {
            completion(frozenFrame)
            return
        }
        captureLiveFrame(completion: completion)
    }

    func prepareForPresentation() {
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.displayIfNeeded()
        wallpaperRenderer.prepareForPresentation()
    }

    func ensureDesktopLayering() {
        // Do not order the wallpaper forward while the desktop is hidden: a
        // full-screen Dock restore would pop it into the animation and flicker
        // on the way back.
        guard !isDesktopHidden else { return }
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func manages(window candidate: NSWindow) -> Bool {
        candidate === window
    }

    /// WindowServer's own per-display verdict on whether this wallpaper window can
    /// be seen. Unlike coverage geometry it accounts for the window being on a
    /// Space the user is not looking at.
    var isWindowVisible: Bool {
        window.occlusionState.contains(.visible)
    }

    func close() {
        presentationGeneration += 1
        frameCaptureGeneration += 1
        window.orderOut(nil)
        window.close()
    }

    /// Disable the live surface and capture a still only after the renderer reports
    /// that its playhead is frozen (so snapshot == resume checkpoint).
    ///
    /// Nothing is posted to the overlay before the renderer is pinned. The paused
    /// renderer keeps the exact frame the user last saw, so any cached still put up
    /// here can only be older than what is already correct on screen.
    private func beginPausedCapture(generation: Int, publishDesktopFallback: Bool) {
        // pinToPauseSession always re-snaps even when the renderer was already paused.
        wallpaperRenderer.pinToPauseSession { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            // Already locked this hide-session: do not replace with a live frame
            // that may have advanced during a false resume.
            if let sticky = self.pauseSessionFrozenFrame {
                self.frozenFrame = sticky
                self.presentationView.showFrozenFrame(sticky)
                if publishDesktopFallback {
                    self.onPausedFrameCaptured?(sticky)
                }
                return
            }
            self.capturePausedFrame(
                generation: generation,
                publishDesktopFallback: publishDesktopFallback
            )
        }
    }

    private func capturePausedFrame(generation: Int, publishDesktopFallback: Bool) {
        captureLiveFrame { [weak self] image in
            guard let self else { return }
            guard let image else {
                NSLog(
                    "Wallflow display %u paused capture FAILED",
                    self.displayID
                )
                return
            }
            // The still belongs to the renderer's frozen timeline, not to a
            // presentation generation. A pause/resume landing during this async
            // Metal capture must not discard the publish, or the system desktop
            // picture keeps showing a frame from an earlier freeze — which is what
            // shows through during the Space animation and reads as a jump.
            if publishDesktopFallback {
                self.onPausedFrameCaptured?(image)
            }
            guard generation == self.presentationGeneration else {
                NSLog(
                    "Wallflow display %u paused still superseded (published anyway)",
                    self.displayID
                )
                return
            }
            self.frozenFrame = image
            self.pauseSessionFrozenFrame = image
            self.presentationView.showFrozenFrame(image)
        }
    }

    private func captureLiveFrame(completion: ((NSImage?) -> Void)? = nil) {
        frameCaptureGeneration += 1
        let generation = frameCaptureGeneration
        wallpaperRenderer.captureFrame { [weak self] image in
            guard let self,
                  generation == self.frameCaptureGeneration else {
                completion?(nil)
                return
            }
            guard let image,
                  let snapshot = WallpaperSnapshot.preparedImage(from: image) else {
                completion?(nil)
                return
            }
            completion?(snapshot)
        }
    }

    /// Enable live rendering only at the reveal moment, then drop the freeze.
    ///
    /// Contract with renderers: `setRenderingEnabled(true, completion:)` must call
    /// completion while still showing the pause-frame (playhead not yet advancing).
    /// We drop the freeze on that matching frame; renderers start time on the next turn.
    private func beginLiveReveal(generation: Int) {
        isLiveSurfaceEnabled = true
        // Resume particle simulation with the scene after the matching still is ready.
        wallpaperRenderer.setParticlesActive(
            requestedRenderingEnabled && !isDesktopHidden
        )
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isDesktopHidden && isLiveSurfaceEnabled
        ) { [weak self] in
            guard let self,
                  generation == self.presentationGeneration,
                  !self.isDesktopHidden,
                  self.requestedRenderingEnabled,
                  self.isLiveSurfaceEnabled else {
                return
            }
            // Drop freeze immediately while the live surface still matches it.
            // Renderers deliberately delay playhead advance until the next run-loop.
            self.presentationView.hideFrozenFrame()
            self.commitPauseSession()
        }
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isDesktopHidden && isLiveSurfaceEnabled
        )
        // Every pause reason also suspends particle simulation and input.
        if !isDesktopHidden {
            wallpaperRenderer.setParticlesActive(requestedRenderingEnabled)
        }
    }
}
