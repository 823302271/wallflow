import AppKit
import Foundation

final class WallflowExternalWebTest {
    private var wallpaperView: WebWallpaperView?
    private var testWindow: NSWindow?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var firstFrame = ""
    private var firstAnimationClock = 0.0
    private var firstFishX = 0.0
    private var firstFishY = 0.0

    func run(
        projectURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.completion = completion
        do {
            let project = try WallpaperProjectLoader.load(projectURL)
            guard project.kind == .web else {
                throw WallflowSelfTestError.failed("External test project is not a web wallpaper")
            }
            let view = WebWallpaperView(
                frame: CGRect(x: 0, y: 0, width: 640, height: 360),
                desktopFrame: CGRect(x: 0, y: 0, width: 640, height: 360),
                project: project,
                playsAudio: false
            )
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
            view.runtimeReadyHandler = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.captureInitialState()
                }
            }

            let timeout = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
                self?.finish(
                    .failure(WallflowSelfTestError.failed("External web wallpaper timed out"))
                )
            }
            RunLoop.main.add(timeout, forMode: .common)
            self.timeout = timeout
        } catch {
            finish(.failure(error))
        }
    }

    private func captureInitialState() {
        let script = """
        JSON.stringify({
          canvas: Boolean(document.querySelector('canvas')),
          fishCount: typeof config === 'undefined' ? null : config.fishCount,
          koiCount: typeof kois === 'undefined' ? null : kois.length,
          clock: typeof causticTime === 'undefined' ? null : causticTime,
          fishX: typeof kois === 'undefined' || !kois[0] ? null : kois[0].x,
          fishY: typeof kois === 'undefined' || !kois[0] ? null : kois[0].y,
          frame: document.querySelector('canvas')?.toDataURL() || ''
        })
        """
        wallpaperView?.evaluateJavaScriptForTesting(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let state = Self.object(from: value),
                  (state["canvas"] as? NSNumber)?.boolValue == true,
                  (state["fishCount"] as? NSNumber)?.intValue == 15,
                  (state["koiCount"] as? NSNumber)?.intValue == 15,
                  let clock = (state["clock"] as? NSNumber)?.doubleValue,
                  let fishX = (state["fishX"] as? NSNumber)?.doubleValue,
                  let fishY = (state["fishY"] as? NSNumber)?.doubleValue,
                  let frame = state["frame"] as? String,
                  !frame.isEmpty else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Koi wallpaper initial state failed"))
                )
                return
            }
            self.firstFrame = frame
            self.firstAnimationClock = clock
            self.firstFishX = fishX
            self.firstFishY = fishY
            self.applyPropertiesAndInput()
        }
    }

    private func applyPropertiesAndInput() {
        wallpaperView?.applyUserProperties(
            .object([
                "fishCount": .object([
                    "type": .string("slider"),
                    "value": .number(7)
                ])
            ])
        )
        let script = """
        window.__wallflowDispatchMouse('mousemove', 120, 90, 0, 0);
        window.__wallflowDispatchMouse('mousedown', 120, 90, 0, 1);
        window.__wallflowDispatchMouse('mouseup', 120, 90, 0, 0);
        JSON.stringify({
          mouseX: typeof mouse === 'undefined' ? null : mouse.x,
          mouseY: typeof mouse === 'undefined' ? null : mouse.y,
          mouseActive: typeof mouse === 'undefined' ? null : mouse.active,
          foods: typeof foods === 'undefined' ? null : foods.length,
          ripples: typeof ripples === 'undefined' ? null : ripples.length
        })
        """
        wallpaperView?.evaluateJavaScriptForTesting(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let state = Self.object(from: value),
                  (state["mouseX"] as? NSNumber)?.intValue == 120,
                  (state["mouseY"] as? NSNumber)?.intValue == 90,
                  (state["mouseActive"] as? NSNumber)?.boolValue == true,
                  (state["foods"] as? NSNumber)?.intValue ?? 0 > 0,
                  (state["ripples"] as? NSNumber)?.intValue ?? 0 > 0 else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Koi mouse or click input failed"))
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.verifyUpdatedState()
            }
        }
    }

    private func verifyUpdatedState() {
        let script = """
        JSON.stringify({
          fishCount: config.fishCount,
          koiCount: kois.length,
          clock: causticTime,
          fishX: kois[0]?.x,
          fishY: kois[0]?.y,
          frame: document.querySelector('canvas')?.toDataURL() || ''
        })
        """
        wallpaperView?.evaluateJavaScriptForTesting(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            let state = Self.object(from: value)
            let fishCount = (state?["fishCount"] as? NSNumber)?.intValue
            let koiCount = (state?["koiCount"] as? NSNumber)?.intValue
            let clock = (state?["clock"] as? NSNumber)?.doubleValue
            let fishX = (state?["fishX"] as? NSNumber)?.doubleValue
            let fishY = (state?["fishY"] as? NSNumber)?.doubleValue
            let frame = state?["frame"] as? String
            let fishMoved: Bool
            if let fishX, let fishY {
                fishMoved = hypot(fishX - self.firstFishX, fishY - self.firstFishY) > 0.01
            } else {
                fishMoved = false
            }
            guard fishCount == 7,
                  koiCount == 7,
                  clock.map({ $0 > self.firstAnimationClock }) == true,
                  frame?.isEmpty == false,
                  fishMoved else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Koi animation or properties failed: fishCount=\(fishCount?.description ?? "nil"), koiCount=\(koiCount?.description ?? "nil"), clock=\(clock?.description ?? "nil"), fishMoved=\(fishMoved), frameChanged=\(frame != self.firstFrame)"
                        )
                    )
                )
                return
            }
            self.verifyHostPause()
        }
    }

    private func verifyHostPause() {
        wallpaperView?.setRenderingEnabled(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.wallpaperView?.evaluateJavaScriptForTesting("causticTime") {
                [weak self] value, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                guard let pausedClock = (value as? NSNumber)?.doubleValue else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Koi pause clock was unavailable"
                            )
                        )
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.verifyPausedClock(pausedClock)
                }
            }
        }
    }

    private func verifyPausedClock(_ pausedClock: Double) {
        wallpaperView?.evaluateJavaScriptForTesting("causticTime") { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let currentClock = (value as? NSNumber)?.doubleValue,
                  abs(currentClock - pausedClock) < 0.001 else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Koi animation advanced while Wallflow was paused"
                        )
                    )
                )
                return
            }
            self.wallpaperView?.setRenderingEnabled(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.verifyResumedClock(pausedClock)
            }
        }
    }

    private func verifyResumedClock(_ pausedClock: Double) {
        wallpaperView?.evaluateJavaScriptForTesting("causticTime") { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let currentClock = (value as? NSNumber)?.doubleValue,
                  currentClock > pausedClock else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Koi animation did not resume"))
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
        testWindow?.orderOut(nil)
        testWindow = nil
        wallpaperView = nil
        completion(result)
    }

    private static func object(from value: Any?) -> [String: Any]? {
        guard let string = value as? String,
              let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
