import AppKit
import Foundation

final class WallflowLibrarySelfTest {
    private var controller: WallpaperLibraryWindowController?
    private var completion: ((Result<URL, Error>) -> Void)?

    func run(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
        let now = Date()
        let entries = [
            WallpaperLibraryEntry(
                id: UUID(),
                source: "/tmp/interactive-koi-pond/project.json",
                title: "Interactive Koi Pond",
                kind: WallpaperProject.Kind.web.rawValue,
                addedAt: now
            ),
            WallpaperLibraryEntry(
                id: UUID(),
                source: "https://example.com/wallpaper.mp4",
                title: "Ocean Loop",
                kind: WallpaperProject.Kind.video.rawValue,
                addedAt: now.addingTimeInterval(1)
            ),
            WallpaperLibraryEntry(
                id: UUID(),
                source: "/missing/scene/project.json",
                title: "Missing Scene",
                kind: WallpaperProject.Kind.scene.rawValue,
                addedAt: now.addingTimeInterval(2)
            )
        ]
        let controller = WallpaperLibraryWindowController(
            entries: entries,
            currentEntryID: entries[1].id,
            isBuiltInCurrent: false,
            onUse: { _ in },
            onLocateUnavailable: { _ in },
            onRemove: { _ in },
            onReveal: { _ in },
            onImportFile: {},
            onImportURL: {}
        )
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.captureWindow()
        }
    }

    private func captureWindow() {
        guard let contentView = controller?.window?.contentView else {
            finish(.failure(WallflowSelfTestError.failed("Library window was not created")))
            return
        }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            finish(.failure(WallflowSelfTestError.failed("Library window capture failed")))
            return
        }
        contentView.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            finish(.failure(WallflowSelfTestError.failed("Library window PNG failed")))
            return
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-library-self-test.png")
        do {
            try data.write(to: outputURL, options: .atomic)
            finish(.success(outputURL))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let completion else { return }
        self.completion = nil
        controller?.close()
        controller = nil
        completion(result)
    }
}
