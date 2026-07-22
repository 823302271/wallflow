import AppKit

protocol WallpaperRenderer: AnyObject {
    var contentView: NSView { get }
    func setRenderingEnabled(_ enabled: Bool)
    func setAudioMuted(_ muted: Bool)
    func setPlaysAudio(_ enabled: Bool)
    func setFitMode(_ fitMode: WallpaperFitMode)
    func updateDesktopFrame(_ frame: CGRect)
    func applyUserProperties(_ properties: JSONValue)
    func prepareForPresentation()
    func captureFrame(completion: @escaping (NSImage?) -> Void)
}

extension WallpaperRenderer {
    func setAudioMuted(_ muted: Bool) {}
    func setPlaysAudio(_ enabled: Bool) {}
    func setFitMode(_ fitMode: WallpaperFitMode) {}
    func updateDesktopFrame(_ frame: CGRect) {}
    func applyUserProperties(_ properties: JSONValue) {}
    func prepareForPresentation() {
        contentView.displayIfNeeded()
    }
    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        let bounds = contentView.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            completion(nil)
            return
        }
        contentView.cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        completion(image)
    }
}

extension WallpaperMetalView: WallpaperRenderer {
    var contentView: NSView { self }

    func prepareForPresentation() {
        displayIfNeeded()
        draw()
    }
}

enum WallpaperRendererFactory {
    static func make(
        project: WallpaperProject,
        frame: CGRect,
        desktopFrame: CGRect,
        playsAudio: Bool,
        fitMode: WallpaperFitMode
    ) -> WallpaperRenderer {
        switch project.kind {
        case .builtIn:
            return WallpaperMetalView(frame: frame, desktopFrame: desktopFrame)
        case .web:
            if let metalRenderer = CanvasMetalWallpaperView.makeIfSupported(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project
            ) {
                return metalRenderer
            }
            return WebWallpaperView(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project,
                playsAudio: playsAudio,
                fitMode: fitMode
            )
        case .scene:
            return SceneWallpaperView(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project,
                playsAudio: playsAudio,
                fitMode: fitMode
            )
        case .video:
            return VideoWallpaperView(
                frame: frame,
                project: project,
                playsAudio: playsAudio,
                fitMode: fitMode
            )
        }
    }
}
