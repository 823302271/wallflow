import Foundation

struct SceneGeneral: Equatable {
    let clearColor: [Double]
    let cameraParallax: Bool
    let cameraParallaxAmount: Double
    let cameraParallaxDelay: Double
    let cameraParallaxMouseInfluence: Double
    let canvasWidth: Double
    let canvasHeight: Double
}

struct SceneImageLayer: Equatable {
    let id: Int
    let name: String
    let descriptorPath: String
    let texturePath: String?
    let origin: [Double]
    let scale: [Double]
    let angles: [Double]
    let width: Double
    let height: Double
    let fullscreen: Bool
    let alpha: Double
    let parallaxDepth: Double
}

struct SceneSoundObject: Equatable {
    enum PlaybackMode: String, Equatable {
        case loop
        case random
        case single
    }

    let id: Int
    let name: String
    let paths: [String]
    let playbackMode: PlaybackMode
    let volume: Double
    let startsSilent: Bool
}

struct SceneCompatibilityReport: Equatable {
    let imageObjects: Int
    let particleObjects: Int
    let soundObjects: Int
    let lightObjects: Int
    let unknownObjects: Int
    let imageDescriptors: [String]
}

struct SceneDocument: Equatable {
    let packageVersion: String
    let sceneVersion: Int?
    let general: SceneGeneral
    let compatibility: SceneCompatibilityReport
    let imageLayers: [SceneImageLayer]
    let particleSystems: [SceneParticleSystem]
    let sounds: [SceneSoundObject]

    init(package: ScenePackage) throws {
        let data = try package.data(forPath: "/scene.json")
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let generalJSON = root["general"] as? [String: Any] ?? [:]
        let projection = generalJSON["orthogonalprojection"] as? [String: Any] ?? [:]
        var canvasWidth = Self.double(projection["width"], fallback: 1920)
        var canvasHeight = Self.double(projection["height"], fallback: 1080)

        var imageObjects = 0
        var particleObjects = 0
        var soundObjects = 0
        var lightObjects = 0
        var unknownObjects = 0
        var imageDescriptors: [String] = []
        var parsedImageLayers: [SceneImageLayer] = []
        var parsedParticles: [SceneParticleSystem] = []
        var parsedSounds: [SceneSoundObject] = []

        for case let object as [String: Any] in root["objects"] as? [Any] ?? [] {
            if let image = object["image"] as? String {
                imageObjects += 1
                imageDescriptors.append(image)
                if let imageLayer = Self.parseImageLayer(
                    object,
                    descriptorPath: image,
                    package: package
                ) {
                    parsedImageLayers.append(imageLayer)
                    if (projection["auto"] as? NSNumber)?.boolValue == true {
                        canvasWidth = max(canvasWidth, imageLayer.width)
                        canvasHeight = max(canvasHeight, imageLayer.height)
                    }
                }
            } else if object["particle"] != nil {
                particleObjects += 1
                if let particle = SceneParticleParser.parse(object: object, package: package) {
                    parsedParticles.append(particle)
                }
            } else if object["sound"] != nil {
                soundObjects += 1
                if let sound = Self.parseSoundObject(object) {
                    parsedSounds.append(sound)
                }
            } else if object["light"] != nil {
                lightObjects += 1
            } else {
                unknownObjects += 1
            }
        }

        packageVersion = package.version
        sceneVersion = (root["version"] as? NSNumber)?.intValue
        general = SceneGeneral(
            clearColor: Self.doubleArray(generalJSON["clearcolor"], fallback: [0, 0, 0]),
            cameraParallax: Self.bool(generalJSON["cameraparallax"], fallback: false),
            cameraParallaxAmount: Self.double(
                generalJSON["cameraparallaxamount"],
                fallback: 0.05
            ),
            cameraParallaxDelay: Self.double(
                generalJSON["cameraparallaxdelay"],
                fallback: 0.1
            ),
            cameraParallaxMouseInfluence: Self.double(
                generalJSON["cameraparallaxmouseinfluence"],
                fallback: 1
            ),
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        compatibility = SceneCompatibilityReport(
            imageObjects: imageObjects,
            particleObjects: particleObjects,
            soundObjects: soundObjects,
            lightObjects: lightObjects,
            unknownObjects: unknownObjects,
            imageDescriptors: imageDescriptors
        )
        imageLayers = parsedImageLayers
        particleSystems = parsedParticles
        sounds = parsedSounds
    }

    private static func bool(_ value: Any?, fallback: Bool) -> Bool {
        (value as? NSNumber)?.boolValue ?? fallback
    }

    private static func double(_ value: Any?, fallback: Double) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String,
           let parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return fallback
    }

