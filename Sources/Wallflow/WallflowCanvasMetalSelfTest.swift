import AppKit
import Foundation

final class WallflowCanvasMetalSelfTest {
    private var wallpaperView: CanvasMetalWallpaperView?
    private var testWindow: NSWindow?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var pausedTime = 0.0
    private var pausedSubmissionCount = 0
    private var pausedKoiPosition = CGPoint.zero
    private var didCompleteSuppressedResume = false

    func run(
        projectURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.completion = completion
        do {
            let project = try WallpaperProjectLoader.load(projectURL)
            guard let view = CanvasMetalWallpaperView.makeIfSupported(
                frame: CGRect(x: 0, y: 0, width: 640, height: 360),
                desktopFrame: CGRect(x: 0, y: 0, width: 640, height: 360),
                project: project
            ) else {
                throw WallflowSelfTestError.failed(
                    "Koi wallpaper did not select the Canvas Metal renderer"
                )
            }
            wallpaperView = view
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.level = .floating
            window.orderFrontRegardless()
            testWindow = window

            let timeout = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
                self?.finish(
                    .failure(WallflowSelfTestError.failed("Canvas Metal test timed out"))
                )
            }
            RunLoop.main.add(timeout, forMode: .common)
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.verifyInitialState()
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func verifyInitialState() {
        do {
            guard let view = wallpaperView,
                  view.schedulerActiveForTesting,
                  view.commandCountForTesting > 100,
                  view.drawableSize == view.convertToBacking(view.bounds).size,
                  try integer(from: view.evaluateJavaScriptForTesting("config.fishCount")) == 15,
                  try integer(from: view.evaluateJavaScriptForTesting("kois.length")) == 15 else {
                throw WallflowSelfTestError.failed("Canvas Metal initial state failed")
            }

            view.applyUserProperties(
                .object([
                    "fishCount": .object([
                        "type": .string("slider"),
                        "value": .number(7)
                    ])
                ])
            )
            view.dispatchMouseForTesting(type: "mousemove", x: 120, y: 90)
            view.dispatchMouseForTesting(type: "click", x: 120, y: 90)
            // Right-click is intentionally not bridged (system desktop menu ownership).
            // Left-click still drives interactive canvas input (e.g. ripples).
            let rippleCount = try integer(
                from: view.evaluateJavaScriptForTesting("ripples.length")
            )
            guard rippleCount > 0 else {
                throw WallflowSelfTestError.failed("Canvas Metal left click did not create ripples")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.verifyPropertiesAndInput()
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func verifyPropertiesAndInput() {
        do {
            guard let view = wallpaperView else {
                throw WallflowSelfTestError.failed("Canvas Metal view was released")
            }
            let configuredCount = try integer(
                from: view.evaluateJavaScriptForTesting("config.fishCount")
            )
            let koiCount = try integer(
                from: view.evaluateJavaScriptForTesting("kois.length")
            )
            let rippleCount = try integer(
                from: view.evaluateJavaScriptForTesting("ripples.length")
            )
            guard configuredCount == 7,
                  koiCount == 7,
                  rippleCount > 0 else {
                throw WallflowSelfTestError.failed(
                    "Canvas Metal state was config=\(configuredCount), koi=\(koiCount), "
                        + "ripple=\(rippleCount)"
                )
            }
            var completedSynchronously = false
            view.captureFrame { [weak self, weak view] image in
                guard let self, let view else { return }
                do {
                    guard completedSynchronously else {
                        throw WallflowSelfTestError.failed(
                            "Canvas Metal snapshot blocked the main thread"
                        )
                    }
                    try self.verifySnapshot(image, view: view)
                    view.setRenderingEnabled(false)
                    self.pausedTime = view.virtualTimeForTesting
                    self.pausedSubmissionCount = view.renderSubmissionCountForTesting
                    self.pausedKoiPosition = try self.koiPosition(from: view)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.verifyPausedState()
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
            completedSynchronously = true
        } catch {
            finish(.failure(error))
        }
    }

    private func verifySnapshot(
        _ image: NSImage?,
        view: CanvasMetalWallpaperView
    ) throws {
        guard let image else {
            throw WallflowSelfTestError.failed("Canvas Metal snapshot was missing")
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        ), cgImage.width == Int(view.drawableSize.width.rounded()),
           cgImage.height == Int(view.drawableSize.height.rounded()),
           let data = cgImage.dataProvider?.data as Data? else {
            throw WallflowSelfTestError.failed(
                "Canvas Metal snapshot did not preserve the drawable"
            )
        }
        let containsVisibleColor = data.withUnsafeBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)
            guard pixels.count >= 4 else { return false }
            let stride = max(4, (pixels.count / 2048 / 4) * 4)
            for offset in Swift.stride(from: 0, to: pixels.count - 3, by: stride) {
                if pixels[offset] > 2 || pixels[offset + 1] > 2 || pixels[offset + 2] > 2 {
                    return true
                }
            }
            return false
        }
        guard containsVisibleColor else {
            throw WallflowSelfTestError.failed("Canvas Metal snapshot was black")
        }
    }

    private func verifyPausedState() {
        guard let view = wallpaperView,
              !view.schedulerActiveForTesting,
              view.virtualTimeForTesting == pausedTime,
              view.renderSubmissionCountForTesting == pausedSubmissionCount else {
            finish(
                .failure(
                    WallflowSelfTestError.failed(
                        "Canvas Metal pause did not stop time and GPU submissions"
                    )
                )
            )
            return
        }
        // Model the switching primary display temporarily having no presentable
        // drawable. The old 0.4-second fallback revealed a stale surface here.
        view.suppressPresentationForTesting = true
        didCompleteSuppressedResume = false
        view.setRenderingEnabled(true) { [weak self, weak view] in
            guard let self, let view else { return }
            self.didCompleteSuppressedResume = true
            do {
                let revealPosition = try self.koiPosition(from: view)
                guard view.virtualTimeForTesting == self.pausedTime,
                      hypot(
                        revealPosition.x - self.pausedKoiPosition.x,
                        revealPosition.y - self.pausedKoiPosition.y
                      ) < 0.000_001 else {
                    throw WallflowSelfTestError.failed(
                        "Canvas Metal advanced before the paused frame was revealed"
                    )
                }
                // Match DesktopWindowController's reveal boundary.
                view.commitPauseSession()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.verifyResumedState()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self, weak view] in
            guard let self, let view else { return }
            guard !self.didCompleteSuppressedResume else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Canvas Metal revealed before a drawable was presented"
                        )
                    )
                )
                return
            }
            view.suppressPresentationForTesting = false
            view.draw()
        }
    }

