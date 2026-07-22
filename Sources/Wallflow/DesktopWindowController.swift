import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DesktopPresentationView: NSView {
    private let rendererView: NSView
    private let frozenImageView: NSImageView

    override var isOpaque: Bool { true }

    init(frame: CGRect, rendererView: NSView) {
        self.rendererView = rendererView
        frozenImageView = NSImageView(frame: frame)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]

        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        frozenImageView.frame = bounds
        frozenImageView.autoresizingMask = [.width, .height]
        frozenImageView.imageAlignment = .alignCenter
        frozenImageView.imageScaling = .scaleAxesIndependently
        frozenImageView.isHidden = true

        addSubview(rendererView)
        addSubview(frozenImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showFrozenFrame(_ image: NSImage) {
        frozenImageView.image = image
        frozenImageView.isHidden = false
        frozenImageView.needsDisplay = true
    }

    func hideFrozenFrame() {
        frozenImageView.isHidden = true
    }

    var isShowingFrozenFrame: Bool {
        !frozenImageView.isHidden && frozenImageView.image != nil
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
    private var presentationGeneration = 0
    private var frameCaptureGeneration = 0
    private(set) var isDesktopHidden = false
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    private(set) var displayBounds: CGRect
    private(set) var desktopVisibilityBounds: CGRect

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
        // full-screen Spaces (especially secondary displays) so it never pauses.
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

    var isWindowVisible: Bool {
        window.occlusionState.contains(.visible)
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
            isLiveSurfaceEnabled = false
            applyRenderingState()
            capturePausedFrame(generation: generation, publishDesktopFallback: true)
        }
    }

    @discardableResult
    func setDesktopHidden(_ hidden: Bool) -> Bool {
        guard hidden != isDesktopHidden else { return false }
        isDesktopHidden = hidden
        presentationGeneration += 1
        let generation = presentationGeneration
        if hidden {
            // Freeze first, pause immediately — playhead must not advance while hidden.
            isLiveSurfaceEnabled = false
            applyRenderingState()
            capturePausedFrame(generation: generation, publishDesktopFallback: true)
        } else {
            // Show the paused still and only re-enable the live surface when revealing
            // so resume does not play "under" the freeze (which looked like a jump to
            // a future frame).
            showCachedFrozenFrame()
            isLiveSurfaceEnabled = false
            applyRenderingState()
            prepareForPresentation()
            if requestedRenderingEnabled {
                beginLiveReveal(generation: generation)
            }
        }
        return true
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
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func manages(window candidate: NSWindow) -> Bool {
        candidate === window
    }

    func close() {
        presentationGeneration += 1
        frameCaptureGeneration += 1
        window.orderOut(nil)
        window.close()
    }

    private func showCachedFrozenFrame() {
        guard let frozenFrame else { return }
        presentationView.showFrozenFrame(frozenFrame)
    }

    private func capturePausedFrame(generation: Int, publishDesktopFallback: Bool) {
        showCachedFrozenFrame()
        captureLiveFrame { [weak self] image in
            guard let self, generation == self.presentationGeneration else { return }
            guard let image else { return }
            self.frozenFrame = image
            self.presentationView.showFrozenFrame(image)
            if publishDesktopFallback {
                self.onPausedFrameCaptured?(image)
            }
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
    private func beginLiveReveal(generation: Int) {
        showCachedFrozenFrame()
        isLiveSurfaceEnabled = true
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
            // One run-loop turn lets the first resumed frame composite before
            // removing the still, avoiding a one-frame black/future flash.
            DispatchQueue.main.async {
                guard generation == self.presentationGeneration,
                      !self.isDesktopHidden,
                      self.requestedRenderingEnabled,
                      self.isLiveSurfaceEnabled else {
                    return
                }
                self.presentationView.hideFrozenFrame()
            }
        }
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isDesktopHidden && isLiveSurfaceEnabled
        )
    }
}
