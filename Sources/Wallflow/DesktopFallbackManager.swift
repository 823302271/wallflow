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
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let fallbackURL = directory.appendingPathComponent(
            "display-\(displayID)-\(UUID().uuidString).png"
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
                        self.pruneFallbackImages(
                            for: displayID,
                            keeping: fallbackURL
                        )
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

    private func pruneFallbackImages(
        for displayID: CGDirectDisplayID,
        keeping currentURL: URL
    ) {
        let prefix = "display-\(displayID)-"
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "png"
        } ?? []
        let sorted = urls.sorted {
            let left = try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let right = try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        for url in sorted.filter({ $0 != currentURL }).dropFirst(2) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("display-\(displayID).png")
        )
    }
}
