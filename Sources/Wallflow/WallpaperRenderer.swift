import AppKit

protocol WallpaperRenderer: AnyObject {
    var contentView: NSView { get }
    func setRenderingEnabled(_ enabled: Bool)
    func setAudioMuted(_ muted: Bool)
    func applyUserProperties(_ properties: JSONValue)
}

extension WallpaperRenderer {
    func setAudioMuted(_ muted: Bool) {}
    func applyUserProperties(_ properties: JSONValue) {}
}

extension WallpaperMetalView: WallpaperRenderer {
    var contentView: NSView { self }
}

enum WallpaperRendererFactory {
    static func make(
        project: WallpaperProject,
        frame: CGRect,
        desktopFrame: CGRect,
        playsAudio: Bool
    ) -> WallpaperRenderer {
        switch project.kind {
        case .builtIn:
            return WallpaperMetalView(frame: frame, desktopFrame: desktopFrame)
        case .web:
            return WebWallpaperView(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project,
                playsAudio: playsAudio
            )
        case .scene:
            return SceneWallpaperView(
                frame: frame,
                desktopFrame: desktopFrame,
                project: project,
                playsAudio: playsAudio
            )
        }
    }
}
