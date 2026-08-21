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
    /// Stays locked until the host reveals the restored matching frame.
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
            if !enabled {
                // Already paused: still pin playhead to the session checkpoint.
                pinToPauseSession(completion: completion)
            } else {
                completion?()
            }
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

    func pinToPauseSession(completion: (() -> Void)?) {
        renderingEnabled = false
        writeCheckpointAndPause()
        completion?()
    }

    func commitPauseSession() {
        // Only the host may release the lock after the matching frame is ready.
        // `rate` may temporarily be zero while AVPlayer buffers or reaches a loop
        // boundary; renderingEnabled is the authoritative host state.
        guard renderingEnabled else { return }
        checkpoint = nil
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

        // While paused, never prefer the live host-time buffer — it can lag the
        // checkpoint by a frame or two and produce a freeze that does not match seek.
        if let image = copyDisplayedFrameImage(
            at: time,
            preferCheckpointOnly: checkpoint != nil && !renderingEnabled
        ) {
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

    var playerRateForTesting: Float {
        player.rate
    }

    // MARK: - Checkpoint pause / restore

    /// Pause = lock resume data once for this hide-session, then stop the player.
    /// Re-pauses during a flaky Space transition keep the same checkpoint and snap
    /// the playhead back — they must never capture a "future" media time.
    private func writeCheckpointAndPause() {
        resumeGeneration += 1
        if let existing = checkpoint {
            player.pause()
            player.rate = 0
            // Snap back immediately so a brief false resume cannot leave the
            // decoder parked ahead of the locked pause frame.
            player.seek(
                to: existing.time,
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { _ in }
            )
            return
        }
        checkpoint = VideoPlaybackCheckpoint.capture(from: player)
        player.pause()
        player.rate = 0
    }

    /// Resume = seek to checkpoint while still paused, hand the matching frame to
    /// the host (so the freeze overlay can drop), then start playback.
    /// The checkpoint stays locked until continuous play has been committed so a
    /// Space-transition re-pause cannot rewrite it to a future frame.
    private func restoreFromCheckpointAndPlay(completion: (() -> Void)?) {
        resumeGeneration += 1
        let generation = resumeGeneration

        let revealReady: () -> Void = { [weak self] in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            let playbackStartTime = self.player.currentTime()
            // Host hides the freeze while we are still paused at the checkpoint.
            completion?()
            // One run-loop turn after reveal: only then advance the playhead.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.resumeGeneration,
                      self.renderingEnabled else {
                    return
                }
                self.startPlayback(
                    generation: generation,
                    baseline: playbackStartTime,
                    attempt: 0
                )
                // The host clears the checkpoint after this matching frame is
                // revealed. An aborted reveal keeps it locked for the next retry.
            }
        }

        var didFinishPreroll = false
        let revealAfterPreroll: () -> Void = {
            guard !didFinishPreroll else { return }
            didFinishPreroll = true
            revealReady()
        }
        let prerollThenReveal: () -> Void = { [weak self] in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            self.player.preroll(atRate: 1) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self,
                          generation == self.resumeGeneration,
                          self.renderingEnabled else {
                        return
                    }
                    revealAfterPreroll()
                }
            }
            // AVPlayer can delay a preroll callback while rebuilding a decoder.
            // Keep the frozen frame bounded, then let guarded playback retries run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self,
                      generation == self.resumeGeneration,
                      self.renderingEnabled else {
                    return
                }
                revealAfterPreroll()
            }
        }

        guard let checkpoint else {
            ensurePlayerItemReady()
            // No checkpoint: still delay play until after the host can reveal.
            player.pause()
            player.rate = 0
            prerollThenReveal()
            return
        }

        ensurePlayerItemReady()
        let target = checkpoint.time

        seekToCheckpoint(target, generation: generation, attempt: 0) { [weak self] ok in
            guard let self, generation == self.resumeGeneration, self.renderingEnabled else {
                return
            }
            // Stay paused at the seeked frame so the freeze overlay matches.
            self.player.pause()
            self.player.rate = 0
            prerollThenReveal()
            if !ok {
                NSLog(
                    "Wallflow video restore seek was approximate at %.3fs",
                    target.seconds
                )
            }
        }
    }

    private func startPlayback(
        generation: Int,
        baseline: CMTime,
        attempt: Int
    ) {
        guard generation == resumeGeneration, renderingEnabled else { return }
        player.playImmediately(atRate: 1)
        guard attempt < 4 else {
            NSLog(
                "Wallflow video playback did not advance after resume (status=%d)",
                player.timeControlStatus.rawValue
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  generation == self.resumeGeneration,
                  self.renderingEnabled else {
                return
            }
            let current = self.player.currentTime()
            let advanced = current.isValid
                && current.isNumeric
                && baseline.isValid
                && baseline.isNumeric
                && current.seconds > baseline.seconds + 0.03
            if advanced || self.player.timeControlStatus == .playing {
                return
            }
            self.ensurePlayerItemReady()
            self.startPlayback(
                generation: generation,
                baseline: baseline,
                attempt: attempt + 1
            )
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

    private func copyDisplayedFrameImage(
        at time: CMTime,
        preferCheckpointOnly: Bool = false
    ) -> NSImage? {
        if let item = player.currentItem {
            attachVideoOutput(to: item)
        }
        guard let videoOutput else { return nil }
        var displayTime = CMTime.invalid
        let candidates: [CMTime]
        if preferCheckpointOnly {
            candidates = [time]
        } else {
            let hostTime = CACurrentMediaTime()
            let itemTime = videoOutput.itemTime(forHostTime: hostTime)
            candidates = [itemTime, time, player.currentTime()]
        }
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
