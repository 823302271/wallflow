import Foundation

/// Optional Wallpaper Engine built-in assets (e.g. `materials/particle/**`)
/// that workshop packages reference but do not ship.
///
/// Layout under Application Support:
/// ```
/// Wallflow/EngineAssets/
///   materials/
///     particle/          ← copy of WE `assets/materials/particle`
///       nature/
///         rosepetals.tex
/// ```
final class EngineAssetStore {
    static let shared = EngineAssetStore()

    private let fileManager = FileManager.default
    let rootURL: URL

    var particleRootURL: URL {
        rootURL
            .appendingPathComponent("materials", isDirectory: true)
            .appendingPathComponent("particle", isDirectory: true)
    }

    var isParticlePackInstalled: Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: particleRootURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        // Treat as installed when the directory has any content.
        let items = try? fileManager.contentsOfDirectory(
            at: particleRootURL,
            includingPropertiesForKeys: nil
        )
        return (items?.isEmpty == false)
    }

    init(rootURL: URL? = nil) {
        let resolved: URL
        if let rootURL {
            resolved = rootURL
        } else {
            let support = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            resolved = support.appendingPathComponent(
                "Wallflow/EngineAssets",
                isDirectory: true
            )
        }
        self.rootURL = resolved
        try? fileManager.createDirectory(
            at: resolved,
            withIntermediateDirectories: true
        )
    }

    /// Resolve a WE texture hint like `particle/nature/rosepetals` to a local file.
    func resolveTextureFile(hint: String) -> URL? {
        let cleaned = hint
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return nil }

        var candidates: [URL] = []
        // materials/particle/... (WE material path convention)
        if cleaned.hasPrefix("particle/") || cleaned.hasPrefix("materials/") {
            candidates.append(rootURL.appendingPathComponent(cleaned))
            if !cleaned.hasPrefix("materials/") {
                candidates.append(
                    rootURL
                        .appendingPathComponent("materials", isDirectory: true)
                        .appendingPathComponent(cleaned)
                )
            }
        } else {
            candidates.append(
                particleRootURL.appendingPathComponent(cleaned)
            )
            candidates.append(
                rootURL
                    .appendingPathComponent("materials", isDirectory: true)
                    .appendingPathComponent("particle", isDirectory: true)
                    .appendingPathComponent(cleaned)
            )
        }

        let extensions = ["", ".tex", ".png", ".jpg", ".jpeg", ".tga"]
        for base in candidates {
            for ext in extensions {
                let url: URL
                if ext.isEmpty {
                    url = base
                } else if base.pathExtension.isEmpty {
                    url = base.appendingPathExtension(String(ext.dropFirst()))
                } else {
                    continue
                }
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    /// Install a particle pack folder (contents of WE `assets/materials/particle`).
    /// Accepts either the `particle` directory itself or a parent that contains it.
    @discardableResult
    func installParticlePack(from sourceURL: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw EngineAssetError.notADirectory(source.path)
        }

        let particleSource: URL
        if source.lastPathComponent.lowercased() == "particle" {
            particleSource = source
        } else {
            let nested = source.appendingPathComponent("particle", isDirectory: true)
            let materialsNested = source
                .appendingPathComponent("materials", isDirectory: true)
                .appendingPathComponent("particle", isDirectory: true)
            if fileManager.fileExists(atPath: nested.path) {
                particleSource = nested
            } else if fileManager.fileExists(atPath: materialsNested.path) {
                particleSource = materialsNested
            } else {
                // Assume the selected folder *is* the particle pack root.
                particleSource = source
            }
        }

        let destination = particleRootURL
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: particleSource, to: destination)

        // Quick sanity: rosepetals is the most common missing built-in.
        let rose = destination
            .appendingPathComponent("nature", isDirectory: true)
            .appendingPathComponent("rosepetals.tex")
        if !fileManager.fileExists(atPath: rose.path) {
            NSLog(
                "Wallflow engine pack installed but rosepetals.tex was not found at %@",
                rose.path
            )
        }
        return destination
    }

    var statusSummary: String {
        if isParticlePackInstalled {
            return particleRootURL.path
        }
        return ""
    }
}

enum EngineAssetError: LocalizedError {
    case notADirectory(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let path):
            return "Not a folder: \(path)"
        }
    }
}
