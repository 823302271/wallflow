import Foundation
import JavaScriptCore
import simd

struct CanvasMetalProgram {
    let scripts: [String]
    let initialBackground: String
    let hasVignette: Bool
}

enum CanvasMetalProgramLoader {
    private static let unsupportedMarkers = [
        "getContext('webgl", "getContext(\"webgl", "drawImage(",
        "createLinearGradient(", "createRadialGradient(", "createPattern(",
        "getImageData(", "putImageData(", "fillText(", "strokeText(",
        "quadraticCurveTo(", "bezierCurveTo(", "arcTo(", "Path2D",
        "fillRect(", "strokeRect(", "ellipse(", "save(", "restore(",
        "translate(", "rotate(", "transform(", "setTransform(", "clip(",
        "closePath(", "setLineDash(", "measureText(", ".globalAlpha",
        "document.createElement(", "getElementsBy", "querySelector(",
        "setInterval(", "new Image(", "new Audio(", "AudioContext",
        "wallpaperRegisterAudioListener(", "fetch(", "XMLHttpRequest", "WebSocket"
    ]

    static func load(project: WallpaperProject) -> CanvasMetalProgram? {
        guard project.kind == .web,
              let entryURL = project.entryURL,
              entryURL.isFileURL,
              let rootURL = project.rootURL,
              let html = try? String(contentsOf: entryURL, encoding: .utf8),
              !html.localizedCaseInsensitiveContains("<video"),
              !html.localizedCaseInsensitiveContains("<audio"),
              !html.localizedCaseInsensitiveContains("<img") else {
            return nil
        }
        let canvases = matches(pattern: #"(?is)<canvas\b([^>]*)>"#, source: html)
        guard canvases.count == 1,
              let canvasID = firstMatch(
                  pattern: #"(?is)\bid\s*=\s*['\"]([^'\"]+)['\"]"#,
                  source: canvases[0][1]
              )?[1] else {
            return nil
        }

        let scriptMatches = matches(
            pattern: #"(?is)<script\b([^>]*)>(.*?)</script>"#,
            source: html
        )
        var scripts: [String] = []
        for match in scriptMatches {
            let attributes = match[1]
            let inlineSource = match[2]
            if let source = firstMatch(
                pattern: #"(?is)\bsrc\s*=\s*['\"]([^'\"]+)['\"]"#,
                source: attributes
            )?[1] {
                guard let scriptURL = safeResourceURL(
                    source,
                    relativeTo: entryURL,
                    rootURL: rootURL
                ),
                      let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                    return nil
                }
                scripts.append(script)
            } else if !inlineSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scripts.append(inlineSource)
            }
        }
        guard !scripts.isEmpty else { return nil }

        let combinedSource = scripts.joined(separator: "\n")
        guard combinedSource.range(
            of: #"getContext\s*\(\s*['\"]2d['\"]\s*\)"#,
            options: .regularExpression
        ) != nil,
              matches(
                  pattern: #"getElementById\s*\(\s*['\"]([^'\"]+)['\"]\s*\)"#,
                  source: combinedSource
              ).allSatisfy({ $0[1] == canvasID }),
              !unsupportedMarkers.contains(where: combinedSource.contains) else {
            return nil
        }

        let styleSheets = matches(
            pattern: #"(?is)<link\b([^>]*)>"#,
            source: html
        ).compactMap { match -> String? in
            let attributes = match[1]
            guard attributes.localizedCaseInsensitiveContains("stylesheet"),
                  let source = firstMatch(
                      pattern: #"(?is)\bhref\s*=\s*['\"]([^'\"]+)['\"]"#,
                      source: attributes
                  )?[1],
                  let styleURL = safeResourceURL(
                      source,
                      relativeTo: entryURL,
                      rootURL: rootURL
                  ) else {
                return nil
            }
            return try? String(contentsOf: styleURL, encoding: .utf8)
        }
        let css = styleSheets.joined(separator: "\n")
        guard !css.localizedCaseInsensitiveContains("url(") else { return nil }
        let background = firstMatch(
            pattern: #"(?is)body\s*\{[^}]*background(?:-color)?\s*:\s*([^;]+)"#,
            source: css
        )?[1].trimmingCharacters(in: .whitespacesAndNewlines) ?? "#000000"
        let hasVignette = css.localizedCaseInsensitiveContains("radial-gradient")
            && css.localizedCaseInsensitiveContains("rgba(0, 0, 0")

