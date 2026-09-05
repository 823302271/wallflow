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
        guard !cleaned.isEmpty,
              !cleaned.split(separator: "/").contains("..") else { return nil }

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

    /// Recognize resource-only packs, including ZIP wrapper directories. A project
    /// manifest always takes precedence over a nested materials/particle folder.
    static func locateParticlePack(in root: URL, depth: Int = 0) -> URL? {
        guard depth <= 4 else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent != "__MACOSX" } ?? []
        guard !entries.contains(where: {
            ["project.json", "scene.pkg", "index.html"].contains($0.lastPathComponent.lowercased())
        }) else { return nil }
        if root.lastPathComponent.lowercased() == "particle" || entries.contains(where: { $0.pathExtension.lowercased() == "tex" }) {
            let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let file = files?.nextObject() as? URL {
                if file.pathExtension.lowercased() == "tex",
                   (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return root }
            }
        }
        let directories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard directories.count == 1, let child = directories.first else { return nil }
        return locateParticlePack(in: child, depth: depth + 1)
    }

    /// Stage a complete copy before swapping. A failed copy preserves the installed pack.
    @discardableResult
    func installParticlePack(from sourceURL: URL) throws -> URL {
        guard let source = Self.locateParticlePack(in: sourceURL.standardizedFileURL) else {
            throw EngineAssetError.notADirectory(sourceURL.path)
        }
        let destination = particleRootURL
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { return destination }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".particle-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".particle-backup-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hadPrevious { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? fileManager.removeItem(at: backup) }
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
