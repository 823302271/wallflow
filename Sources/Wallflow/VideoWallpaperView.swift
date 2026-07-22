import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

final class VideoWallpaperView: NSView, WallpaperRenderer {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private let looper: AVPlayerLooper
    private let asset: AVURLAsset
    private var videoOutput: AVPlayerItemVideoOutput?
    private var renderingEnabled = true
    private var playsAudio: Bool
    private var audioMuted = false
    private var fitMode: WallpaperFitMode
    /// Locked media time while paused so resume continues from the same frame.
    private var pausedTime: CMTime?
    private var resumeGeneration = 0

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
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        attachVideoOutput(to: item)
        // AVPlayerLooper swaps items; keep a video output on the active item.
        player.addObserver(self, forKeyPath: "currentItem", options: [.new], context: nil)
        updateAudioState()
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        player.removeObserver(self, forKeyPath: "currentItem")
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "currentItem", let item = player.currentItem {
            attachVideoOutput(to: item)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setRenderingEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        if enabled == renderingEnabled {
            if enabled {
                completion?()
            } else {
                completion?()
            }
            return
        }
        renderingEnabled = enabled
        if enabled {
            resumePlaybackFromPausedTime(completion: completion)
        } else {
            pausePlaybackAndLockTime()
            completion?()
        }
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
        if !renderingEnabled, let pausedTime, pausedTime.isValid, pausedTime.isNumeric {
            if player.timeControlStatus != .paused {
                player.pause()
                player.rate = 0
            }
            let current = player.currentTime()
            if !current.isValid
                || !current.isNumeric
                || abs(current.seconds - pausedTime.seconds) > 0.02 {
                player.seek(
                    to: pausedTime,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        }
        playerLayer.setNeedsDisplay()
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        let time: CMTime
        if let pausedTime, pausedTime.isValid, pausedTime.isNumeric {
            time = pausedTime
        } else {
            time = player.currentTime()
        }
        guard time.isValid, time.isNumeric else {
            completion(nil)
            return
        }

        // Prefer the actual displayed pixel buffer so the freeze frame matches
        // what the user last saw (and what resume will continue from).
        if let image = copyDisplayedFrameImage(at: time) {
            completion(image)
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        DispatchQueue.global(qos: .userInitiated).async {
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

    var isPlaybackPausedForTesting: Bool {
        !renderingEnabled && player.rate == 0
    }

    private func attachVideoOutput(to item: AVPlayerItem) {
        if let existing = videoOutput, item.outputs.contains(existing) {
            return
        }
        if let videoOutput {
            item.remove(videoOutput)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
    }

    private func copyDisplayedFrameImage(at time: CMTime) -> NSImage? {
        // Ensure the current looper item still has our output.
        if let item = player.currentItem {
            attachVideoOutput(to: item)
        }
        guard let videoOutput else { return nil }
        var displayTime = CMTime.invalid
        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)
        let candidates: [CMTime] = [itemTime, time, player.currentTime()]
        for candidate in candidates where candidate.isValid && candidate.isNumeric {
            if let buffer = videoOutput.copyPixelBuffer(
                forItemTime: candidate,
                itemTimeForDisplay: &displayTime
            ) {
                return nsImage(from: buffer)
            }
        }
        return nil
    }

    private func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let cgImage = context.createCGImage(ciImage, from: rect) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func pausePlaybackAndLockTime() {
        resumeGeneration += 1
        let time = player.currentTime()
        if time.isValid, time.isNumeric {
            pausedTime = time
        }
        player.pause()
        player.rate = 0
    }

    private func resumePlaybackFromPausedTime(completion: (() -> Void)?) {
        resumeGeneration += 1
        let generation = resumeGeneration
        let finish: () -> Void = { [weak self] in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            completion?()
        }

        guard let pausedTime, pausedTime.isValid, pausedTime.isNumeric else {
            player.play()
            finish()
            return
        }

        let current = player.currentTime()
        let needsSeek = !current.isValid
            || !current.isNumeric
            || abs(current.seconds - pausedTime.seconds) > 0.01

        let startPlayback = { [weak self] in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            // Keep pausedTime until we actually start — next pause overwrites it.
            self.player.play()
            // Drop the lock after play starts so subsequent captures use live time.
            self.pausedTime = nil
            finish()
        }

        if needsSeek {
            player.seek(
                to: pausedTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                guard let self, generation == self.resumeGeneration else { return }
                guard self.renderingEnabled, finished else {
                    return
                }
                startPlayback()
            }
        } else {
            startPlayback()
        }
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