        return CanvasMetalProgram(
            scripts: scripts,
            initialBackground: background,
            hasVignette: hasVignette
        )
    }

    private static func safeResourceURL(
        _ path: String,
        relativeTo entryURL: URL,
        rootURL: URL
    ) -> URL? {
        guard !path.contains("://") else { return nil }
        let resourceURL = entryURL.deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let resourcePath = resourceURL.path
        guard resourcePath == rootPath || resourcePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return resourceURL
    }

    private static func matches(pattern: String, source: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                let matchRange = result.range(at: index)
                guard matchRange.location != NSNotFound,
                      let swiftRange = Range(matchRange, in: source) else {
                    return ""
                }
                return String(source[swiftRange])
            }
        }
    }

    private static func firstMatch(pattern: String, source: String) -> [String]? {
        matches(pattern: pattern, source: source).first
    }
}

struct CanvasMetalFrame {
    static let commandWidth = 20

    let commands: [Float]
    let background: SIMD4<Float>
}

enum CanvasMetalRuntimeError: LocalizedError {
    case unavailable
    case script(String)
    case unsupported(String)
    case malformedCommands

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "JavaScriptCore could not create a Canvas runtime."
        case .script(let message):
            return "Canvas wallpaper JavaScript failed: \(message)"
        case .unsupported(let feature):
            return "Canvas wallpaper uses an unsupported API: \(feature)"
        case .malformedCommands:
            return "Canvas wallpaper produced malformed Metal commands."
        }
    }
}

final class CanvasMetalRuntime {
    private let context: JSContext
    private var exceptionMessage: String?
    private(set) var canvasSize: CGSize

    init(program: CanvasMetalProgram, size: CGSize) throws {
        guard let context = JSContext() else {
            throw CanvasMetalRuntimeError.unavailable
        }
        self.context = context
        canvasSize = size
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            let column = exception?.objectForKeyedSubscript("column")?.toInt32() ?? 0
            self?.exceptionMessage = "\(message) at \(line):\(column)"
        }

