import AppKit
import Foundation

final class WallflowCanvasMetalSelfTest {
    private var wallpaperView: CanvasMetalWallpaperView?
    private var testWindow: NSWindow?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var pausedTime = 0.0
    private var pausedSubmissionCount = 0

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
        view.setRenderingEnabled(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.verifyResumedState()
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
        finish(.success(()))
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
