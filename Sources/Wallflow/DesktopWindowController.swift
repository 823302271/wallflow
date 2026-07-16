import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopWindowController {
    private let window: DesktopWindow
    private let transitionWindow: DesktopWindow
    private let transitionImageView: NSImageView
    private let wallpaperRenderer: WallpaperRenderer
    private var requestedRenderingEnabled = true
    private(set) var isCoveredByForegroundWindow = false
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    private(set) var displayBounds: CGRect

    init(screen: NSScreen, project: WallpaperProject, playsAudio: Bool) {
        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let transitionWindow = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let transitionImageView = NSImageView(
            frame: CGRect(origin: .zero, size: screen.frame.size)
        )

        let wallpaperRenderer = WallpaperRendererFactory.make(
            project: project,
            frame: CGRect(origin: .zero, size: screen.frame.size),
            desktopFrame: screen.frame,
            playsAudio: playsAudio
        )

        let displayID = Self.displayID(for: screen)
        self.window = window
        self.transitionWindow = transitionWindow
        self.transitionImageView = transitionImageView
        self.wallpaperRenderer = wallpaperRenderer
        self.screen = screen
        self.displayID = displayID
        displayBounds = displayID == 0 ? screen.frame : CGDisplayBounds(displayID)

        transitionImageView.imageScaling = .scaleAxesIndependently
        transitionImageView.autoresizingMask = [.width, .height]
        transitionWindow.title = "Wallflow Transition Frame"
        transitionWindow.contentView = transitionImageView
        configureDesktopWindow(transitionWindow)

        window.title = "Wallflow Renderer"
        window.contentView = wallpaperRenderer.contentView
        configureDesktopWindow(window)
        transitionWindow.orderFrontRegardless()
        window.orderFrontRegardless()
        window.order(.above, relativeTo: transitionWindow.windowNumber)
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
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .stationary,
            .ignoresCycle
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
        requestedRenderingEnabled = enabled
        applyRenderingState()
    }

    @discardableResult
    func setCoveredByForegroundWindow(_ covered: Bool) -> Bool {
        let changed = covered != isCoveredByForegroundWindow
        isCoveredByForegroundWindow = covered
        applyRenderingState()
        return changed
    }

    func setAudioMuted(_ muted: Bool) {
        wallpaperRenderer.setAudioMuted(muted)
    }

    func update(screen: NSScreen, playsAudio: Bool) {
        self.screen = screen
        displayBounds = displayID == 0 ? screen.frame : CGDisplayBounds(displayID)
        wallpaperRenderer.setPlaysAudio(playsAudio)
        wallpaperRenderer.updateDesktopFrame(screen.frame)
        wallpaperRenderer.contentView.frame = CGRect(
            origin: .zero,
            size: screen.frame.size
        )
        transitionImageView.frame = CGRect(origin: .zero, size: screen.frame.size)
        transitionWindow.setFrame(screen.frame, display: true)
        window.setFrame(screen.frame, display: true)
        prepareForPresentation()
    }

    func applyUserProperties(_ properties: JSONValue) {
        wallpaperRenderer.applyUserProperties(properties)
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        wallpaperRenderer.captureFrame(completion: completion)
    }

    func setTransitionFrame(_ image: NSImage) {
        transitionImageView.image = image
        transitionImageView.displayIfNeeded()
    }

    func beginSpaceTransition() {
        transitionWindow.orderFrontRegardless()
        transitionWindow.order(.above, relativeTo: window.windowNumber)
        transitionWindow.displayIfNeeded()
    }

    func finishSpaceTransition() {
        prepareForPresentation()
    }

    func prepareForPresentation() {
        window.orderFrontRegardless()
        window.order(.above, relativeTo: transitionWindow.windowNumber)
        window.displayIfNeeded()
        wallpaperRenderer.prepareForPresentation()
    }

    func close() {
        window.orderOut(nil)
        transitionWindow.orderOut(nil)
        window.close()
        transitionWindow.close()
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isCoveredByForegroundWindow
        )
    }
}
