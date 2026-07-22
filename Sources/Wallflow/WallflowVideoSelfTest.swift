import AppKit
import AVFoundation
import Foundation

final class WallflowVideoSelfTest {
    private var wallpaperView: VideoWallpaperView?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?

    func run(videoURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        do {
            let project = try WallpaperProjectLoader.load(videoURL)
            let view = VideoWallpaperView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 180),
                project: project,
                playsAudio: false
            )
            wallpaperView = view
            try verifyFitModes(view)
            pollUntilPlaying()

            let timeout = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
                self?.finish(
                    .failure(WallflowSelfTestError.failed("Video playback timed out"))
                )
            }
            RunLoop.main.add(timeout, forMode: .common)
            self.timeout = timeout
        } catch {
            finish(.failure(error))
        }
    }

    private func pollUntilPlaying() {
        guard let view = wallpaperView else { return }
        if view.playbackStatusForTesting == .failed {
            finish(.failure(WallflowSelfTestError.failed("AVPlayer failed to load the video")))
            return
        }
        if view.playbackStatusForTesting == .readyToPlay,
           view.playbackTimeForTesting > 0.1 {
            verifyShortPause()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollUntilPlaying()
        }
    }

    private func verifyFitModes(_ view: VideoWallpaperView) throws {
        view.setFitMode(.automatic)
        guard view.videoGravityForTesting == .resizeAspectFill else {
            throw WallflowSelfTestError.failed("Automatic video fit did not use aspect fill")
        }
        view.setFitMode(.fit)
        guard view.videoGravityForTesting == .resizeAspect else {
            throw WallflowSelfTestError.failed("Video fit mode did not preserve the full frame")
        }
        view.setFitMode(.stretch)
        guard view.videoGravityForTesting == .resize else {
            throw WallflowSelfTestError.failed("Video stretch mode did not resize the frame")
        }
        view.setFitMode(.fill)
        guard view.videoGravityForTesting == .resizeAspectFill else {
            throw WallflowSelfTestError.failed("Video fill mode did not crop to fill")
        }
    }

    private func verifyShortPause() {
        guard let view = wallpaperView else { return }
        view.setRenderingEnabled(false, completion: nil)
        let pausedTime = view.playbackTimeForTesting
        guard let checkpoint = view.checkpointMediaSecondsForTesting,
              abs(checkpoint - pausedTime) < 0.08 else {
            finish(
                .failure(
                    WallflowSelfTestError.failed("Pause did not write a playback checkpoint")
                )
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let view = self.wallpaperView else { return }
            // Source of truth is checkpoint data, not live player time.
            guard let held = view.checkpointMediaSecondsForTesting,
                  abs(held - pausedTime) < 0.08,
                  view.isPlaybackPausedForTesting else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Checkpoint changed while paused"))
                )
                return
            }
            view.setRenderingEnabled(true) { [weak self] in
                guard let self, let view = self.wallpaperView else { return }
                let resumeTime = view.playbackTimeForTesting
                guard resumeTime + 0.05 >= pausedTime,
                      resumeTime <= pausedTime + 0.35 else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Video resumed from a future frame (\(resumeTime) vs \(pausedTime))"
                            )
                        )
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.verifyLongPauseHold()
                }
            }
        }
    }

    /// Long absence: checkpoint data must stay fixed; resume seeks from that data.
    private func verifyLongPauseHold() {
        guard let view = wallpaperView else { return }
        view.setRenderingEnabled(false, completion: nil)
        let pausedTime = view.playbackTimeForTesting
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, let view = self.wallpaperView else { return }
            guard let held = view.checkpointMediaSecondsForTesting,
                  abs(held - pausedTime) < 0.08,
                  view.isPlaybackPausedForTesting else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Checkpoint drifted during long pause"
                        )
                    )
                )
                return
            }
            view.setRenderingEnabled(true) { [weak self] in
                guard let self, let view = self.wallpaperView else { return }
                let resumeTime = view.playbackTimeForTesting
                guard resumeTime + 0.05 >= pausedTime,
                      resumeTime <= pausedTime + 0.4 else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Long-pause resume jumped (\(resumeTime) vs \(pausedTime))"
                            )
                        )
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.verifyResumeAndSnapshot(previousTime: pausedTime)
                }
            }
        }
    }

    private func verifyResumeAndSnapshot(previousTime: TimeInterval) {
        guard let view = wallpaperView,
              view.playbackTimeForTesting > previousTime + 0.1 else {
            finish(.failure(WallflowSelfTestError.failed("Video did not resume")))
            return
        }
        view.setRenderingEnabled(false, completion: nil)
        let secondPause = view.playbackTimeForTesting
        view.captureFrame { [weak self] image in
            guard let self else { return }
            guard let image, image.size.width > 0, image.size.height > 0 else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Video frame capture failed"))
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, let view = self.wallpaperView else { return }
                let drift = abs(view.playbackTimeForTesting - secondPause)
                guard drift < 0.12 else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Video advanced after pause while capturing desktop frame"
                            )
                        )
                    )
                    return
                }
                self.finish(.success(()))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.invalidate()
        timeout = nil
        wallpaperView = nil
        completion(result)
    }
}
