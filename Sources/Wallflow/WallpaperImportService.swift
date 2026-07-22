import Foundation

enum WallpaperImportError: LocalizedError {
    case invalidURL
    case unsupportedURLScheme(String)
    case workshopURLUnsupported
    case incompleteRemoteProject(String)
    case fileTooLarge(Int64)
    case archiveListingFailed(String)
    case unsafeArchiveEntry(String)
    case archiveExtractionFailed(String)
    case archiveContainsSymbolicLink(String)
    case archiveHasTooManyFiles(Int)
    case extractedProjectTooLarge(Int64)
    case noProjectInArchive
    case multipleProjectsInArchive

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.text(.invalidURL)
        case .unsupportedURLScheme(let scheme):
            return L10n.format(.unsupportedURLScheme, scheme)
        case .workshopURLUnsupported:
            return L10n.text(.workshopURLUnsupported)
        case .incompleteRemoteProject(let extensionName):
            return L10n.format(.incompleteRemoteProject, extensionName)
        case .fileTooLarge(let bytes):
            return L10n.format(.fileTooLarge, Self.size(bytes))
        case .archiveListingFailed(let details):
            return L10n.format(.archiveListingFailed, details)
        case .unsafeArchiveEntry(let path):
            return L10n.format(.unsafeArchiveEntry, path)
        case .archiveExtractionFailed(let details):
            return L10n.format(.archiveExtractionFailed, details)
        case .archiveContainsSymbolicLink(let path):
            return L10n.format(.archiveContainsSymbolicLink, path)
        case .archiveHasTooManyFiles(let count):
            return L10n.format(.archiveHasTooManyFiles, count)
        case .extractedProjectTooLarge(let bytes):
            return L10n.format(.extractedProjectTooLarge, Self.size(bytes))
        case .noProjectInArchive:
            return L10n.text(.noProjectInArchive)
        case .multipleProjectsInArchive:
            return L10n.text(.multipleProjectsInArchive)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

final class WallpaperImportService {
    private let workerQueue = DispatchQueue(
        label: "dev.wallflow.wallpaper-import",
        qos: .userInitiated
    )
    private let importedRootURL: URL
    private let maximumDownloadSize: Int64 = 512 * 1024 * 1024
    private let maximumExtractedSize: Int64 = 1024 * 1024 * 1024
    private let maximumFileCount = 100_000

    init(importedRootURL: URL? = nil) {
        self.importedRootURL = importedRootURL ?? Self.defaultImportedRootURL()
    }

    func prepare(
        sourceURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if sourceURL.isFileURL {
            workerQueue.async { [weak self] in
                guard let self else { return }
                let result = Result {
                    if sourceURL.pathExtension.lowercased() == "zip" {
                        return try self.extractArchive(sourceURL)
                    }
                    return try self.installLocalProject(sourceURL)
                }
                self.finish(completion, with: result)
            }
            return
        }

        guard let scheme = sourceURL.scheme?.lowercased() else {
            completion(.failure(WallpaperImportError.invalidURL))
            return
        }
        guard ["http", "https"].contains(scheme) else {
            completion(.failure(WallpaperImportError.unsupportedURLScheme(scheme)))
            return
        }
        if sourceURL.host?.lowercased().contains("steamcommunity.com") == true {
            completion(.failure(WallpaperImportError.workshopURLUnsupported))
            return
        }

        let extensionName = sourceURL.pathExtension.lowercased()
        if extensionName == "zip" {
            downloadAndExtract(sourceURL, completion: completion)
        } else if ["json", "pkg"].contains(extensionName) {
            completion(.failure(WallpaperImportError.incompleteRemoteProject(extensionName)))
        } else {
            completion(.success(sourceURL))
        }
    }

    private func downloadAndExtract(
        _ sourceURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let error {
                self.finish(completion, with: .failure(error))
                return
            }
            guard let temporaryURL else {
                self.finish(completion, with: .failure(WallpaperImportError.invalidURL))
                return
            }

            do {
                let responseSize = response?.expectedContentLength ?? -1
                let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let measuredSize = max(Int64(fileSize), responseSize)
                guard measuredSize <= self.maximumDownloadSize else {
                    throw WallpaperImportError.fileTooLarge(measuredSize)
                }
                let importedURL = try self.extractArchive(temporaryURL)
                self.finish(completion, with: .success(importedURL))
            } catch {
                self.finish(completion, with: .failure(error))
            }
        }.resume()
    }

