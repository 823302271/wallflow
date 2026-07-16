import Foundation

struct WallpaperManifest: Codable, Equatable {
    let file: String
    let type: String
    let title: String?
    let preview: String?
    let general: JSONValue?
}

struct WallpaperProject: Equatable {
    enum Kind: String, Equatable {
        case builtIn
        case web
        case scene
    }

    let kind: Kind
    let rootURL: URL?
    let entryURL: URL?
    let manifestURL: URL?
    let manifest: WallpaperManifest?
    let displayTitle: String

    static let builtIn = WallpaperProject(
        kind: .builtIn,
        rootURL: nil,
        entryURL: nil,
        manifestURL: nil,
        manifest: nil,
        displayTitle: "Wallflow Native Scene"
    )

    var userProperties: JSONValue {
        guard let general = manifest?.general?.objectValue,
              let properties = general["properties"] else {
            return .object([:])
        }
        return properties
    }
}

enum WallpaperProjectLoaderError: LocalizedError {
    case unsupportedSelection(URL)
    case malformedManifest(URL, Error)
    case unsupportedType(String)
    case missingEntry(URL)
    case entryOutsideProject(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection(let url):
            return "No supported Wallpaper Engine project was found at \(url.path)."
        case .malformedManifest(let url, let error):
            return "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        case .unsupportedType(let type):
            return "Wallpaper type '\(type)' is not supported yet."
        case .missingEntry(let url):
            return "Wallpaper entry file is missing: \(url.path)"
        case .entryOutsideProject(let url):
            return "Wallpaper entry is outside its project directory: \(url.path)"
        }
    }
}

enum WallpaperProjectLoader {
    static func load(_ selectedURL: URL) throws -> WallpaperProject {
        let url = selectedURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WallpaperProjectLoaderError.unsupportedSelection(url)
        }

        if isDirectory.boolValue {
            return try loadDirectory(url)
        }

        switch url.lastPathComponent.lowercased() {
        case "project.json":
            return try loadManifest(url)
        case "scene.pkg":
            let manifestURL = url.deletingLastPathComponent().appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return try loadManifest(manifestURL)
            }
            return WallpaperProject(
                kind: .scene,
                rootURL: url.deletingLastPathComponent(),
                entryURL: url,
                manifestURL: nil,
                manifest: nil,
                displayTitle: url.deletingLastPathComponent().lastPathComponent
            )
        default:
            if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                return WallpaperProject(
                    kind: .web,
                    rootURL: url.deletingLastPathComponent(),
                    entryURL: url,
                    manifestURL: nil,
                    manifest: nil,
                    displayTitle: url.deletingPathExtension().lastPathComponent
                )
            }
            throw WallpaperProjectLoaderError.unsupportedSelection(url)
        }
    }

    private static func loadDirectory(_ directory: URL) throws -> WallpaperProject {
        let manifestURL = directory.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try loadManifest(manifestURL)
        }

        let htmlURL = directory.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: htmlURL.path) {
            return try load(htmlURL)
        }

        let sceneURL = directory.appendingPathComponent("scene.pkg")
        if FileManager.default.fileExists(atPath: sceneURL.path) {
            return try load(sceneURL)
        }

        throw WallpaperProjectLoaderError.unsupportedSelection(directory)
    }

    private static func loadManifest(_ manifestURL: URL) throws -> WallpaperProject {
        let manifest: WallpaperManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(WallpaperManifest.self, from: data)
        } catch {
            throw WallpaperProjectLoaderError.malformedManifest(manifestURL, error)
        }

        let kind: WallpaperProject.Kind
        switch manifest.type.lowercased() {
        case "web":
            kind = .web
        case "scene":
            kind = .scene
        default:
            throw WallpaperProjectLoaderError.unsupportedType(manifest.type)
        }

        let rootURL = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let relativePath = manifest.file.replacingOccurrences(of: "\\", with: "/")
        let entryURL = rootURL.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        let rootPath = rootURL.standardizedFileURL.path
        let entryPath = entryURL.standardizedFileURL.path
        guard entryPath == rootPath || entryPath.hasPrefix(rootPath + "/") else {
            throw WallpaperProjectLoaderError.entryOutsideProject(entryURL)
        }
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw WallpaperProjectLoaderError.missingEntry(entryURL)
        }

        return WallpaperProject(
            kind: kind,
            rootURL: rootURL,
            entryURL: entryURL,
            manifestURL: manifestURL,
            manifest: manifest,
            displayTitle: manifest.title ?? rootURL.lastPathComponent
        )
    }
}
