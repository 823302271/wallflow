import AppKit
import Darwin

/// Real run-loop verification without changing the user's wallpaper or windows.
final class WallflowSceneSelfTest {
    private var view: SceneWallpaperView?

    func run(projectURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let project = try WallpaperProjectLoader.load(projectURL)
            guard project.kind == .scene else {
                throw WallflowSelfTestError.failed("Scene self-test requires a scene wallpaper")
            }
            let desktop = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
            let frame = CGRect(origin: .zero, size: desktop.size)
            let view = SceneWallpaperView(frame: frame, desktopFrame: desktop, project: project, playsAudio: false)
            self.view = view
            view.layoutSubtreeIfNeeded()
            view.debugDriveParticles(point: CGPoint(x: frame.midX, y: frame.midY), inDesktop: true, delta: 0.1)
            let liveCPU = Self.cpuSeconds()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let liveTicks = view.debugEffectsTickCount
                let liveSeconds = Self.cpuSeconds() - liveCPU
                guard liveTicks >= 30 else {
                    completion(.failure(WallflowSelfTestError.failed("Scene clock did not run: \(liveTicks) ticks")))
                    return
                }
                view.setRenderingEnabled(false)
                let frozenCount = view.debugParticleCount()
                let pausedCPU = Self.cpuSeconds()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let pausedTicks = view.debugEffectsTickCount - liveTicks
                    let pausedSeconds = Self.cpuSeconds() - pausedCPU
                    guard pausedTicks == 0, !view.debugEffectsTimerIsRunning,
                          view.debugParticleCount() == frozenCount else {
                        completion(.failure(WallflowSelfTestError.failed("Paused scene advanced or lost its particles")))
                        return
                    }
                    view.setRenderingEnabled(true) { view.commitPauseSession() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let resumedTicks = view.debugEffectsTickCount - liveTicks
                        view.setRenderingEnabled(false)
                        guard resumedTicks >= 30 else {
                            completion(.failure(WallflowSelfTestError.failed("Scene failed to restart after pause")))
                            return
                        }
                        print(String(format: "Scene clock: live=%d ticks/2s, paused=%d ticks/2s, resumed=%d ticks/2s; process CPU: live=%.4fs, paused=%.4fs",
                                     liveTicks, pausedTicks, resumedTicks, liveSeconds, pausedSeconds))
                        completion(.success(()))
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
