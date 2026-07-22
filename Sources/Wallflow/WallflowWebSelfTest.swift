import AppKit
import Foundation

final class WallflowWebSelfTest {
    private var wallpaperView: WebWallpaperView?
    private var testWindow: NSWindow?
    private var temporaryDirectory: URL?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var pausedAnimationTime = 0.0

    func run(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion

        do {
            let directory = try makeFixture()
            temporaryDirectory = directory
            let project = try WallpaperProjectLoader.load(directory)
            let view = WebWallpaperView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 180),
                desktopFrame: NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 320, height: 180),
                project: project,
                playsAudio: true
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.verifyProperties()
                }
            }

            let timeout = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                self?.finish(.failure(WallflowSelfTestError.failed("WebKit load timed out")))
            }
            RunLoop.main.add(timeout, forMode: .common)
            self.timeout = timeout
        } catch {
            finish(.failure(error))
        }
    }

    private func verifyProperties() {
        wallpaperView?.evaluateJavaScriptForTesting(
            "JSON.stringify(window.__wallflowProbe)"
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let properties = probe["properties"] as? [String: Any],
                  let speed = properties["speed"] as? [String: Any],
                  (speed["value"] as? NSNumber)?.doubleValue == 2,
                  let general = probe["general"] as? [String: Any],
                  (general["fps"] as? NSNumber)?.intValue == 24,
                  (probe["paused"] as? NSNumber)?.boolValue == false else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Web property callbacks were incomplete"))
                )
                return
            }
            self.verifyAutomaticFitMode()
        }
    }

    private func verifyAutomaticFitMode() {
        verifyFitMode(expectedMode: "automatic", expectedObjectFit: "cover") { [weak self] in
            self?.wallpaperView?.setFitMode(.fit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.verifyFitMode(expectedMode: "fit", expectedObjectFit: "contain") {
                    self?.wallpaperView?.setFitMode(.stretch)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.verifyFitMode(expectedMode: "stretch", expectedObjectFit: "fill") {
                            self?.wallpaperView?.setFitMode(.fill)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                                self?.verifyFitMode(
                                    expectedMode: "fill",
                                    expectedObjectFit: "cover"
                                ) {
                                    self?.verifyIncrementalPropertiesAndMute()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func verifyFitMode(
        expectedMode: String,
        expectedObjectFit: String,
        completion: @escaping () -> Void
    ) {
        wallpaperView?.evaluateJavaScriptForTesting(
            "JSON.stringify({ mode: document.documentElement.dataset.wallflowFitMode, fit: getComputedStyle(document.getElementById('hero')).objectFit, target: document.getElementById('hero').dataset.wallflowFitTarget })"
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["mode"] as? String == expectedMode,
                  result["fit"] as? String == expectedObjectFit,
                  result["target"] as? String == "true" else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Web wallpaper fit mode did not apply: \(String(describing: value))"
                        )
                    )
                )
                return
            }
            completion()
        }
    }

    private func verifyIncrementalPropertiesAndMute() {
        wallpaperView?.applyUserProperties(
            .object([
                "speed": .object([
                    "type": .string("slider"),
                    "value": .number(3)
                ])
            ])
        )
        wallpaperView?.setAudioMuted(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.wallpaperView?.evaluateJavaScriptForTesting(
                "JSON.stringify({ properties: window.__wallflowProbe.properties, muted: document.getElementById('media').muted })"
            ) { [weak self] value, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                guard let string = value as? String,
                      let data = string.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let properties = result["properties"] as? [String: Any],
                      let speed = properties["speed"] as? [String: Any],
                      (speed["value"] as? NSNumber)?.doubleValue == 3,
                      (result["muted"] as? NSNumber)?.boolValue == true else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Web incremental properties or audio mute did not apply"
                            )
                        )
                    )
                    return
                }
                self.verifyPauseAndResume()
            }
        }
    }

    private func verifyPauseAndResume() {
        wallpaperView?.evaluateJavaScriptForTesting(
            "document.getElementById('animated').getAnimations()[0].currentTime || 0"
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            self.pausedAnimationTime = (value as? NSNumber)?.doubleValue ?? 0
            self.wallpaperView?.setRenderingEnabled(false)
            self.verifyPausedStateAfterDelay()
        }
    }

    private func verifyPausedStateAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard self?.wallpaperView?.inputBridgeActiveForTesting == false else {
                self?.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Web input bridge remained active while paused"
                        )
                    )
                )
                return
            }
            self?.wallpaperView?.evaluateJavaScriptForTesting(
                "JSON.stringify({ paused: window.__wallflowProbe.paused, animationTime: document.getElementById('animated').getAnimations()[0].currentTime || 0 })"
            ) { [weak self] value, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                guard let string = value as? String,
                      let data = string.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (result["paused"] as? NSNumber)?.boolValue == true,
                      let animationTime = (result["animationTime"] as? NSNumber)?.doubleValue,
                      abs(animationTime - self.pausedAnimationTime) < 50 else {
                    self.finish(
                        .failure(
                            WallflowSelfTestError.failed(
                                "Web pause did not freeze the animation frame: "
                                    + "before=\(self.pausedAnimationTime), result=\(String(describing: value))"
                            )
                        )
                    )
                    return
                }

                self.pausedAnimationTime = animationTime

                self.wallpaperView?.setRenderingEnabled(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard self?.wallpaperView?.inputBridgeActiveForTesting == true else {
                        self?.finish(
                            .failure(
                                WallflowSelfTestError.failed(
                                    "Web input bridge did not resume"
                                )
                            )
                        )
                        return
                    }
                    self?.verifyResumedState()
                }
            }
        }
    }

    private func verifyResumedState() {
        wallpaperView?.evaluateJavaScriptForTesting(
            "JSON.stringify({ paused: window.__wallflowProbe.paused, animationTime: document.getElementById('animated').getAnimations()[0].currentTime || 0 })"
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (result["paused"] as? NSNumber)?.boolValue == false,
                  let animationTime = (result["animationTime"] as? NSNumber)?.doubleValue,
                  animationTime > self.pausedAnimationTime else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Web animation did not resume from the paused frame: "
                                + "paused=\(self.pausedAnimationTime), result=\(String(describing: value))"
                        )
                    )
                )
                return
            }
            self.verifyMouseBridge()
        }
    }

    private func verifyMouseBridge() {
        let script = """
        window.__wallflowDispatchMouse('mousemove', 41, 73, 0, 0);
        window.__wallflowDispatchMouse('mousedown', 41, 73, 0, 1);
        window.__wallflowDispatchMouse('mouseup', 41, 73, 0, 0);
        window.__wallflowDispatchMouse('mousedown', 41, 73, 2, 2);
        window.__wallflowDispatchMouse('mouseup', 41, 73, 2, 0);
        JSON.stringify({ mouse: window.__wallflowProbe.mouse, clicks: window.__wallflowProbe.clicks, contextmenus: window.__wallflowProbe.contextmenus });
        """
        wallpaperView?.evaluateJavaScriptForTesting(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mouse = result["mouse"] as? [String: Any],
                  (mouse["x"] as? NSNumber)?.intValue == 41,
                  (mouse["y"] as? NSNumber)?.intValue == 73,
                  (result["clicks"] as? NSNumber)?.intValue == 2,
                  (result["contextmenus"] as? NSNumber)?.intValue == 1 else {
                self.finish(
                    .failure(
                        WallflowSelfTestError.failed(
                            "Web mouse event bridge did not fire: \(String(describing: value))"
                        )
                    )
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
        testWindow?.orderOut(nil)
        testWindow = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        completion(result)
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallflow-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try """
        {
          "file": "index.html",
          "type": "web",
          "title": "Web Runtime Probe",
          "general": {
            "properties": {
              "speed": { "type": "slider", "value": 2 }
            }
          }
        }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        try """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          @keyframes wallflow-probe { from { opacity: 0.2; } to { opacity: 0.8; } }
          #animated { width: 10px; height: 10px; animation: wallflow-probe 5s linear infinite; }
        </style>
        </head>
        <body>
        <img id="hero" alt="" style="display:block;width:100vw;height:50vh" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
        <canvas id="overlay" style="position:fixed;inset:0;width:100vw;height:100vh;pointer-events:none"></canvas>
        <div id="animated"></div>
        <audio id="media"></audio>
        <script>
          window.__wallflowProbe = {
            properties: null,
            general: null,
            paused: null,
            mouse: null,
            clicks: 0,
            contextmenus: 0
          };
          window.wallpaperPropertyListener = {
            applyUserProperties(value) { window.__wallflowProbe.properties = value; },
            applyGeneralProperties(value) { window.__wallflowProbe.general = value; },
            setPaused(value) { window.__wallflowProbe.paused = value; }
          };
          window.addEventListener('mousemove', event => {
            window.__wallflowProbe.mouse = { x: event.clientX, y: event.clientY };
          });
          window.addEventListener('click', () => {
            window.__wallflowProbe.clicks += 1;
          });
          window.addEventListener('contextmenu', event => {
            event.preventDefault();
            window.__wallflowProbe.contextmenus += 1;
          });
        </script>
        </body>
        </html>
        """.write(
            to: directory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }
}
