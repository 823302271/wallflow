import AppKit
import CoreGraphics

final class DesktopFallbackManager {
    private let workspace = NSWorkspace.shared
    private let directory: URL
    private let encodingQueue = DispatchQueue(
        label: "dev.wallflow.desktop-fallback",
        qos: .utility
    )
    private var generations: [CGDirectDisplayID: Int] = [:]
    /// URLs handed to macOS, oldest first, per display.
    ///
    /// Every publish needs a *fresh* URL: macOS caches the desktop picture by URL,
    /// so reusing a filename can redisplay the content it cached for that name last
    /// time — the wallpaper visibly one step behind. Files are retired strictly by
    /// age here on the main queue, several publishes after they stop being active,
    /// which is what the old prune-by-modification-date got wrong: it raced with
    /// setDesktopImageURL and deleted the picture macOS was reading.
    private var installedURLs: [CGDirectDisplayID: [URL]] = [:]
    private static let retainedFallbackCount = 4

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
        var sourceRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &sourceRect,
            context: nil,
            hints: nil
        ) else {
            return
        }
        let generation = (generations[displayID] ?? 0) + 1
        generations[displayID] = generation
        // Force aspect-fill (scale + clip) so the system desktop still matches
        // Wallflow's freeze/live fill presentation — do not inherit a user stretch
        // mode that makes Space return look like a re-layout.
        var options = workspace.desktopImageOptions(for: screen) ?? [:]
        options[.imageScaling] = NSNumber(
            value: NSImageScaling.scaleProportionallyUpOrDown.rawValue
        )
        options[.allowClipping] = true
        let fallbackURL = directory.appendingPathComponent(
            "display-\(displayID)-\(generation)-\(UUID().uuidString).png"
        )

        encodingQueue.async { [weak self] in
            guard let self,
                  let pngData = WallpaperSnapshot.pngData(from: cgImage) else {
                return
            }
            do {
                try pngData.write(to: fallbackURL, options: .atomic)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // A newer still superseded this one. Leave the file alone: it is
                    // an inactive slot that the next publish will overwrite, and
                    // deleting files in this directory is what previously pulled the
                    // active picture out from under macOS.
                    guard self.generations[displayID] == generation else {
                        try? FileManager.default.removeItem(at: fallbackURL)
                        return
                    }
                    do {
                        try self.workspace.setDesktopImageURL(
                            fallbackURL,
                            for: screen,
                            options: options
                        )
                        self.retire(fallbackURL, for: displayID)
                    } catch {
                        NSLog(
                            "Wallflow could not set the desktop fallback image: %@",
                            error.localizedDescription
                        )
                    }
                }
            } catch {
                NSLog(
                    "Wallflow could not write the desktop fallback image: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// Record a newly installed picture and delete only URLs that have been
    /// superseded several publishes ago — never the one macOS is reading.
    private func retire(_ installedURL: URL, for displayID: CGDirectDisplayID) {
        var urls = installedURLs[displayID] ?? []
        urls.append(installedURL)
        while urls.count > Self.retainedFallbackCount {
            let stale = urls.removeFirst()
            try? FileManager.default.removeItem(at: stale)
        }
        installedURLs[displayID] = urls
    }

    /// One-time sweep of files left by earlier runs. Nothing here can be the
    /// picture macOS is currently reading, because this app has not installed one
    /// yet in this process.
    func removeOrphanedImages(activeURLs: Set<URL>) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension == "png"
                && $0.lastPathComponent.hasPrefix("display-")
                && !activeURLs.contains($0)
        } ?? []
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
