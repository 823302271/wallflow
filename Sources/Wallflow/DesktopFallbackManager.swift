import AppKit
import CoreGraphics

final class DesktopFallbackManager {
    private let workspace = NSWorkspace.shared
    private let directory: URL

    init() {
        let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = (applicationSupport ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Wallflow/DesktopFallback", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    @discardableResult
    func update(image: NSImage, for screen: NSScreen, displayID: CGDirectDisplayID) -> Bool {
        guard let pngData = WallpaperSnapshot.pngData(from: image) else { return false }
        let fallbackURL = directory.appendingPathComponent(
            "display-\(displayID).png"
        )

        do {
            try pngData.write(to: fallbackURL, options: .atomic)
            try workspace.setDesktopImageURL(
                fallbackURL,
                for: screen,
                options: workspace.desktopImageOptions(for: screen) ?? [:]
            )
            return true
        } catch {
            NSLog(
                "Wallflow could not set the desktop fallback image: %@",
                error.localizedDescription
            )
            return false
        }
    }
}
