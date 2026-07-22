import AppKit
import AVFoundation

final class VideoWallpaperView: NSView, WallpaperRenderer {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private let looper: AVPlayerLooper
    private let asset: AVURLAsset
    private var renderingEnabled = true
    private var playsAudio: Bool
    private var audioMuted = false
    private var fitMode: WallpaperFitMode

    var contentView: NSView { self }

    init(
        frame: CGRect,
        project: WallpaperProject,
        playsAudio: Bool,
        fitMode: WallpaperFitMode = .automatic
    ) {
        guard let entryURL = project.entryURL else {
            preconditionFailure("Video wallpaper requires an entry URL")
        }

        asset = AVURLAsset(url: entryURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        self.playsAudio = playsAudio
        self.fitMode = fitMode
        looper = AVPlayerLooper(player: player, templateItem: item)

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        applyFitMode()
        layer?.addSublayer(playerLayer)

        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        updateAudioState()
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != renderingEnabled else { return }
        renderingEnabled = enabled
        enabled ? player.play() : player.pause()
    }

    func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        updateAudioState()
    }

    func setPlaysAudio(_ enabled: Bool) {
        playsAudio = enabled
        updateAudioState()
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        guard fitMode != self.fitMode else { return }
        self.fitMode = fitMode
        applyFitMode()
    }

    func updateDesktopFrame(_ frame: CGRect) {}

    func applyUserProperties(_ properties: JSONValue) {}

    func prepareForPresentation() {
        layoutSubtreeIfNeeded()
        playerLayer.setNeedsDisplay()
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        let time = player.currentTime()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)

        DispatchQueue.global(qos: .utility).async {
            let image = try? generator.copyCGImage(at: time, actualTime: nil)
            DispatchQueue.main.async {
                completion(image.map {
                    NSImage(
                        cgImage: $0,
                        size: NSSize(width: $0.width, height: $0.height)
                    )
                })
            }
        }
    }

    var playbackTimeForTesting: TimeInterval {
        player.currentTime().seconds
    }

    var playbackStatusForTesting: AVPlayerItem.Status {
        player.currentItem?.status ?? .unknown
    }

    private func updateAudioState() {
        player.isMuted = audioMuted || !playsAudio
    }

    private func applyFitMode() {
        playerLayer.videoGravity = switch fitMode {
        case .automatic, .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }

    var videoGravityForTesting: AVLayerVideoGravity {
        playerLayer.videoGravity
    }
}
