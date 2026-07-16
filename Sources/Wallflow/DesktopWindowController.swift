import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopWindowController {
    private static let wallpaperLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
    )
    private let window: DesktopWindow
    private let wallpaperRenderer: WallpaperRenderer
    private var requestedRenderingEnabled = true
    private(set) var isDesktopHidden = false
    private(set) var screen: NSScreen
    let displayID: CGDirectDisplayID
    private(set) var displayBounds: CGRect
    private(set) var desktopVisibilityBounds: CGRect

    init(screen: NSScreen, project: WallpaperProject, playsAudio: Bool) {
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
            playsAudio: playsAudio
        )
        let displayID = Self.displayID(for: screen)
        self.window = window
        self.wallpaperRenderer = wallpaperRenderer
        self.screen = screen
        self.displayID = displayID
        displayBounds = displayID == 0 ? screen.frame : CGDisplayBounds(displayID)
        desktopVisibilityBounds = Self.desktopVisibilityBounds(
            for: screen,
            displayBounds: displayBounds
        )

        window.title = "Wallflow Renderer"
        window.contentView = wallpaperRenderer.contentView
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
        requestedRenderingEnabled = enabled
        applyRenderingState()
    }

    @discardableResult
    func setDesktopHidden(_ hidden: Bool) -> Bool {
        guard hidden != isDesktopHidden else { return false }
        isDesktopHidden = hidden
        applyRenderingState()
        return true
    }

    func setAudioMuted(_ muted: Bool) {
        wallpaperRenderer.setAudioMuted(muted)
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
        wallpaperRenderer.contentView.frame = CGRect(
            origin: .zero,
            size: screen.frame.size
        )
        window.setFrame(screen.frame, display: true)
        prepareForPresentation()
    }

    func applyUserProperties(_ properties: JSONValue) {
        wallpaperRenderer.applyUserProperties(properties)
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        wallpaperRenderer.captureFrame(completion: completion)
    }

    func prepareForPresentation() {
        window.orderFrontRegardless()
        window.displayIfNeeded()
        wallpaperRenderer.prepareForPresentation()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isDesktopHidden
        )
    }
}
