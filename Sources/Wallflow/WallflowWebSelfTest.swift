import AppKit
import Foundation

final class WallflowWebSelfTest {
    private var wallpaperView: WebWallpaperView?
    private var temporaryDirectory: URL?
    private var timeout: Timer?
    private var completion: ((Result<Void, Error>) -> Void)?

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
            self.verifyIncrementalPropertiesAndMute()
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
        wallpaperView?.setRenderingEnabled(false)
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
                "window.__wallflowProbe.paused"
            ) { [weak self] value, error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                guard (value as? NSNumber)?.boolValue == true else {
                    self.finish(
                        .failure(WallflowSelfTestError.failed("Web pause callback did not fire"))
                    )
                    return
                }

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
            "window.__wallflowProbe.paused"
        ) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard (value as? NSNumber)?.boolValue == false else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Web resume callback did not fire"))
                )
                return
            }
            self.verifyMouseBridge()
        }
    }

    private func verifyMouseBridge() {
        let script = """
        window.__wallflowDispatchMouse('mousemove', 41, 73, 0, 0);
        JSON.stringify(window.__wallflowProbe.mouse);
        """
        wallpaperView?.evaluateJavaScriptForTesting(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let mouse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (mouse["x"] as? NSNumber)?.intValue == 41,
                  (mouse["y"] as? NSNumber)?.intValue == 73 else {
                self.finish(
                    .failure(WallflowSelfTestError.failed("Web mouse event bridge did not fire"))
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
        <head><meta charset="utf-8"></head>
        <body>
        <audio id="media"></audio>
        <script>
          window.__wallflowProbe = {
            properties: null,
            general: null,
            paused: null,
            mouse: null
          };
          window.wallpaperPropertyListener = {
            applyUserProperties(value) { window.__wallflowProbe.properties = value; },
            applyGeneralProperties(value) { window.__wallflowProbe.general = value; },
            setPaused(value) { window.__wallflowProbe.paused = value; }
          };
          window.addEventListener('mousemove', event => {
            window.__wallflowProbe.mouse = { x: event.clientX, y: event.clientY };
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
