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
    private var desktopPressedMouseButtons = 0
    private var lastMouseMovementTime = CACurrentMediaTime()
    private var isAudioMuted = false
    private var presentationGeneration = 0
    private var userProperties: JSONValue
    private var fitMode: WallpaperFitMode
    var runtimeReadyHandler: (() -> Void)?
    var inputBridgeActiveForTesting: Bool {
        mouseTimer != nil && globalMouseMonitor != nil
    }

    var contentView: NSView { self }

    init(
        frame: CGRect,
        desktopFrame: CGRect,
        project: WallpaperProject,
        playsAudio: Bool,
        fitMode: WallpaperFitMode = .automatic
    ) {
        self.desktopFrame = desktopFrame
        self.project = project
        self.playsAudio = playsAudio
        self.fitMode = fitMode
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

    func setRenderingEnabled(_ enabled: Bool, completion: (() -> Void)?) {
        if enabled == isRenderingEnabled {
            if !enabled {
                pinToPauseSession(completion: completion)
            } else {
                completion?()
            }
            return
        }
        isRenderingEnabled = enabled
        presentationGeneration += 1
        let generation = presentationGeneration

        if enabled {
            // Reveal first while still frozen at the pause frame, then unpause.
            // Otherwise rAF / CSS / media advance under the host freeze overlay and
            // the first live frame jumps past the still the user just saw.
            completion?()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isRenderingEnabled,
                      self.presentationGeneration == generation else {
                    return
                }
                self.setHostAnimationPaused(false) { [weak self] in
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
            }
        } else {
            pinToPauseSession(completion: completion)
        }
    }

    func pinToPauseSession(completion: (() -> Void)?) {
        presentationGeneration += 1
        let generation = presentationGeneration
        isRenderingEnabled = false
        stopInputBridge()
        callPropertyListener("setPaused", argument: "true")
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        setHostAnimationPaused(true) { [weak self] in
            guard let self, self.presentationGeneration == generation else {
                return
            }
            completion?()
        }
    }

    func commitPauseSession() {
        guard isRenderingEnabled else { return }
        webView.evaluateJavaScript(
            "window.__wallflowCommitTimeline && window.__wallflowCommitTimeline();",
            completionHandler: nil
        )
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

    func setFitMode(_ fitMode: WallpaperFitMode) {
        guard fitMode != self.fitMode else { return }
        self.fitMode = fitMode
        applyFitMode()
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
        applyFitMode()
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

    private func applyFitMode() {
        guard isRuntimeReady else { return }
        webView.evaluateJavaScript(
            "window.__wallflowSetFitMode('\(fitMode.rawValue)');",
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
            // Idle desktop: 30 Hz location poll is enough; ramp to 60 on motion.
            scheduleMouseTimer(fps: 30)
        }

        if globalMouseMonitor == nil {
            // Only left-click is bridged into the wallpaper. Right-click is left to the
            // system (Finder desktop menu / apps) and must never be obstructed.
            let eventMask: NSEvent.EventTypeMask = [
                .leftMouseDown,
                .leftMouseUp
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
        desktopPressedMouseButtons = 0
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
        let isDown: Bool
        switch event.type {
        case .leftMouseDown:
            isDown = true
        case .leftMouseUp:
            isDown = false
        default:
            return
        }
        let mask = 1
        let stateAlreadyHandled = (lastPressedMouseButtons & mask != 0) == isDown
        if isDown {
            lastPressedMouseButtons |= mask
        } else {
            lastPressedMouseButtons &= ~mask
        }
        guard !stateAlreadyHandled else { return }

        let global = NSEvent.mouseLocation
        let quartz = event.cgEvent?.location
            ?? DesktopVisibility.quartzPoint(fromAppKit: global)
        dispatchDesktopMouseButtonIfNeeded(
            button: 0,
            isDown: isDown,
            globalLocation: global,
            quartzPoint: quartz
        )
    }

    private func pollMouseButtons(globalLocation: CGPoint) {
        // Only track the primary button so secondary/right clicks stay with the system.
        let current = NSEvent.pressedMouseButtons & 1
        let previous = lastPressedMouseButtons & 1
        let changed = current ^ previous
        lastPressedMouseButtons = (lastPressedMouseButtons & ~1) | current
        guard changed != 0 else { return }
        let quartzPoint = CGEvent(source: nil)?.location
            ?? DesktopVisibility.quartzPoint(fromAppKit: globalLocation)
        dispatchDesktopMouseButtonIfNeeded(
            button: 0,
            isDown: current != 0,
            globalLocation: globalLocation,
            quartzPoint: quartzPoint
        )
    }

    private func dispatchDesktopMouseButtonIfNeeded(
        button: Int,
        isDown: Bool,
        globalLocation: CGPoint,
        quartzPoint: CGPoint
    ) {
        let mask = button == 0 ? 1 : 2
        if isDown {
            guard desktopFrame.contains(globalLocation),
                  DesktopVisibility.isDesktopExposed(at: quartzPoint) else {
                return
            }
            desktopPressedMouseButtons |= mask
        } else {
            // Always complete a press that we started, even if the cursor moved
            // slightly off the exposed desktop before mouseup.
            guard desktopPressedMouseButtons & mask != 0 else { return }
            desktopPressedMouseButtons &= ~mask
        }
        dispatchMouseButtonChange(
            button: button,
            isDown: isDown,
            globalLocation: globalLocation
        )
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
        // CSS client coordinates: origin top-left of this display's desktop frame.
        let x = globalLocation.x - desktopFrame.minX
        let y = desktopFrame.maxY - globalLocation.y
        guard x.isFinite, y.isFinite else { return }
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
      // Locked for a pause session so brief false resumes cannot permanently
      // advance the host rAF clock (future-frame jump after Space flaps).
      let sessionVirtualFrameTime = null;
      const frameCallbacks = new Map();
      const hostPausedAnimations = new Set();
      const sessionAnimationTimes = new Map();
      const sessionMediaTimes = new Map();
      let animationSyncScheduled = false;

      function lockMediaElements() {
        document.querySelectorAll('audio, video').forEach(element => {
          try {
            if (!sessionMediaTimes.has(element)) {
              sessionMediaTimes.set(element, element.currentTime);
            } else {
              const locked = sessionMediaTimes.get(element);
              if (Number.isFinite(locked) && Math.abs(element.currentTime - locked) > 0.01) {
                element.currentTime = locked;
              }
            }
          } catch (_) {}
        });
      }

      function restoreMediaElements() {
        sessionMediaTimes.forEach((time, element) => {
          try {
            if (element.isConnected && Number.isFinite(time)) {
              element.currentTime = time;
            }
          } catch (_) {}
        });
      }

      function clearSessionTimelineLocks() {
        sessionVirtualFrameTime = null;
        sessionAnimationTimes.clear();
        sessionMediaTimes.clear();
      }

      function syncDocumentAnimations() {
        animationSyncScheduled = false;
        document.documentElement.toggleAttribute('data-wallflow-host-paused', hostPaused);
        if (typeof document.getAnimations !== 'function') return;
        if (hostPaused) {
          document.getAnimations().forEach(animation => {
            try {
              if (!sessionAnimationTimes.has(animation) && animation.currentTime != null) {
                sessionAnimationTimes.set(animation, animation.currentTime);
              } else if (sessionAnimationTimes.has(animation)) {
                animation.currentTime = sessionAnimationTimes.get(animation);
              }
              if (animation.playState === 'running' || animation.playState === 'paused') {
                animation.pause();
                hostPausedAnimations.add(animation);
              }
            } catch (_) {}
          });
          lockMediaElements();
        } else {
          hostPausedAnimations.forEach(animation => {
            try {
              if (sessionAnimationTimes.has(animation)) {
                animation.currentTime = sessionAnimationTimes.get(animation);
              }
              if (animation.playState === 'paused') animation.play();
            } catch (_) {}
          });
          hostPausedAnimations.clear();
          restoreMediaElements();
        }
      }

      function scheduleDocumentAnimationSync() {
        if (animationSyncScheduled) return;
        animationSyncScheduled = true;
        Promise.resolve().then(syncDocumentAnimations);
      }

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
        scheduleDocumentAnimationSync();
        if (hostPaused) {
          if (sessionVirtualFrameTime === null) {
            sessionVirtualFrameTime = virtualFrameTime;
          } else {
            virtualFrameTime = sessionVirtualFrameTime;
          }
          if (nativePumpId !== null) {
            nativeCancelAnimationFrame(nativePumpId);
            nativePumpId = null;
          }
          if (timerId !== null) {
            clearTimeout(timerId);
            timerId = null;
          }
        } else {
          if (sessionVirtualFrameTime !== null) {
            virtualFrameTime = sessionVirtualFrameTime;
          }
          lastFrameTime = performance.now();
          scheduleAnimationPump();
          // Timeline unlock is host-driven via __wallflowCommitTimeline so a
          // multi-Space hop cannot clear the lock after a brief intermediate play.
        }
      };
      window.__wallflowCommitTimeline = function() {
        clearSessionTimelineLocks();
      };

      document.addEventListener('DOMContentLoaded', () => {
        // While paused, do NOT re-sync on every DOM mutation — that burns CPU
        // under freeze (wallpaper "background" cost higher than foreground).
        new MutationObserver(() => {
          if (!hostPaused) scheduleDocumentAnimationSync();
        }).observe(document.documentElement, {
          attributes: true,
          childList: true,
          subtree: true
        });
        scheduleDocumentAnimationSync();
      });

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
          composed: true,
          clientX: x,
          clientY: y,
          pageX: x,
          pageY: y,
          screenX: x,
          screenY: y,
          button: button,
          buttons: buttons,
          view: window
        };
        // Bubble once from the hit element through document/window. Re-dispatching
        // on ancestors duplicates input and multiplies interactive animation work.
        const target = document.elementFromPoint(x, y) || document.body || document.documentElement || document;
        try { target.dispatchEvent(new MouseEvent(type, options)); } catch (_) {}
        // Left-click only. Right-click / contextmenu stay with macOS (desktop icons).
        if (type === 'mouseup' && button === 0) {
          try { target.dispatchEvent(new MouseEvent('click', options)); } catch (_) {}
        }
        if (typeof PointerEvent !== 'undefined') {
          const pointerType = type === 'mousedown' ? 'pointerdown'
            : type === 'mouseup' ? 'pointerup'
            : type === 'mousemove' ? 'pointermove' : null;
          if (pointerType) {
            const pointerOptions = Object.assign({
              pointerId: 1,
              pointerType: 'mouse',
              isPrimary: true
            }, options);
            try { target.dispatchEvent(new PointerEvent(pointerType, pointerOptions)); } catch (_) {}
          }
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
      const baseStyle = document.createElement('style');
      baseStyle.textContent = `
        html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
        * { -webkit-user-select: none; user-select: none; }
      `;
      document.head.appendChild(baseStyle);

      const fitStyle = document.createElement('style');
      fitStyle.textContent = `
        html[data-wallflow-fit-active="true"] { background: #000 !important; }
        html[data-wallflow-fit-active="true"] body { background-color: #000 !important; }
        html[data-wallflow-host-paused] *,
        html[data-wallflow-host-paused] *::before,
        html[data-wallflow-host-paused] *::after {
          animation-play-state: paused !important;
        }
        [data-wallflow-fit-container="true"] {
          width: 100% !important;
          height: 100% !important;
          min-width: 0 !important;
          min-height: 0 !important;
          max-width: none !important;
          max-height: none !important;
          margin: 0 !important;
        }
        [data-wallflow-fit-target="true"] {
          display: block !important;
          float: none !important;
          width: 100vw !important;
          height: 100vh !important;
          min-width: 0 !important;
          min-height: 0 !important;
          max-width: none !important;
          max-height: none !important;
          object-fit: var(--wallflow-object-fit) !important;
          object-position: center center !important;
        }
        [data-wallflow-fit-background="true"] {
          background-size: var(--wallflow-background-size) !important;
          background-position: center center !important;
          background-repeat: no-repeat !important;
        }
      `;
      document.head.appendChild(fitStyle);

      let fitMode = 'automatic';
      let scheduled = false;

      const isVisible = element => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' &&
          Number(style.opacity || 1) > 0 && rect.width > 1 && rect.height > 1;
      };

      const area = element => {
        const rect = element.getBoundingClientRect();
        return rect.width * rect.height;
      };

      const viewportArea = () => Math.max(1, innerWidth * innerHeight);

      const dominantMedia = includeCanvas => {
        const primary = Array.from(document.querySelectorAll('img, video'))
          .filter(isVisible)
          .filter(element => area(element) >= viewportArea() * 0.15)
          .sort((left, right) => area(right) - area(left))[0] || null;
        if (primary || !includeCanvas) return primary;
        return Array.from(document.querySelectorAll('canvas'))
          .filter(isVisible)
          .filter(element => area(element) >= viewportArea() * 0.15)
          .sort((left, right) => area(right) - area(left))[0] || null;
      };

      const dominantBackground = () => {
        const elements = [document.body, ...document.body.querySelectorAll('*')];
        return elements
          .filter(element => isVisible(element))
          .filter(element => getComputedStyle(element).backgroundImage !== 'none')
          .filter(element => area(element) >= viewportArea() * 0.45)
          .sort((left, right) => area(right) - area(left))[0] || null;
      };

      const isSimpleMediaPage = target => {
        if (!target || area(target) < viewportArea() * 0.45) return false;
        const substantialMedia = Array.from(document.querySelectorAll('img, video'))
          .filter(isVisible)
          .filter(element => area(element) >= viewportArea() * 0.05);
        if (substantialMedia.length !== 1) return false;
        if (document.querySelector('iframe, object, embed, form, input, textarea, select, button')) {
          return false;
        }

        const ancestors = new Set();
        let ancestor = target.parentElement;
        while (ancestor) {
          ancestors.add(ancestor);
          ancestor = ancestor.parentElement;
        }
        return !Array.from(document.body.querySelectorAll('*')).some(element => {
          if (element === target || target.contains(element) || ancestors.has(element)) return false;
          if (!isVisible(element)) return false;
          if (['SCRIPT', 'STYLE', 'LINK', 'AUDIO', 'SOURCE', 'TRACK', 'CANVAS'].includes(element.tagName)) {
            return false;
          }
          if ((element.textContent || '').trim().length > 0) return true;
          const style = getComputedStyle(element);
          return style.backgroundImage !== 'none' && area(element) >= viewportArea() * 0.05;
        });
      };

      const isSimpleBackgroundPage = target => {
        if (!target || area(target) < viewportArea() * 0.8) return false;
        const substantialMedia = Array.from(document.querySelectorAll('img, video, canvas'))
          .filter(isVisible)
          .filter(element => area(element) >= viewportArea() * 0.05);
        const hasVisibleText = [target, ...target.querySelectorAll('*')].some(element => {
          if (!isVisible(element) || ['SCRIPT', 'STYLE'].includes(element.tagName)) return false;
          return Array.from(element.childNodes).some(node =>
            node.nodeType === Node.TEXT_NODE && (node.textContent || '').trim().length > 0
          );
        });
        return substantialMedia.length === 0 && !hasVisibleText &&
          !document.querySelector('iframe, object, embed, form, input, textarea, select, button');
      };

      const clearFitTargets = () => {
        document.documentElement.removeAttribute('data-wallflow-fit-active');
        document.querySelectorAll(
          '[data-wallflow-fit-container], [data-wallflow-fit-target], [data-wallflow-fit-background]'
        ).forEach(element => {
          element.removeAttribute('data-wallflow-fit-container');
          element.removeAttribute('data-wallflow-fit-target');
          element.removeAttribute('data-wallflow-fit-background');
        });
      };

      const markMedia = target => {
        target.setAttribute('data-wallflow-fit-target', 'true');
        let ancestor = target.parentElement;
        while (ancestor) {
          ancestor.setAttribute('data-wallflow-fit-container', 'true');
          ancestor = ancestor.parentElement;
        }
      };

      const applyFitMode = () => {
        clearFitTargets();
        document.documentElement.dataset.wallflowFitMode = fitMode;

        const automatic = fitMode === 'automatic';
        const media = dominantMedia(!automatic);
        const background = dominantBackground();
        const canFitMedia = automatic ? isSimpleMediaPage(media) : Boolean(media);
        const canFitBackground = automatic
          ? !canFitMedia && isSimpleBackgroundPage(background)
          : !canFitMedia && Boolean(background);
        if (!canFitMedia && !canFitBackground) return;

        const objectFit = fitMode === 'fit'
          ? 'contain'
          : fitMode === 'stretch' ? 'fill' : 'cover';
        const backgroundSize = fitMode === 'fit'
          ? 'contain'
          : fitMode === 'stretch' ? '100% 100%' : 'cover';
        document.documentElement.style.setProperty('--wallflow-object-fit', objectFit);
        document.documentElement.style.setProperty('--wallflow-background-size', backgroundSize);
        document.documentElement.setAttribute('data-wallflow-fit-active', 'true');
        if (canFitMedia) {
          markMedia(media);
        } else {
          background.setAttribute('data-wallflow-fit-background', 'true');
        }
      };

      const scheduleFit = () => {
        // While the host freeze overlay is up, do not re-measure / re-apply fit.
        // Space returns fire resize/mutation; re-fitting under the still looks like
        // the wallpaper "re-stretching" when the overlay drops.
        if (document.documentElement.hasAttribute('data-wallflow-host-paused')) return;
        if (scheduled) return;
        scheduled = true;
        setTimeout(() => {
          scheduled = false;
          if (document.documentElement.hasAttribute('data-wallflow-host-paused')) return;
          applyFitMode();
        }, 0);
      };

      window.__wallflowSetFitMode = mode => {
        fitMode = ['automatic', 'fill', 'fit', 'stretch'].includes(mode)
          ? mode
          : 'automatic';
        scheduleFit();
      };
      window.addEventListener('resize', scheduleFit);
      window.addEventListener('load', scheduleFit, true);
      new MutationObserver(scheduleFit).observe(document.body, {
        childList: true,
        subtree: true
      });
      scheduleFit();
      document.addEventListener('dragstart', event => event.preventDefault());
    })();
    """#
}
