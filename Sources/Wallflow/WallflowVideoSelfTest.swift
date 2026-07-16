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
            pollUntilPlaying()

            let timeout = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
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
            verifyPause()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollUntilPlaying()
        }
    }

    private func verifyPause() {
        guard let view = wallpaperView else { return }
        view.setRenderingEnabled(false)
        let pausedTime = view.playbackTimeForTesting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let view = self.wallpaperView else { return }
            let movement = abs(view.playbackTimeForTesting - pausedTime)
            guard movement < 0.08 else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Video continued while paused"))
                )
                return
            }
            view.setRenderingEnabled(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.verifyResumeAndSnapshot(previousTime: pausedTime)
            }
        }
    }

    private func verifyResumeAndSnapshot(previousTime: TimeInterval) {
        guard let view = wallpaperView,
              view.playbackTimeForTesting > previousTime + 0.1 else {
            finish(.failure(WallflowSelfTestError.failed("Video did not resume")))
            return
        }
        view.captureFrame { [weak self] image in
            guard let self else { return }
            guard let image, image.size.width > 0, image.size.height > 0 else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Video frame capture failed"))
                )
                return
            }
            self.finish(.success(()))
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
