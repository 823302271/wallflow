import AppKit
import CoreGraphics

final class DesktopFallbackManager {
    private struct OriginalDesktop {
        let url: URL
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
    }

    private let workspace = NSWorkspace.shared
    private let directory: URL
    private var originals: [CGDirectDisplayID: OriginalDesktop] = [:]
    private var currentFallbacks: [CGDirectDisplayID: URL] = [:]

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

        if originals[displayID] == nil,
           let currentURL = workspace.desktopImageURL(for: screen) {
            let defaultsKey = "Wallflow.originalDesktop.\(displayID)"
            let savedOriginalURL = UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(URL.init(string:))
            let originalURL = currentURL.path.hasPrefix(directory.path)
                ? savedOriginalURL ?? currentURL
                : currentURL
            originals[displayID] = OriginalDesktop(
                url: originalURL,
                options: workspace.desktopImageOptions(for: screen) ?? [:]
            )
            UserDefaults.standard.set(originalURL.absoluteString, forKey: defaultsKey)
        }
        guard let original = originals[displayID] else { return }

        let fallbackURL = directory.appendingPathComponent(
            "display-\(displayID)-\(UUID().uuidString).png"
        )
        do {
            try pngData.write(to: fallbackURL, options: .atomic)
            try workspace.setDesktopImageURL(
                fallbackURL,
                for: screen,
                options: original.options
            )
            if let previous = currentFallbacks.updateValue(fallbackURL, forKey: displayID),
               previous != fallbackURL {
                try? FileManager.default.removeItem(at: previous)
            }
        } catch {
            try? FileManager.default.removeItem(at: fallbackURL)
            NSLog("Wallflow could not set the desktop fallback image: %@", error.localizedDescription)
        }
    }

    func restoreOriginalDesktops() {
        var screensByID: [CGDirectDisplayID: NSScreen] = [:]
        NSScreen.screens.forEach { screen in
            let displayID = DesktopWindowController.displayID(for: screen)
            if screensByID[displayID] == nil {
                screensByID[displayID] = screen
            }
        }
        for (displayID, original) in originals {
            guard let screen = screensByID[displayID] else { continue }
            do {
                try workspace.setDesktopImageURL(
                    original.url,
                    for: screen,
                    options: original.options
                )
            } catch {
                NSLog("Wallflow could not restore the desktop image: %@", error.localizedDescription)
            }
            UserDefaults.standard.removeObject(
                forKey: "Wallflow.originalDesktop.\(displayID)"
            )
        }
        for url in currentFallbacks.values {
            try? FileManager.default.removeItem(at: url)
        }
        currentFallbacks.removeAll()
        originals.removeAll()
    }
}
