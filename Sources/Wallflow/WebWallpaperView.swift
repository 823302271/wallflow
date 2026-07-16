import AppKit
import QuartzCore
import WebKit

final class WebWallpaperView: NSView, WallpaperRenderer, WKNavigationDelegate {
    private static let hostFPS = 24
    private let webView: WKWebView
    private var desktopFrame: CGRect
    private let project: WallpaperProject
    private var playsAudio: Bool
    private var mouseTimer: Timer?
    private var globalMouseMonitor: Any?
    private var lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    private var isRuntimeReady = false
    private var isRenderingEnabled = true
    private var mouseDispatchPending = false
    private var inputPollingFPS = 0
    private var lastPressedMouseButtons = NSEvent.pressedMouseButtons
    private var lastMouseMovementTime = CACurrentMediaTime()
    private var isAudioMuted = false
    private var presentationGeneration = 0
    private var userProperties: JSONValue
    var runtimeReadyHandler: (() -> Void)?
    var inputBridgeActiveForTesting: Bool {
        mouseTimer != nil && globalMouseMonitor != nil
    }

    var contentView: NSView { self }

    init(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        playsAudio: Bool
    ) {
        self.desktopFrame = desktopFrame
        self.project = project
        self.playsAudio = playsAudio
        userProperties = project.userProperties

        let userContentController = WKUserContentController()
        userContentController.addUserScript(
            WKUserScript(
                source: Self.compatibilityBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Self.pageStyleBootstrap,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: frame, configuration: configuration)
        super.init(frame: frame)

        autoresizingMask = [.width, .height]
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .black

        addSubview(webView)
        loadWallpaper()
        startInputBridge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopInputBridge()
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != isRenderingEnabled else { return }
        isRenderingEnabled = enabled
        presentationGeneration += 1
        let generation = presentationGeneration

        if enabled {
            setHostAnimationPaused(false) { [weak self] in
                guard let self,
                      self.isRenderingEnabled,
                      self.presentationGeneration == generation else {
                    return
                }
                self.webView.setAllMediaPlaybackSuspended(false) { [weak self] in
                    guard let self,
                          self.isRenderingEnabled,
                          self.presentationGeneration == generation else {
                        return
                    }
                    self.callPropertyListener("setPaused", argument: "false")
                    self.startInputBridge()
                }
            }
        } else {
            stopInputBridge()
            callPropertyListener("setPaused", argument: "true")
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            setHostAnimationPaused(true)
        }
    }

    func prepareForPresentation() {
        displayIfNeeded()
    }

    func captureFrame(completion: @escaping (NSImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            completion(image.flatMap(WallpaperSnapshot.preparedImage))
        }
    }

    func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        applyAudioMuteState()
    }

    func setPlaysAudio(_ enabled: Bool) {
        playsAudio = enabled
        applyAudioMuteState()
    }

    func updateDesktopFrame(_ frame: CGRect) {
        desktopFrame = frame
        lastMouseLocation = CGPoint(x: -.greatestFiniteMagnitude, y: 0)
    }

