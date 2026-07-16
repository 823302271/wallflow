import AppKit
import CoreGraphics
import CryptoKit

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

    func update(image: NSImage, for screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let pngData = WallpaperSnapshot.pngData(from: image) else { return }
        let digest = SHA256.hash(data: pngData)
            .map { String(format: "%02x", $0) }
            .joined()
        let fallbackURL = directory.appendingPathComponent(
            "display-\(displayID)-\(digest).png"
        )

        do {
            if !FileManager.default.fileExists(atPath: fallbackURL.path) {
                try pngData.write(to: fallbackURL, options: .atomic)
            }
            let currentURL = workspace.desktopImageURL(for: screen)?.standardizedFileURL
            guard currentURL != fallbackURL.standardizedFileURL else { return }
            try workspace.setDesktopImageURL(
                fallbackURL,
                for: screen,
                options: workspace.desktopImageOptions(for: screen) ?? [:]
            )
        } catch {
            NSLog(
                "Wallflow could not set the desktop fallback image: %@",
                error.localizedDescription
            )
        }
    }
}