    private func verifyResumedState() {
        guard let view = wallpaperView,
              view.schedulerActiveForTesting,
              view.virtualTimeForTesting > pausedTime,
              view.virtualTimeForTesting - pausedTime < 400 else {
            finish(
                .failure(
                    WallflowSelfTestError.failed(
                        "Canvas Metal resume jumped to a future frame"
                    )
                )
            )
            return
        }
        let secondPausedTime = view.virtualTimeForTesting
        view.setRenderingEnabled(false)
        guard view.virtualTimeForTesting == secondPausedTime,
              secondPausedTime > pausedTime else {
            finish(
                .failure(
                    WallflowSelfTestError.failed(
                        "Canvas Metal reused the previous Space checkpoint"
                    )
                )
            )
            return
        }
        view.setRenderingEnabled(true) { [weak self, weak view] in
            guard let self, let view else { return }
            guard view.virtualTimeForTesting == secondPausedTime else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Canvas Metal second reveal skipped its paused frame"
                        )
                    )
                )
                return
            }
            // Still inside the pause session: the host has not committed. A Space
            // hop landing here must snap the timeline back AND repaint, otherwise
            // the still captured for the freeze shows a frame nobody saw.
            self.verifySpaceHopSnapsBack(to: secondPausedTime)
        }
    }

    private func verifySpaceHopSnapsBack(to lockedTime: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak view = wallpaperView] in
            guard let self, let view else { return }
            guard view.virtualTimeForTesting > lockedTime else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Canvas Metal did not resume after its second reveal"
                        )
                    )
                )
                return
            }
            let advancedSubmissionCount = view.renderSubmissionCountForTesting
            view.pinToPauseSession(completion: nil)
            guard view.virtualTimeForTesting == lockedTime,
                  view.renderSubmissionCountForTesting > advancedSubmissionCount else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Canvas Metal Space re-pin did not repaint the locked frame"
                        )
                    )
                )
                return
            }
            view.setRenderingEnabled(true) { [weak self, weak view] in
                guard let self, let view else { return }
                view.commitPauseSession()
                self.finish(.success(()))
            }
        }
    }

    private func koiPosition(from view: CanvasMetalWallpaperView) throws -> CGPoint {
        guard let x = try view.evaluateJavaScriptForTesting("kois[0].x") as? NSNumber,
              let y = try view.evaluateJavaScriptForTesting("kois[0].y") as? NSNumber else {
            throw WallflowSelfTestError.failed("Canvas Metal koi position probe failed")
        }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    private func integer(from value: Any?) throws -> Int {
        guard let number = value as? NSNumber else {
            throw WallflowSelfTestError.failed("Canvas Metal JavaScript probe failed")
        }
        return number.intValue
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.invalidate()
        timeout = nil
        wallpaperView?.setRenderingEnabled(false)
        wallpaperView = nil
        testWindow?.orderOut(nil)
        testWindow = nil
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}
