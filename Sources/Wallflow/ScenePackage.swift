import Foundation

struct ScenePackageEntry: Equatable {
    let path: String
    let offset: Int
    let length: Int
}

enum ScenePackageError: LocalizedError, Equatable {
    case truncated
    case invalidStringLength(Int)
    case invalidUTF8
    case invalidVersion(String)
    case invalidEntryCount(Int)
    case invalidPath(String)
    case duplicatePath(String)
    case invalidRange(String)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "The scene package is truncated."
        case .invalidStringLength(let length):
            return "The scene package contains an invalid string length: \(length)."
        case .invalidUTF8:
            return "The scene package contains invalid UTF-8 text."
        case .invalidVersion(let version):
            return "Unsupported scene package header: \(version)."
        case .invalidEntryCount(let count):
            return "The scene package has an invalid entry count: \(count)."
        case .invalidPath(let path):
            return "The scene package contains an unsafe path: \(path)."
        case .duplicatePath(let path):
            return "The scene package contains a duplicate path: \(path)."
        case .invalidRange(let path):
            return "The scene package entry is outside the file: \(path)."
        case .missingEntry(let path):
            return "The scene package does not contain \(path)."
        }
    }
}

final class ScenePackage {
    let version: String
    let entries: [ScenePackageEntry]

    private let data: Data
    private let entriesByPath: [String: ScenePackageEntry]

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        var cursor = BinaryCursor(data: data)
        let version = try cursor.readString(maximumLength: 32)
        guard version.hasPrefix("PKGV"),
              version.count == 8,
              Int(version.dropFirst(4)) != nil else {
            throw ScenePackageError.invalidVersion(version)
        }

        let entryCount = try cursor.readInt32()
        guard (0...100_000).contains(entryCount) else {
            throw ScenePackageError.invalidEntryCount(entryCount)
        }

        struct PendingEntry {
            let path: String
            let relativeOffset: Int
            let length: Int
        }

        var pendingEntries: [PendingEntry] = []
        pendingEntries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let rawPath = try cursor.readString(maximumLength: 4096)
            let path = try Self.normalizePath(rawPath)
            let relativeOffset = try cursor.readInt32()
            let length = try cursor.readInt32()
            guard relativeOffset >= 0, length >= 0 else {
                throw ScenePackageError.invalidRange(path)
            }
            pendingEntries.append(
                PendingEntry(path: path, relativeOffset: relativeOffset, length: length)
            )
        }

        let dataStart = cursor.offset
        var parsedEntries: [ScenePackageEntry] = []
        var byPath: [String: ScenePackageEntry] = [:]
        parsedEntries.reserveCapacity(entryCount)

        for pending in pendingEntries {
            guard pending.relativeOffset <= data.count - dataStart,
                  pending.length <= data.count - dataStart - pending.relativeOffset else {
                throw ScenePackageError.invalidRange(pending.path)
            }
            guard byPath[pending.path] == nil else {
                throw ScenePackageError.duplicatePath(pending.path)
            }

            let entry = ScenePackageEntry(
                path: pending.path,
                offset: dataStart + pending.relativeOffset,
                length: pending.length
            )
            parsedEntries.append(entry)
            byPath[pending.path] = entry
        }

        self.version = version
        entries = parsedEntries
        entriesByPath = byPath
    }

    func contains(_ path: String) -> Bool {
        guard let normalized = try? Self.normalizePath(path) else { return false }
        return entriesByPath[normalized] != nil
    }

    func data(forPath path: String) throws -> Data {
        let normalized = try Self.normalizePath(path)
        guard let entry = entriesByPath[normalized] else {
            throw ScenePackageError.missingEntry(normalized)
        }
        return data.subdata(in: entry.offset..<(entry.offset + entry.length))
    }

    private static func normalizePath(_ path: String) throws -> String {
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)

        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." }) else {
            throw ScenePackageError.invalidPath(path)
        }

        let normalizedComponents = components.filter { $0 != "." }
        guard !normalizedComponents.isEmpty else {
            throw ScenePackageError.invalidPath(path)
        }
        return "/" + normalizedComponents.joined(separator: "/")
    }
}

private struct BinaryCursor {
    let data: Data
    var offset = 0

    mutating func readInt32() throws -> Int {
        guard offset <= data.count - 4 else {
            throw ScenePackageError.truncated
        }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return Int(Int32(bitPattern: value))
    }

    mutating func readString(maximumLength: Int) throws -> String {
        let length = try readInt32()
        guard length >= 0, length <= maximumLength else {
            throw ScenePackageError.invalidStringLength(length)
        }
        guard offset <= data.count - length else {
            throw ScenePackageError.truncated
        }

        let range = offset..<(offset + length)
        offset += length
        guard let value = String(data: data.subdata(in: range), encoding: .utf8) else {
            throw ScenePackageError.invalidUTF8
        }
        return value
    }
}