    private func extractArchive(_ archiveURL: URL) throws -> URL {
        let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(archiveSize) <= maximumDownloadSize else {
            throw WallpaperImportError.fileTooLarge(Int64(archiveSize))
        }

        let listingData = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path],
            failure: WallpaperImportError.archiveListingFailed
        )
        guard let listing = String(data: listingData, encoding: .utf8) else {
            throw WallpaperImportError.archiveListingFailed("invalid UTF-8 file names")
        }
        for entry in listing.split(whereSeparator: \Character.isNewline) {
            let path = String(entry).replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"),
                  !components.contains(where: { $0 == ".." }) else {
                throw WallpaperImportError.unsafeArchiveEntry(path)
            }
        }
        try validateArchiveSummary(archiveURL)

        let destination = try makeImportDestination()
        var keepDestination = false
        defer {
            if !keepDestination {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        _ = try runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, destination.path],
            failure: WallpaperImportError.archiveExtractionFailed
        )
        try validateExtractedProject(destination)
        let projectURL = try locateProject(in: destination)
        keepDestination = true
        return projectURL
    }

    func installLocalProject(_ sourceURL: URL) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        if Self.contains(sourceURL, in: importedRootURL) {
            return sourceURL
        }

        let project = try WallpaperProjectLoader.load(sourceURL)
        guard let projectSource = localProjectSource(for: project) else {
            throw WallpaperProjectLoaderError.unsupportedSelection(sourceURL)
        }

        let destination = try makeImportDestination()
        var keepDestination = false
        defer {
            if !keepDestination {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: projectSource.path,
            isDirectory: &isDirectory
        ) else {
            throw WallpaperProjectLoaderError.unsupportedSelection(projectSource)
        }
        if isDirectory.boolValue {
            try validateExtractedProject(projectSource)
        } else {
            let fileSize = try projectSource.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
            guard Int64(fileSize) <= maximumExtractedSize else {
                throw WallpaperImportError.extractedProjectTooLarge(Int64(fileSize))
            }
        }

        let installedSource = destination.appendingPathComponent(
            projectSource.lastPathComponent,
            isDirectory: isDirectory.boolValue
        )
        try FileManager.default.copyItem(at: projectSource, to: installedSource)
        try validateExtractedProject(destination)
        let projectURL = try locateProject(in: destination)
        _ = try WallpaperProjectLoader.load(projectURL)
        keepDestination = true
        return projectURL
    }

    private func localProjectSource(for project: WallpaperProject) -> URL? {
        if project.kind == .video, project.manifestURL == nil {
            return project.entryURL
        }
        return project.rootURL
    }

    private func validateExtractedProject(_ rootURL: URL) throws {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw WallpaperImportError.noProjectInArchive
        }

        var fileCount = 0
        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw WallpaperImportError.archiveContainsSymbolicLink(fileURL.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            guard fileCount <= maximumFileCount else {
                throw WallpaperImportError.archiveHasTooManyFiles(fileCount)
            }
            totalSize += Int64(values.fileSize ?? 0)
            guard totalSize <= maximumExtractedSize else {
                throw WallpaperImportError.extractedProjectTooLarge(totalSize)
            }
        }
    }

    private func validateArchiveSummary(_ archiveURL: URL) throws {
        let summaryData = try runProcess(
            executable: "/usr/bin/zipinfo",
            arguments: ["-t", archiveURL.path],
            failure: WallpaperImportError.archiveListingFailed
        )
        guard let summary = String(data: summaryData, encoding: .utf8) else {
            throw WallpaperImportError.archiveListingFailed("invalid archive summary")
        }
        let expression = try NSRegularExpression(
            pattern: #"([0-9]+) files?, ([0-9]+) bytes uncompressed"#
        )
        let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        guard let match = expression.firstMatch(in: summary, range: range),
              let countRange = Range(match.range(at: 1), in: summary),
              let sizeRange = Range(match.range(at: 2), in: summary),
              let fileCount = Int(summary[countRange]),
              let uncompressedSize = Int64(summary[sizeRange]) else {
            throw WallpaperImportError.archiveListingFailed(
                summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard fileCount <= maximumFileCount else {
            throw WallpaperImportError.archiveHasTooManyFiles(fileCount)
        }
        guard uncompressedSize <= maximumExtractedSize else {
            throw WallpaperImportError.extractedProjectTooLarge(uncompressedSize)
        }
    }

    func locateProject(in rootURL: URL) throws -> URL {
        let entryFileNames = ["project.json", "index.html", "scene.pkg"]
        let videoExtensions = ["mp4", "m4v", "mov"]
        for name in entryFileNames {
            let directURL = rootURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: directURL.path) {
                return name == "project.json" ? directURL : rootURL
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WallpaperImportError.noProjectInArchive
        }

        var candidates: [(priority: Int, depth: Int, url: URL)] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent.lowercased()
            let extensionName = fileURL.pathExtension.lowercased()
            let priority: Int
            if let entryPriority = entryFileNames.firstIndex(of: fileName) {
                priority = entryPriority
            } else if videoExtensions.contains(extensionName) {
                priority = entryFileNames.count
            } else {
                continue
            }
            let relative = fileURL.path.dropFirst(rootURL.path.count)
            let depth = relative.split(separator: "/").count
            candidates.append((priority, depth, fileURL))
        }
        guard !candidates.isEmpty else {
            throw WallpaperImportError.noProjectInArchive
        }

        candidates.sort {
            ($0.priority, $0.depth, $0.url.path) < ($1.priority, $1.depth, $1.url.path)
        }
        let best = candidates[0]
        let equallyPreferred = candidates.filter {
            $0.priority == best.priority && $0.depth == best.depth
        }
        guard equallyPreferred.count == 1 else {
            throw WallpaperImportError.multipleProjectsInArchive
        }
        return best.url.lastPathComponent.lowercased() == "project.json"
            || videoExtensions.contains(best.url.pathExtension.lowercased())
            ? best.url
            : best.url.deletingLastPathComponent()
    }

    private func makeImportDestination() throws -> URL {
        try FileManager.default.createDirectory(
            at: importedRootURL,
            withIntermediateDirectories: true
        )
        let destination = importedRootURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        return destination
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

    private static func contains(_ url: URL, in rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        failure: (String) -> WallpaperImportError
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(details?.isEmpty == false ? details! : "exit \(process.terminationStatus)")
        }
        return data
    }

    private func finish(
        _ completion: @escaping (Result<URL, Error>) -> Void,
        with result: Result<URL, Error>
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