    func applyUserProperties(_ properties: JSONValue) {
        guard let changed = properties.objectValue else { return }
        var allProperties = userProperties.objectValue ?? [:]
        for (key, value) in changed {
            allProperties[key] = value
        }
        userProperties = .object(allProperties)
        guard isRuntimeReady else { return }
        callPropertyListener(
            "applyUserProperties",
            argument: Self.javascriptJSON(properties.foundationObject)
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isRuntimeReady = true
        dispatchInitialProperties()
        runtimeReadyHandler?()
    }

    func evaluateJavaScriptForTesting(
        _ script: String,
        completion: @escaping (Any?, Error?) -> Void
    ) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    private func loadWallpaper() {
        guard let entryURL = project.entryURL else {
            return
        }
        if entryURL.isFileURL, let rootURL = project.rootURL {
            webView.loadFileURL(entryURL, allowingReadAccessTo: rootURL)
        } else {
            webView.load(URLRequest(url: entryURL))
        }
    }

    private func dispatchInitialProperties() {
        guard isRuntimeReady else { return }
        let propertiesJSON = Self.javascriptJSON(userProperties.foundationObject)
        webView.evaluateJavaScript(
            "window.__wallflowSetFPS(\(Self.hostFPS));",
            completionHandler: nil
        )
        setHostAnimationPaused(!isRenderingEnabled)
        callPropertyListener("applyUserProperties", argument: propertiesJSON)
        callPropertyListener(
            "applyGeneralProperties",
            argument: "{fps: \(Self.hostFPS)}"
        )
        callPropertyListener("setPaused", argument: isRenderingEnabled ? "false" : "true")
        applyAudioMuteState()
    }

    private func callPropertyListener(_ function: String, argument: String) {
        guard isRuntimeReady else { return }
        let script = """
        (() => {
          const listener = window.wallpaperPropertyListener;
          if (listener && typeof listener.\(function) === 'function') {
            listener.\(function)(\(argument));
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func applyAudioMuteState() {
        guard isRuntimeReady else { return }
        let effectiveMuted = isAudioMuted || !playsAudio
        webView.evaluateJavaScript(
            "window.__wallflowSetMuted(\(effectiveMuted ? "true" : "false"));",
            completionHandler: nil
        )
    }

    private func setHostAnimationPaused(
        _ paused: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard isRuntimeReady else {
            completion?()
            return
        }
        webView.evaluateJavaScript(
            "window.__wallflowSetPaused(\(paused ? "true" : "false"));"
        ) { _, _ in
            completion?()
        }
    }

    private func startInputBridge() {
        guard isRenderingEnabled else { return }
        lastMouseMovementTime = CACurrentMediaTime()
        lastPressedMouseButtons = NSEvent.pressedMouseButtons
        if mouseTimer == nil {
            scheduleMouseTimer(fps: 60)
        }

        if globalMouseMonitor == nil {
            let eventMask: NSEvent.EventTypeMask = [
                .leftMouseDown,
                .leftMouseUp,
                .rightMouseDown,
                .rightMouseUp
            ]
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) {
                [weak self] event in
                DispatchQueue.main.async {
                    self?.handleMonitoredMouseButton(event)
                }
            }
        }
    }

    private func stopInputBridge() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        inputPollingFPS = 0
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func pollMouseLocation() {
        guard isRuntimeReady, !mouseDispatchPending else { return }
        let now = CACurrentMediaTime()
        let global = NSEvent.mouseLocation
        pollMouseButtons(globalLocation: global)
        guard desktopFrame.contains(global) else {
            if now - lastMouseMovementTime > 1.5, inputPollingFPS != 30 {
                scheduleMouseTimer(fps: 30)
            }
            return
        }
        let moved = hypot(
            global.x - lastMouseLocation.x,
            global.y - lastMouseLocation.y
        ) >= 0.25
        guard moved else {
            if now - lastMouseMovementTime > 1.5, inputPollingFPS != 30 {
                scheduleMouseTimer(fps: 30)
            }
            return
        }

        lastMouseMovementTime = now
        if inputPollingFPS != 60 {
            scheduleMouseTimer(fps: 60)
        }
        lastMouseLocation = global
        dispatchMouseEvent(type: "mousemove", globalLocation: global, button: 0, buttons: 0)
    }

    private func handleMonitoredMouseButton(_ event: NSEvent) {
        let button: Int
        let isDown: Bool
        switch event.type {
        case .leftMouseDown:
            button = 0
            isDown = true
        case .leftMouseUp:
            button = 0
            isDown = false
        case .rightMouseDown:
            button = 2
            isDown = true
        case .rightMouseUp:
            button = 2
            isDown = false
        default:
            return
        }
        let mask = button == 0 ? 1 : 2
        let stateAlreadyHandled = (lastPressedMouseButtons & mask != 0) == isDown
        if isDown {
            lastPressedMouseButtons |= mask
        } else {
            lastPressedMouseButtons &= ~mask
        }
        guard !stateAlreadyHandled else { return }

        let global = NSEvent.mouseLocation
        guard desktopFrame.contains(global) else {
            return
        }
        dispatchMouseButtonChange(button: button, isDown: isDown, globalLocation: global)
    }

    private func pollMouseButtons(globalLocation: CGPoint) {
        let current = NSEvent.pressedMouseButtons
        let changed = current ^ lastPressedMouseButtons
        lastPressedMouseButtons = current
        guard changed != 0,
              desktopFrame.contains(globalLocation) else {
            return
        }
        if changed & 1 != 0 {
            dispatchMouseButtonChange(
                button: 0,
                isDown: current & 1 != 0,
                globalLocation: globalLocation
            )
        }
        if changed & 2 != 0 {
            dispatchMouseButtonChange(
                button: 2,
                isDown: current & 2 != 0,
                globalLocation: globalLocation
            )
        }
    }

    private func dispatchMouseButtonChange(
        button: Int,
        isDown: Bool,
        globalLocation: CGPoint
    ) {
        lastMouseMovementTime = CACurrentMediaTime()
        if inputPollingFPS != 60 {
            scheduleMouseTimer(fps: 60)
        }
        dispatchMouseEvent(
            type: isDown ? "mousedown" : "mouseup",
            globalLocation: globalLocation,
            button: button,
            buttons: isDown ? (button == 0 ? 1 : 2) : 0
        )
    }

    private func dispatchMouseEvent(
        type: String,
        globalLocation: CGPoint,
        button: Int,
        buttons: Int
    ) {
        let x = globalLocation.x - desktopFrame.minX
        let y = desktopFrame.maxY - globalLocation.y
        mouseDispatchPending = true
        let script = "window.__wallflowDispatchMouse('\(type)', \(x), \(y), \(button), \(buttons));"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            self?.mouseDispatchPending = false
        }
    }

    private func scheduleMouseTimer(fps: Int) {
        mouseTimer?.invalidate()
        inputPollingFPS = fps
        let interval = 1.0 / Double(fps)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollMouseLocation()
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private static func javascriptJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }

    private static let compatibilityBootstrap = #"""
    (() => {
      const nativeRequestAnimationFrame = window.requestAnimationFrame.bind(window);
      const nativeCancelAnimationFrame = window.cancelAnimationFrame.bind(window);
      let frameInterval = 1000 / 24;
      let lastFrameTime = -Infinity;
      let nextFrameRequestId = 1;
      let nativePumpId = null;
      let timerId = null;
      let isPumping = false;
      let hostPaused = false;
      let virtualFrameTime = null;
      const frameCallbacks = new Map();

      function scheduleAnimationPump() {
        if (hostPaused || nativePumpId !== null || timerId !== null || frameCallbacks.size === 0) return;
        const elapsed = performance.now() - lastFrameTime;
        const delay = Math.max(0, frameInterval - elapsed);
        if (delay <= 1) {
          nativePumpId = nativeRequestAnimationFrame(pumpAnimationFrame);
        } else {
          timerId = setTimeout(() => {
            timerId = null;
            nativePumpId = nativeRequestAnimationFrame(pumpAnimationFrame);
          }, delay);
        }
      }

      function pumpAnimationFrame(timestamp) {
        nativePumpId = null;
        const elapsed = Number.isFinite(lastFrameTime) ? timestamp - lastFrameTime : 0;
        lastFrameTime = timestamp;
        if (virtualFrameTime === null) {
          virtualFrameTime = timestamp;
        } else {
          virtualFrameTime += Math.min(Math.max(elapsed, 0), frameInterval * 2);
        }
        const callbacks = Array.from(frameCallbacks.values());
        frameCallbacks.clear();
        isPumping = true;
        callbacks.forEach(callback => callback(virtualFrameTime));
        isPumping = false;
        scheduleAnimationPump();
      }

      window.requestAnimationFrame = function(callback) {
        const id = nextFrameRequestId++;
        frameCallbacks.set(id, callback);
        if (!isPumping) scheduleAnimationPump();
        return id;
      };
      window.cancelAnimationFrame = function(id) {
        frameCallbacks.delete(id);
        if (frameCallbacks.size === 0) {
          if (nativePumpId !== null) {
            nativeCancelAnimationFrame(nativePumpId);
            nativePumpId = null;
          }
          if (timerId !== null) {
            clearTimeout(timerId);
            timerId = null;
          }
        }
      };
      window.__wallflowSetFPS = function(fps) {
        const value = Number(fps);
        frameInterval = 1000 / Math.min(Math.max(Number.isFinite(value) ? value : 24, 1), 60);
        if (timerId !== null) {
          clearTimeout(timerId);
          timerId = null;
        }
        scheduleAnimationPump();
      };
      window.__wallflowSetPaused = function(paused) {
        hostPaused = Boolean(paused);
        if (hostPaused) {
          if (nativePumpId !== null) {
            nativeCancelAnimationFrame(nativePumpId);
            nativePumpId = null;
          }
          if (timerId !== null) {
            clearTimeout(timerId);
            timerId = null;
          }
        } else {
          lastFrameTime = performance.now();
          scheduleAnimationPump();
        }
      };

      const nativeDevicePixelRatio = window.devicePixelRatio || 1;
      try {
        Object.defineProperty(window, 'devicePixelRatio', {
          configurable: true,
          get: () => Math.min(nativeDevicePixelRatio, 1)
        });
      } catch (_) {}

      window.wallpaperEngineVersion = '2.5.0-wallflow';
      window.wallpaperRegisterAudioListener = function(listener) {
        window.__wallflowAudioListener = listener;
      };
      window.wallpaperRegisterMediaPropertiesListener = function(listener) {
        window.__wallflowMediaPropertiesListener = listener;
      };
      window.wallpaperRegisterMediaPlaybackListener = function(listener) {
        window.__wallflowMediaPlaybackListener = listener;
      };
      window.wallpaperRequestRandomFileForProperty = function(propertyName, callback) {
        if (typeof callback === 'function') callback(propertyName, '');
      };
      window.__wallflowDispatchMouse = function(type, x, y, button, buttons) {
        const options = {
          bubbles: true,
          cancelable: true,
          clientX: x,
          clientY: y,
          screenX: x,
          screenY: y,
          button: button,
          buttons: buttons,
          view: window
        };
        const target = document.elementFromPoint(x, y) || document;
        target.dispatchEvent(new MouseEvent(type, options));
        if (type === 'mouseup' && button === 0) {
          target.dispatchEvent(new MouseEvent('click', options));
        } else if (type === 'mouseup' && button === 2) {
          target.dispatchEvent(new MouseEvent('contextmenu', options));
        }
        if (type === 'mousemove' && typeof PointerEvent !== 'undefined') {
          target.dispatchEvent(new PointerEvent('pointermove', options));
        }
      };
      window.__wallflowMuted = false;
      window.__wallflowSetMuted = function(muted) {
        window.__wallflowMuted = Boolean(muted);
        document.querySelectorAll('audio, video').forEach(element => {
          element.muted = window.__wallflowMuted;
        });
      };
      document.addEventListener('DOMContentLoaded', () => {
        window.__wallflowSetMuted(window.__wallflowMuted);
        new MutationObserver(() => {
          window.__wallflowSetMuted(window.__wallflowMuted);
        }).observe(document.documentElement, { childList: true, subtree: true });
      });
    })();
    """#

    private static let pageStyleBootstrap = #"""
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
        * { -webkit-user-select: none; user-select: none; }
      `;
      document.head.appendChild(style);
      document.addEventListener('dragstart', event => event.preventDefault());
    })();
    """#
}
