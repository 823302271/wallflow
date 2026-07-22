import Foundation

struct WallpaperLibraryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var source: String
    var title: String
    var kind: String
    var addedAt: Date
    var fitMode: WallpaperFitMode

    init(
        id: UUID,
        source: String,
        title: String,
        kind: String,
        addedAt: Date,
        fitMode: WallpaperFitMode = .automatic
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.kind = kind
        self.addedAt = addedAt
        self.fitMode = fitMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case title
        case kind
        case addedAt
        case fitMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        fitMode = try container.decodeIfPresent(
            WallpaperFitMode.self,
            forKey: .fitMode
        ) ?? .automatic
    }

    var sourceURL: URL {
        if let url = URL(string: source),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return url
        }
        return URL(fileURLWithPath: source)
    }

    var isAvailable: Bool {
        !sourceURL.isFileURL || FileManager.default.fileExists(atPath: sourceURL.path)
    }
}

final class WallpaperLibrary {
    private static let defaultsKey = "Wallflow.wallpaperLibrary"

    private let defaults: UserDefaults
    private let importedRootURL: URL
    private let importService = WallpaperImportService()
    private(set) var entries: [WallpaperLibraryEntry]

    init(
        defaults: UserDefaults = .standard,
        importedRootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.importedRootURL = importedRootURL ?? Self.defaultImportedRootURL()
        entries = Self.loadEntries(from: defaults)
        discoverManagedWallpapers()
    }

    @discardableResult
    func install(project: WallpaperProject, sourceURL: URL) -> WallpaperLibraryEntry {
        let normalizedSource = Self.normalizedSource(sourceURL)
        if let index = entries.firstIndex(where: { $0.source == normalizedSource }) {
            entries[index].title = project.displayTitle
            entries[index].kind = project.kind.rawValue
            save()
            return entries[index]
        }

        let entry = WallpaperLibraryEntry(
            id: UUID(),
            source: normalizedSource,
            title: project.displayTitle,
            kind: project.kind.rawValue,
            addedAt: Date(),
            fitMode: .automatic
        )
        entries.append(entry)
        sortEntries()
        save()
        return entry
    }

    func remove(_ entry: WallpaperLibraryEntry, deleteManagedFiles: Bool) throws {
        if deleteManagedFiles, let installRoot = managedInstallRoot(for: entry.sourceURL) {
            try FileManager.default.removeItem(at: installRoot)
        }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func isManaged(_ entry: WallpaperLibraryEntry) -> Bool {
        managedInstallRoot(for: entry.sourceURL) != nil
    }

    func entry(for project: WallpaperProject) -> WallpaperLibraryEntry? {
        guard let sourceURL = project.manifestURL ?? project.entryURL ?? project.rootURL else {
            return nil
        }
        let source = Self.normalizedSource(sourceURL)
        return entries.first { $0.source == source }
    }

    @discardableResult
    func setFitMode(_ fitMode: WallpaperFitMode, for project: WallpaperProject) -> Bool {
        guard let sourceURL = project.manifestURL ?? project.entryURL ?? project.rootURL else {
            return false
        }
        let source = Self.normalizedSource(sourceURL)
        guard let index = entries.firstIndex(where: { $0.source == source }) else {
            return false
        }
        entries[index].fitMode = fitMode
        save()
        return true
    }

    private func discoverManagedWallpapers() {
        guard let installRoots = try? FileManager.default.contentsOfDirectory(
            at: importedRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for installRoot in installRoots.sorted(by: { $0.path < $1.path }) {
            guard let sourceURL = try? importService.locateProject(in: installRoot),
                  let project = try? WallpaperProjectLoader.load(sourceURL) else {
                continue
            }
            let canonicalSource = project.manifestURL ?? project.entryURL ?? sourceURL
            install(project: project, sourceURL: canonicalSource)
        }
    }

    private func managedInstallRoot(for sourceURL: URL) -> URL? {
        guard sourceURL.isFileURL else { return nil }
        let root = importedRootURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        let rootPath = root.path
        let sourcePath = source.path
        guard sourcePath.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = sourcePath.dropFirst(rootPath.count + 1)
        guard let firstComponent = relativePath.split(separator: "/").first else {
            return nil
        }
        return root.appendingPathComponent(String(firstComponent), isDirectory: true)
    }

    private func sortEntries() {
        entries.sort {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder == .orderedSame { return $0.addedAt < $1.addedAt }
            return titleOrder == .orderedAscending
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadEntries(from defaults: UserDefaults) -> [WallpaperLibraryEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode(
                  [WallpaperLibraryEntry].self,
                  from: data
              ) else {
            return []
        }
        return entries
    }

    private static func normalizedSource(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private static func defaultImportedRootURL() -> URL {
        let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (applicationSupport ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Wallflow/ImportedWallpapers", isDirectory: true)
    }
}
