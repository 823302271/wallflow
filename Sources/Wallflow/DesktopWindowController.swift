import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopWindowController {
    private let window: DesktopWindow
    private let wallpaperRenderer: WallpaperRenderer
    private var requestedRenderingEnabled = true
    private var isCoveredByForegroundWindow = false
    let displayBounds: CGRect

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

        self.window = window
        self.wallpaperRenderer = wallpaperRenderer
        if let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        } else {
            displayBounds = screen.frame
        }

        window.contentView = wallpaperRenderer.contentView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        requestedRenderingEnabled = enabled
        applyRenderingState()
    }

    func setCoveredByForegroundWindow(_ covered: Bool) {
        isCoveredByForegroundWindow = covered
        applyRenderingState()
    }

    func setAudioMuted(_ muted: Bool) {
        wallpaperRenderer.setAudioMuted(muted)
    }

    func applyUserProperties(_ properties: JSONValue) {
        wallpaperRenderer.applyUserProperties(properties)
    }

    func prepareForPresentation() {
        window.orderFrontRegardless()
        window.displayIfNeeded()
        wallpaperRenderer.prepareForPresentation()
    }

    private func applyRenderingState() {
        wallpaperRenderer.setRenderingEnabled(
            requestedRenderingEnabled && !isCoveredByForegroundWindow
        )
    }
}
