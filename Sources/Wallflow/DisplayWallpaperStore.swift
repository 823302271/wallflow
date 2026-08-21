import AppKit
import CoreGraphics
import Foundation

/// Persists which wallpaper each physical display should show.
/// Keys are `CGDirectDisplayID` decimal strings; values are normalized sources
/// (`DisplayWallpaperStore.builtInToken` or a file path / URL string).
final class DisplayWallpaperStore {
    static let builtInToken = "__builtin__"
    private static let defaultsKey = "Wallflow.displayWallpaperAssignments"
    private static let legacyGlobalProjectKey = "Wallflow.selectedProjectPath"

    private let defaults: UserDefaults
    private var assignments: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assignments = Self.load(from: defaults)
        migrateLegacyGlobalAssignmentIfNeeded()
    }

    func source(for displayID: CGDirectDisplayID) -> String? {
        assignments[Self.key(displayID)]
    }

    func isBuiltIn(for displayID: CGDirectDisplayID) -> Bool {
        let source = source(for: displayID)
        return source == nil || source == Self.builtInToken
    }

    func setBuiltIn(for displayID: CGDirectDisplayID) {
        assignments[Self.key(displayID)] = Self.builtInToken
        save()
    }

    func setSource(_ source: String, for displayID: CGDirectDisplayID) {
        assignments[Self.key(displayID)] = source
        save()
    }

    func setSource(_ source: String, for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            assignments[Self.key(displayID)] = source
        }
        save()
    }

    func setBuiltIn(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            assignments[Self.key(displayID)] = Self.builtInToken
        }
        save()
    }

    /// Repoint every display using an old external path to its managed copy.
    @discardableResult
    func replaceSource(
        _ oldSource: String,
        with newSource: String
    ) -> [CGDirectDisplayID] {
        var changedDisplayIDs: [CGDirectDisplayID] = []
        for (key, source) in assignments where source == oldSource {
            guard let id = UInt32(key) else { continue }
            assignments[key] = newSource
            changedDisplayIDs.append(CGDirectDisplayID(id))
        }
        if !changedDisplayIDs.isEmpty {
            save()
        }
        return changedDisplayIDs
    }

    /// All display IDs currently assigned to the given source (or built-in).
    func displayIDs(usingSource source: String?) -> [CGDirectDisplayID] {
        let token = source ?? Self.builtInToken
        return assignments.compactMap { key, value -> CGDirectDisplayID? in
            guard value == token, let id = UInt32(key) else { return nil }
            return CGDirectDisplayID(id)
        }
    }

    func displayIDsUsingBuiltIn() -> [CGDirectDisplayID] {
        displayIDs(usingSource: Self.builtInToken)
            + assignments.compactMap { key, value -> CGDirectDisplayID? in
                // Treat missing as built-in only for currently attached screens via caller.
                _ = value
                return nil
            }
    }

    private func migrateLegacyGlobalAssignmentIfNeeded() {
        guard assignments.isEmpty,
              let legacy = defaults.string(forKey: Self.legacyGlobalProjectKey),
              !legacy.isEmpty else {
            return
        }
        // Seed every currently attached display with the previous single wallpaper.
        for screen in NSScreen.screens {
            let displayID = DesktopWindowController.displayID(for: screen)
            assignments[Self.key(displayID)] = legacy
        }
        save()
    }

    private func save() {
        defaults.set(assignments, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func key(_ displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}

enum DisplayWallpaperTarget: Equatable {
    case all
    case display(CGDirectDisplayID)

    var displayID: CGDirectDisplayID? {
        if case .display(let id) = self { return id }
        return nil
    }
}