    /// Wallpaper Engine writes vectors as either JSON arrays or space-separated strings
    /// (`"2560.0 1440.0 0.0"`). Accept both.
    private static func doubleArray(_ value: Any?, fallback: [Double]) -> [Double] {
        if let values = value as? [Any] {
            let result = values.map { double($0, fallback: .nan) }.filter { !$0.isNaN }
            if !result.isEmpty { return result }
        }
        if let string = value as? String {
            let parts = string
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                .compactMap { Double($0) }
            if !parts.isEmpty { return parts }
        }
        return fallback
    }

    private static func parseImageLayer(
        _ object: [String: Any],
        descriptorPath: String,
        package: ScenePackage
    ) -> SceneImageLayer? {
        guard bool(object["visible"], fallback: true) else { return nil }
        guard let descriptor = jsonDictionary(package: package, path: descriptorPath) else {
            return nil
        }

        let objectSize = doubleArray(object["size"], fallback: [])
        let fullscreen = bool(descriptor["fullscreen"], fallback: false)
            || bool(object["fullscreen"], fallback: false)
        let width = double(
            descriptor["width"],
            fallback: objectSize.first ?? 0
        )
        let height = double(
            descriptor["height"],
            fallback: objectSize.dropFirst().first ?? 0
        )

        let texturePath = resolveTexturePath(descriptor: descriptor, package: package)

        return SceneImageLayer(
            id: (object["id"] as? NSNumber)?.intValue ?? 0,
            name: object["name"] as? String ?? descriptorPath,
            descriptorPath: descriptorPath,
            texturePath: texturePath,
            origin: doubleArray(object["origin"], fallback: [960, 540, 0]),
            scale: doubleArray(object["scale"], fallback: [1, 1, 1]),
            angles: doubleArray(object["angles"], fallback: [0, 0, 0]),
            width: max(width, 1),
            height: max(height, 1),
            fullscreen: fullscreen,
            alpha: double(object["alpha"], fallback: 1),
            parallaxDepth: double(
                object["parallaxDepth"] ?? object["parallaxdepth"],
                fallback: 0
            )
        )
    }

    /// Resolve the first non-render-target texture from legacy or passes-based materials.
    private static func resolveTexturePath(
        descriptor: [String: Any],
        package: ScenePackage
    ) -> String? {
        guard let materialPath = descriptor["material"] as? String,
              let material = jsonDictionary(package: package, path: materialPath) else {
            return nil
        }

        let textureNames: [String]
        if let topLevel = material["textures"] as? [Any] {
            textureNames = topLevel.compactMap { $0 as? String }
        } else if let passes = material["passes"] as? [[String: Any]] {
            textureNames = passes.flatMap { pass in
                (pass["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
            }
        } else {
            textureNames = []
        }

        guard let textureName = textureNames.first(where: {
            !$0.isEmpty && !$0.hasPrefix("_rt_")
        }) else {
            return nil
        }

        var path = textureName.replacingOccurrences(of: "\\", with: "/")
        if !path.hasPrefix("materials/") {
            path = "materials/" + path
        }
        if URL(fileURLWithPath: path).pathExtension.isEmpty {
            path += ".tex"
        }
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Prefer the resolved path when the package contains it; otherwise still return
        // it so callers can log a missing texture consistently.
        return normalized
    }

    private static func parseSoundObject(_ object: [String: Any]) -> SceneSoundObject? {
        guard bool(object["visible"], fallback: true),
              let rawPaths = object["sound"] as? [Any] else {
            return nil
        }
        let paths = rawPaths.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }

        let mode = SceneSoundObject.PlaybackMode(
            rawValue: (object["playbackmode"] as? String ?? "loop").lowercased()
        ) ?? .loop
        return SceneSoundObject(
            id: (object["id"] as? NSNumber)?.intValue ?? 0,
            name: object["name"] as? String ?? paths[0],
            paths: paths,
            playbackMode: mode,
            volume: min(max(double(object["volume"], fallback: 1), 0), 1),
            startsSilent: bool(object["startsilent"], fallback: false)
        )
    }

    private static func jsonDictionary(
        package: ScenePackage,
        path: String
    ) -> [String: Any]? {
        guard let data = try? package.data(forPath: path),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return value as? [String: Any]
    }
}
