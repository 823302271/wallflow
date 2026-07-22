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
}

final class DesktopWindowController {
    private static let wallpaperLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
    )
    private let window: DesktopWindow
    private let wallpaperRenderer: WallpaperRenderer
    private let presentationView: DesktopPresentationView
    private var requestedRenderingEnabled = true
    private var frozenFrame: NSImage?
    private var presentationGeneration = 0
    private var frameCaptureGeneration = 0
    private(set) var isDesktopHidden = false
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    private(set) var displayBounds: CGRect
    private(set) var desktopVisibilityBounds: CGRect

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
        displayBounds = displayID == 0 ? screen.frame : CGDisplayBounds(displayID)
        desktopVisibilityBounds = Self.desktopVisibilityBounds(
            for: screen,
            displayBounds: displayBounds
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
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.canHide = false
        window.level = Self.wallpaperLevel
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
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

    private static func desktopVisibilityBounds(
        for screen: NSScreen,
        displayBounds: CGRect
    ) -> CGRect {
        let visibleFrame = screen.visibleFrame
        return CGRect(
            x: displayBounds.minX + visibleFrame.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard requestedRenderingEnabled != enabled else { return }
        requestedRenderingEnabled = enabled
        presentationGeneration += 1
        if enabled {
            applyRenderingState()
            if !isDesktopHidden {
                prepareForPresentation()
                scheduleLiveFrameReveal(generation: presentationGeneration)
            }
        } else {
            showCachedFrozenFrame()
            refreshFrozenFrame()
            applyRenderingState()
        }
    }

    @discardableResult
    func setDesktopHidden(_ hidden: Bool) -> Bool {
        guard hidden != isDesktopHidden else { return false }
        isDesktopHidden = hidden
        presentationGeneration += 1
        let generation = presentationGeneration
        if hidden {
            showCachedFrozenFrame()
            refreshFrozenFrame()
            applyRenderingState()
        } else {
            showCachedFrozenFrame()
            applyRenderingState()
            prepareForPresentation()
            if requestedRenderingEnabled {
                scheduleLiveFrameReveal(generation: generation)
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
        displayBounds = displayID == 0 ? screen.frame : CGDisplayBounds(displayID)
        desktopVisibilityBounds = Self.desktopVisibilityBounds(
            for: screen,
            displayBounds: displayBounds
        )
        wallpaperRenderer.setPlaysAudio(playsAudio)
        wallpaperRenderer.updateDesktopFrame(screen.frame)
        presentationView.frame = CGRect(
            origin: .zero,
            size: screen.frame.size
        )
        wallpaperRenderer.contentView.frame = presentationView.bounds
        window.setFrame(screen.frame, display: true)
        prepareForPresentation()
    }

    func applyUserProperties(_ properties: JSONValue) {
        wallpaperRenderer.applyUserProperties(properties)
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        if (isDesktopHidden || !requestedRenderingEnabled), let frozenFrame {
            completion(frozenFrame)
            return
        }
        refreshFrozenFrame(completion: completion)
    }

    func prepareForPresentation() {
        window.orderFrontRegardless()
        window.displayIfNeeded()
        wallpaperRenderer.prepareForPresentation()
    }

    func prepareForSpacePresentation() {
        presentationGeneration += 1
        let generation = presentationGeneration
        showCachedFrozenFrame()
        prepareForPresentation()
        if !isDesktopHidden, requestedRenderingEnabled {
            scheduleLiveFrameReveal(generation: generation)
        }
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

    private func refreshFrozenFrame(
        completion: ((NSImage?) -> Void)? = nil
    ) {
        frameCaptureGeneration += 1
        let generation = frameCaptureGeneration
        wallpaperRenderer.captureFrame { [weak self] image in
            guard let self,
                  generation == self.frameCaptureGeneration,
                  let image,
                  let snapshot = WallpaperSnapshot.preparedImage(from: image) else {
                completion?(nil)
                return
            }
            self.frozenFrame = snapshot
            if self.isDesktopHidden || !self.requestedRenderingEnabled {
                self.presentationView.showFrozenFrame(snapshot)
            }
            completion?(snapshot)
        }
    }

    private func scheduleLiveFrameReveal(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  generation == self.presentationGeneration,
                  !self.isDesktopHidden,
                  self.requestedRenderingEnabled else {
                return
            }
            self.presentationView.hideFrozenFrame()
        }
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isDesktopHidden
        )
    }
}
