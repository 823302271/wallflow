import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Resume is driven by this checkpoint data — not by hoping the player stays
/// frozen at the right frame for a long time. Pause writes the media time;
/// resume always seeks back from that value, regardless of how long we were away
/// or what the system did to buffers/decoders for performance.
private struct VideoPlaybackCheckpoint: Equatable {
    /// Absolute media time in seconds (source of truth).
    let mediaSeconds: Double
    let timescale: CMTimeScale

    var time: CMTime {
        let scale = timescale > 0 ? timescale : 600
        return CMTime(seconds: mediaSeconds, preferredTimescale: scale)
    }

    static func capture(from player: AVPlayer) -> VideoPlaybackCheckpoint? {
        let current = player.currentTime()
        guard current.isValid,
              current.isNumeric,
              current.seconds.isFinite,
              current.seconds >= 0 else {
            return nil
        }
        return VideoPlaybackCheckpoint(
            mediaSeconds: current.seconds,
            timescale: current.timescale
        )
    }
}

final class VideoWallpaperView: NSView, WallpaperRenderer {
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let asset: AVURLAsset
    private var playerItem: AVPlayerItem
    private var videoOutput: AVPlayerItemVideoOutput?
    private var endObserver: NSObjectProtocol?
    private var renderingEnabled = true
    private var playsAudio: Bool
    private var audioMuted = false
    private var fitMode: WallpaperFitMode
    /// Written on pause; resume always restores from this data.
    private var checkpoint: VideoPlaybackCheckpoint?
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
        let item = Self.makePlayerItem(asset: asset)
        playerItem = item
        self.playsAudio = playsAudio
        self.fitMode = fitMode

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        applyFitMode()
        layer?.addSublayer(playerLayer)

        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .none
        // Local files: don't wait/minimize stalling in ways that nudge the playhead.
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        attachVideoOutput(to: item)
        installLoopObserver(for: item)
        updateAudioState()
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
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
            completion?()
            return
        }
        renderingEnabled = enabled
        if enabled {
            restoreFromCheckpointAndPlay(completion: completion)
        } else {
            writeCheckpointAndPause()
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
        // While paused we only show the frozen still from the host; no need to
        // fight the player. Resume will restore from checkpoint data.
        playerLayer.setNeedsDisplay()
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        // Always prefer checkpoint time when paused so the still matches resume.
        let time = checkpoint?.time ?? player.currentTime()
        guard time.isValid, time.isNumeric else {
            completion(nil)
            return
        }

        if let image = copyDisplayedFrameImage(at: time) {
            completion(image)
            return
        }

        // Stable path for long pauses: decode the checkpoint time from the asset
        // directly. Does not depend on live decoder state.
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
        if let checkpoint, !renderingEnabled {
            return checkpoint.mediaSeconds
        }
        return player.currentTime().seconds
    }

    var checkpointMediaSecondsForTesting: TimeInterval? {
        checkpoint?.mediaSeconds
    }

    var playbackStatusForTesting: AVPlayerItem.Status {
        player.currentItem?.status ?? .unknown
    }

    var isPlaybackPausedForTesting: Bool {
        !renderingEnabled && player.rate == 0
    }

    // MARK: - Checkpoint pause / restore

    /// Pause = write resume data once, then stop the player.
    /// Do not keep re-seeking while paused; the checkpoint is the source of truth.
    private func writeCheckpointAndPause() {
        resumeGeneration += 1
        if checkpoint == nil {
            checkpoint = VideoPlaybackCheckpoint.capture(from: player)
        }
        player.pause()
        player.rate = 0
        // Optional: drop the item from the player to free decoder resources during
        // long Space absences. Resume rebuilds from checkpoint + asset.
        // Keeping the item is fine for short pauses; long absences are handled by
        // restoreFromCheckpointAndPlay seeking from data either way.
    }

    /// Resume = read checkpoint data and seek there, then play.
    /// Duration paused does not matter; we never "continue from wherever the
    /// player happened to be" after a long system teardown.
    private func restoreFromCheckpointAndPlay(completion: (() -> Void)?) {
        resumeGeneration += 1
        let generation = resumeGeneration

        let finish: () -> Void = { [weak self] in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            completion?()
        }

        guard let checkpoint else {
            ensurePlayerItemReady()
            player.play()
            finish()
            return
        }

        ensurePlayerItemReady()
        let target = checkpoint.time

        seekToCheckpoint(target, generation: generation, attempt: 0) { [weak self] ok in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            self.player.play()
            // Clear after play starts so the next pause writes a fresh checkpoint.
            self.checkpoint = nil
            DispatchQueue.main.async {
                finish()
            }
            if !ok {
                NSLog(
                    "Wallflow video restore seek was approximate at %.3fs",
                    target.seconds
                )
            }
        }
    }

    private func ensurePlayerItemReady() {
        if player.currentItem == nil || player.currentItem !== playerItem {
            let item = Self.makePlayerItem(asset: asset)
            playerItem = item
            player.replaceCurrentItem(with: item)
            attachVideoOutput(to: item)
            installLoopObserver(for: item)
        }
        // If the item failed while we were away, rebuild it.
        if playerItem.status == .failed {
            let item = Self.makePlayerItem(asset: asset)
            playerItem = item
            player.replaceCurrentItem(with: item)
            attachVideoOutput(to: item)
            installLoopObserver(for: item)
        }
    }

    private func seekToCheckpoint(
        _ time: CMTime,
        generation: Int,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        player.pause()
        player.rate = 0
        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self, generation == self.resumeGeneration else {
                completion(false)
                return
            }
            if !finished {
                if attempt < 3 {
                    self.seekToCheckpoint(
                        time,
                        generation: generation,
                        attempt: attempt + 1,
                        completion: completion
                    )
                } else {
                    completion(false)
                }
                return
            }
            let current = self.player.currentTime()
            let close = current.isValid
                && current.isNumeric
                && abs(current.seconds - time.seconds) <= 0.1
            if close || attempt >= 3 {
                completion(close)
                return
            }
            self.seekToCheckpoint(
                time,
                generation: generation,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private static func makePlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        return item
    }

    // MARK: - Loop / output / helpers

    private func installLoopObserver(for item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.renderingEnabled else { return }
            // Loop is also checkpoint-style: seek to 0 (data), then play.
            self.player.seek(
                to: .zero,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] finished in
                guard let self, finished, self.renderingEnabled else { return }
                self.player.play()
            }
        }
    }

    private func attachVideoOutput(to item: AVPlayerItem) {
        if let existing = videoOutput, item.outputs.contains(existing) {
            return
        }
        if let videoOutput {
            player.currentItem?.remove(videoOutput)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
    }

    private func copyDisplayedFrameImage(at time: CMTime) -> NSImage? {
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