        let background = try Self.javascriptLiteral(program.initialBackground)
        let bootstrap = Self.bootstrap(
            width: max(size.width, 1),
            height: max(size.height, 1),
            background: background
        )
        context.evaluateScript(bootstrap)
        try throwIfFailed()
        for script in program.scripts {
            context.evaluateScript(script)
            try throwIfFailed()
        }
    }

    func renderFrame(timeMilliseconds: Double) throws -> CanvasMetalFrame {
        exceptionMessage = nil
        guard let result = context.objectForKeyedSubscript("__wallflowPumpFrame")?
            .call(withArguments: [timeMilliseconds]) else {
            throw CanvasMetalRuntimeError.script("Animation frame function is unavailable.")
        }
        try throwIfFailed()

        let unsupported = result.objectForKeyedSubscript("unsupported")?.toString() ?? ""
        guard unsupported.isEmpty else {
            throw CanvasMetalRuntimeError.unsupported(unsupported)
        }
        let colorValues = result.objectForKeyedSubscript("background")?.toArray() ?? []
        let color = colorValues.compactMap { ($0 as? NSNumber)?.floatValue }
        let background = SIMD4<Float>(
            color.indices.contains(0) ? color[0] : 0,
            color.indices.contains(1) ? color[1] : 0,
            color.indices.contains(2) ? color[2] : 0,
            color.indices.contains(3) ? color[3] : 1
        )
        let commandCount = Int(
            result.objectForKeyedSubscript("commandCount")?.toInt32() ?? 0
        )
        guard commandCount >= 0,
              commandCount.isMultiple(of: CanvasMetalFrame.commandWidth),
              let commandValue = result.objectForKeyedSubscript("commands") else {
            throw CanvasMetalRuntimeError.malformedCommands
        }
        let contextReference = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard JSValueGetTypedArrayType(
            contextReference,
            commandValue.jsValueRef,
            &exception
        ) == kJSTypedArrayTypeFloat32Array,
              let object = JSValueToObject(
                  contextReference,
                  commandValue.jsValueRef,
                  &exception
              ),
              JSObjectGetTypedArrayLength(contextReference, object, &exception) >= commandCount,
              let bytes = JSObjectGetTypedArrayBytesPtr(
                  contextReference,
                  object,
                  &exception
              ) else {
            throw CanvasMetalRuntimeError.malformedCommands
        }
        let source = bytes.assumingMemoryBound(to: Float.self)
        let commands = Array(UnsafeBufferPointer(start: source, count: commandCount))
        return CanvasMetalFrame(commands: commands, background: background)
    }

    func resize(to size: CGSize) throws {
        guard size.width > 0, size.height > 0, size != canvasSize else { return }
        canvasSize = size
        exceptionMessage = nil
        context.objectForKeyedSubscript("__wallflowResize")?.call(
            withArguments: [size.width, size.height]
        )
        try throwIfFailed()
    }

    func dispatchMouse(type: String, x: CGFloat, y: CGFloat) {
        exceptionMessage = nil
        context.objectForKeyedSubscript("__wallflowDispatchMouse")?.call(
            withArguments: [type, x, y]
        )
    }

    func applyUserProperties(_ properties: JSONValue) throws {
        guard let listener = context.objectForKeyedSubscript("wallpaperPropertyListener"),
              !listener.isUndefined,
              let function = listener.objectForKeyedSubscript("applyUserProperties"),
              !function.isUndefined else {
            return
        }
        exceptionMessage = nil
        function.call(withArguments: [properties.foundationObject])
        try throwIfFailed()
    }

    func evaluateForTesting(_ script: String) throws -> Any? {
        exceptionMessage = nil
        let result = context.evaluateScript(script)
        try throwIfFailed()
        return result?.toObject()
    }

    private func throwIfFailed() throws {
        if let exceptionMessage {
            self.exceptionMessage = nil
            throw CanvasMetalRuntimeError.script(exceptionMessage)
        }
    }

    private static func javascriptLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func bootstrap(
        width: CGFloat,
        height: CGFloat,
        background: String
    ) -> String {
        #"""
        (() => {
          globalThis.window = globalThis;
          let virtualNow = 0;
          let canvasWidth = \#(width);
          let canvasHeight = \#(height);
          const commands = new Float32Array(65536);
          let commandCount = 0;
          let unsupported = '';
          let nextFrameID = 1;
          const frameCallbacks = new Map();
          const eventListeners = new Map();

          function markUnsupported(name) {
            if (!unsupported) unsupported = String(name);
          }

          function clamp01(value) {
            return Math.min(Math.max(Number(value) || 0, 0), 1);
          }

          const colorCache = new Map();
          function decodeColor(text) {
            const named = {
              transparent: [0, 0, 0, 0], black: [0, 0, 0, 1],
              white: [1, 1, 1, 1], red: [1, 0, 0, 1]
            };
            if (named[text]) return named[text].slice();
            if (text[0] === '#') {
              const hex = text.slice(1);
              if (hex.length === 3 || hex.length === 4) {
                return [
                  parseInt(hex[0] + hex[0], 16) / 255,
                  parseInt(hex[1] + hex[1], 16) / 255,
                  parseInt(hex[2] + hex[2], 16) / 255,
                  hex.length === 4 ? parseInt(hex[3] + hex[3], 16) / 255 : 1
                ];
              }
              if (hex.length === 6 || hex.length === 8) {
                return [
                  parseInt(hex.slice(0, 2), 16) / 255,
                  parseInt(hex.slice(2, 4), 16) / 255,
                  parseInt(hex.slice(4, 6), 16) / 255,
                  hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1
                ];
              }
            }
            let match = text.match(/^rgba?\(([^)]+)\)$/);
            if (match) {
              const parts = match[1].split(',').map(part => Number(part.trim()));
              return [
                clamp01(parts[0] / 255), clamp01(parts[1] / 255),
                clamp01(parts[2] / 255), parts.length > 3 ? clamp01(parts[3]) : 1
              ];
            }
            match = text.match(/^hsla?\(([^)]+)\)$/);
            if (match) {
              const parts = match[1].split(',');
              const hue = (((Number(parts[0]) || 0) % 360) + 360) % 360 / 360;
              const saturation = clamp01(parseFloat(parts[1]) / 100);
              const lightness = clamp01(parseFloat(parts[2]) / 100);
              const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
              const sector = hue * 6;
              const x = chroma * (1 - Math.abs(sector % 2 - 1));
              let rgb = sector < 1 ? [chroma, x, 0] : sector < 2 ? [x, chroma, 0]
                : sector < 3 ? [0, chroma, x] : sector < 4 ? [0, x, chroma]
                : sector < 5 ? [x, 0, chroma] : [chroma, 0, x];
              const m = lightness - chroma / 2;
              return [rgb[0] + m, rgb[1] + m, rgb[2] + m,
                parts.length > 3 ? clamp01(parts[3]) : 1];
            }
            markUnsupported('color:' + text);
            return [0, 0, 0, 1];
          }

          function parseColor(value) {
            const cached = colorCache.get(value);
            if (cached) return cached;
            const text = String(value || '#000').trim().toLowerCase();
            let color = colorCache.get(text);
            if (!color) {
              color = decodeColor(text);
              colorCache.set(text, color);
            }
            colorCache.set(value, color);
            return color;
          }

          let backgroundColor = parseColor(\#(background));
          const bodyStyle = new Proxy({}, {
            set(target, property, value) {
              if (property === 'backgroundColor' || property === 'background') {
                backgroundColor = parseColor(value);
              } else {
                markUnsupported('document.body.style.' + String(property));
              }
              target[property] = value;
              return true;
            },
            get(target, property) { return target[property] || ''; }
          });

          class CanvasContext2D {
            constructor() {
              this.fillStyle = '#000000';
              this.strokeStyle = '#000000';
              this.lineWidth = 1;
              this.lineCap = 'butt';
              this.lineJoin = 'miter';
              this.shadowBlur = 0;
              this.shadowColor = 'rgba(0,0,0,0)';
              this.shadowOffsetX = 0;
              this.shadowOffsetY = 0;
              this.globalCompositeOperation = 'source-over';
              this.scaleX = 1;
              this.scaleY = 1;
              this.pathKinds = [];
              this.pathX = [];
              this.pathY = [];
              this.pathRadius = [];
              this.pathCount = 0;
            }
            beginPath() { this.pathCount = 0; }
            moveTo(x, y) {
              const index = this.pathCount++;
              this.pathKinds[index] = 0;
              this.pathX[index] = x * this.scaleX;
              this.pathY[index] = y * this.scaleY;
            }
            lineTo(x, y) {
              const index = this.pathCount++;
              this.pathKinds[index] = 0;
              this.pathX[index] = x * this.scaleX;
              this.pathY[index] = y * this.scaleY;
            }
            arc(x, y, radius, start, end, counterclockwise) {
              const fullCircle = Math.abs(Math.abs(end - start) - Math.PI * 2) < 0.01;
              if (!fullCircle || counterclockwise) markUnsupported('CanvasRenderingContext2D.arc(partial)');
              const index = this.pathCount++;
              this.pathKinds[index] = 1;
              this.pathX[index] = x * this.scaleX;
              this.pathY[index] = y * this.scaleY;
              this.pathRadius[index] = radius * (this.scaleX + this.scaleY) * 0.5;
            }
            clearRect() {}
            scale(x, y) { this.scaleX *= Number(x); this.scaleY *= Number(y); }
            emit(kind, ax, ay, bx, by, cx, cy, width, colorValue) {
              const color = parseColor(colorValue);
              const shadow = parseColor(this.shadowColor);
              if (commandCount + 20 > commands.length) {
                markUnsupported('Canvas command buffer capacity');
                return;
              }
              const overlay = this.globalCompositeOperation === 'overlay';
              const offset = commandCount;
              commands[offset] = kind;
              commands[offset + 1] = ax; commands[offset + 2] = ay;
              commands[offset + 3] = bx; commands[offset + 4] = by;
              commands[offset + 5] = cx; commands[offset + 6] = cy;
              commands[offset + 7] = width;
              commands[offset + 8] = color[0]; commands[offset + 9] = color[1];
              commands[offset + 10] = color[2];
              commands[offset + 11] = color[3] * (overlay ? 0.28 : 1);
              commands[offset + 12] = overlay ? 1 : 0;
              commands[offset + 13] = Number(this.shadowBlur) || 0;
              commands[offset + 14] = Number(this.shadowOffsetX) || 0;
              commands[offset + 15] = Number(this.shadowOffsetY) || 0;
              commands[offset + 16] = shadow[0]; commands[offset + 17] = shadow[1];
              commands[offset + 18] = shadow[2]; commands[offset + 19] = shadow[3];
              commandCount += 20;
            }
            fill() {
              if (this.pathCount === 1 && this.pathKinds[0] === 1) {
                this.emit(1, this.pathX[0], this.pathY[0], this.pathRadius[0],
                  0, 0, 0, 0, this.fillStyle);
                return;
              }
              let first = -1;
              let previous = -1;
              for (let index = 0; index < this.pathCount; index++) {
                if (this.pathKinds[index] !== 0) continue;
                if (first < 0) {
                  first = index;
                } else if (previous < 0) {
                  previous = index;
                } else {
                  this.emit(2,
                    this.pathX[first], this.pathY[first],
                    this.pathX[previous], this.pathY[previous],
                    this.pathX[index], this.pathY[index],
                    0, this.fillStyle);
                  previous = index;
                }
              }
            }
            stroke() {
              if (this.pathCount === 1 && this.pathKinds[0] === 1) {
                this.emit(1, this.pathX[0], this.pathY[0], this.pathRadius[0], 0, 0, 0,
                  Number(this.lineWidth) || 1, this.strokeStyle);
                return;
              }
              let previous = -1;
              for (let index = 0; index < this.pathCount; index++) {
                if (this.pathKinds[index] !== 0) continue;
                if (previous >= 0) {
                  this.emit(0,
                    this.pathX[previous], this.pathY[previous],
                    this.pathX[index], this.pathY[index], 0, 0,
                    (Number(this.lineWidth) || 1) * (this.scaleX + this.scaleY) * 0.5,
                    this.strokeStyle);
                }
                previous = index;
              }
            }
          }

          const context2D = new CanvasContext2D();
          const canvas = {
            getContext(type) {
              if (type !== '2d') markUnsupported('canvas.getContext(' + type + ')');
              return context2D;
            },
            get width() { return canvasWidth; },
            set width(value) { canvasWidth = Number(value) || canvasWidth; },
            get height() { return canvasHeight; },
            set height(value) { canvasHeight = Number(value) || canvasHeight; },
            style: {}
          };

          globalThis.document = {
            body: { style: bodyStyle },
            getElementById() { return canvas; },
            addEventListener(type, callback) { addEventListener(type, callback); }
          };
          globalThis.innerWidth = canvasWidth;
          globalThis.innerHeight = canvasHeight;
          globalThis.devicePixelRatio = 1;
          globalThis.performance = { now() { return virtualNow; } };
          globalThis.console = { log() {}, warn() {}, error() {} };
          globalThis.wallpaperEngineVersion = '2.5.0-wallflow-metal';

          globalThis.addEventListener = function(type, callback) {
            if (!eventListeners.has(type)) eventListeners.set(type, []);
            eventListeners.get(type).push(callback);
          };
          globalThis.removeEventListener = function(type, callback) {
            const listeners = eventListeners.get(type) || [];
            const index = listeners.indexOf(callback);
            if (index >= 0) listeners.splice(index, 1);
          };
          globalThis.requestAnimationFrame = function(callback) {
            const id = nextFrameID++;
            frameCallbacks.set(id, callback);
            return id;
          };
          globalThis.cancelAnimationFrame = function(id) { frameCallbacks.delete(id); };
          globalThis.setTimeout = function() { markUnsupported('setTimeout'); return 0; };
          globalThis.clearTimeout = function() {};
          globalThis.wallpaperRegisterAudioListener = function() {};
          globalThis.wallpaperRegisterMediaPropertiesListener = function() {};
          globalThis.wallpaperRegisterMediaPlaybackListener = function() {};

          globalThis.__wallflowDispatchMouse = function(type, x, y) {
            const event = { type, clientX: x, clientY: y, button: 0, buttons: type === 'mousedown' ? 1 : 0 };
            const listeners = (eventListeners.get(type) || []).slice();
            listeners.forEach(listener => listener(event));
          };
          globalThis.__wallflowResize = function(width, height) {
            canvasWidth = Number(width);
            canvasHeight = Number(height);
            globalThis.innerWidth = canvasWidth;
            globalThis.innerHeight = canvasHeight;
            const listeners = (eventListeners.get('resize') || []).slice();
            listeners.forEach(listener => listener({ type: 'resize' }));
          };
          globalThis.__wallflowPumpFrame = function(timestamp) {
            commandCount = 0;
            virtualNow = Number(timestamp);
            const callbacks = Array.from(frameCallbacks.values());
            frameCallbacks.clear();
            callbacks.forEach(callback => callback(virtualNow));
            return { commands, commandCount, background: backgroundColor, unsupported };
          };
        })();
        """#
    }
}
