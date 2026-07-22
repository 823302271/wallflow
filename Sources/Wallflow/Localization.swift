import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let defaultsKey = "Wallflow.language"

    static var current: AppLanguage {
        get {
            if let saved = UserDefaults.standard.string(forKey: defaultsKey),
               let language = AppLanguage(rawValue: saved) {
                return language
            }
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
                ? .simplifiedChinese
                : .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var resourceName: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-hans"
        }
    }

    var menuTitle: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var menuTag: Int {
        switch self {
        case .english: 0
        case .simplifiedChinese: 1
        }
    }

    init?(menuTag: Int) {
        switch menuTag {
        case 0: self = .english
        case 1: self = .simplifiedChinese
        default: return nil
        }
    }
}

enum L10n {
    enum Key: String {
        case openWallpaper = "menu.open_wallpaper"
        case openWallpaperURL = "menu.open_wallpaper_url"
        case wallpaperLibrary = "menu.wallpaper_library"
        case reloadWallpaper = "menu.reload_wallpaper"
        case wallpaperProperties = "menu.wallpaper_properties"
        case useNativeDemo = "menu.use_native_demo"
        case pauseAnimation = "menu.pause_animation"
        case resumeAnimation = "menu.resume_animation"
        case pauseWhenDesktopHidden = "menu.pause_when_desktop_hidden"
        case muteAudio = "menu.mute_audio"
        case unmuteAudio = "menu.unmute_audio"
        case language = "menu.language"
        case quit = "menu.quit"
        case openPanelTitle = "open_panel.title"
        case openPanelMessage = "open_panel.message"
        case openPanelPrompt = "open_panel.prompt"
        case openErrorTitle = "error.open_title"
        case importURLTitle = "import_url.title"
        case importURLMessage = "import_url.message"
        case importURLPlaceholder = "import_url.placeholder"
        case importAction = "action.import"
        case cancel = "action.cancel"
        case importing = "status.importing"
        case libraryWindowTitle = "library.window_title"
        case libraryColumnName = "library.column.name"
        case libraryColumnType = "library.column.type"
        case libraryColumnSource = "library.column.source"
        case libraryUse = "library.use"
        case libraryLocate = "library.locate"
        case libraryRemove = "library.remove"
        case libraryReveal = "library.reveal"
        case libraryImport = "library.import"
        case libraryCurrent = "library.current"
        case libraryUnavailable = "library.unavailable"
        case libraryBuiltInSource = "library.built_in_source"
        case libraryTypeBuiltIn = "library.type.built_in"
        case libraryTypeWeb = "library.type.web"
        case libraryTypeScene = "library.type.scene"
        case libraryTypeVideo = "library.type.video"
        case libraryRemoveTitle = "library.remove_title"
        case libraryRemoveManagedMessage = "library.remove_managed_message"
        case libraryRemoveReferenceMessage = "library.remove_reference_message"
        case nativeScene = "project.native_scene"
        case resetDefaults = "properties.reset_defaults"
        case none = "properties.none"
        case choose = "properties.choose"
        case option = "properties.option"
        case schemeColor = "properties.scheme_color"
        case propertiesWindowTitle = "properties.window_title"
        case fitMode = "properties.fit_mode"
        case fitModeAutomatic = "properties.fit_mode.automatic"
        case fitModeFill = "properties.fit_mode.fill"
        case fitModeFit = "properties.fit_mode.fit"
        case fitModeStretch = "properties.fit_mode.stretch"
        case unsupportedSelection = "error.unsupported_selection"
        case malformedManifest = "error.malformed_manifest"
        case unsupportedType = "error.unsupported_type"
        case missingEntry = "error.missing_entry"
        case entryOutsideProject = "error.entry_outside_project"
        case invalidURL = "error.invalid_url"
        case unsupportedURLScheme = "error.unsupported_url_scheme"
        case workshopURLUnsupported = "error.workshop_url_unsupported"
        case incompleteRemoteProject = "error.incomplete_remote_project"
        case fileTooLarge = "error.file_too_large"
        case archiveListingFailed = "error.archive_listing_failed"
        case unsafeArchiveEntry = "error.unsafe_archive_entry"
        case archiveExtractionFailed = "error.archive_extraction_failed"
        case archiveContainsSymbolicLink = "error.archive_symbolic_link"
        case archiveHasTooManyFiles = "error.archive_too_many_files"
        case extractedProjectTooLarge = "error.extracted_project_too_large"
        case noProjectInArchive = "error.no_project_in_archive"
        case multipleProjectsInArchive = "error.multiple_projects_in_archive"
    }

    static func text(_ key: Key, language: AppLanguage = .current) -> String {
        String(
            localized: String.LocalizationValue(key.rawValue),
            bundle: localizedBundle(for: language),
            locale: language.locale
        )
    }

    static func format(
        _ key: Key,
        language: AppLanguage = .current,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }

    static func propertiesWindowTitle(_ projectTitle: String) -> String {
        format(.propertiesWindowTitle, projectTitle)
    }

    static func libraryRemoveTitle(_ projectTitle: String) -> String {
        format(.libraryRemoveTitle, projectTitle)
    }

    static func projectTitle(for project: WallpaperProject) -> String {
        project.kind == .builtIn ? text(.nativeScene) : project.displayTitle
    }

    static func wallpaperPropertyTitle(rawTitle: String?, key: String) -> String {
        guard let rawTitle else { return key }
        guard rawTitle.hasPrefix("ui_") else { return rawTitle }
        if rawTitle == "ui_browse_properties_scheme_color" {
            return text(.schemeColor)
        }
        return rawTitle.dropFirst(3).replacingOccurrences(of: "_", with: " ")
    }

    static func fitModeTitle(_ fitMode: WallpaperFitMode) -> String {
        switch fitMode {
        case .automatic: text(.fitModeAutomatic)
        case .fill: text(.fitModeFill)
        case .fit: text(.fitModeFit)
        case .stretch: text(.fitModeStretch)
        }
    }

    static func unsupportedSelection(_ path: String) -> String {
        format(.unsupportedSelection, path)
    }

    static func malformedManifest(_ name: String, error: Error) -> String {
        format(.malformedManifest, name, error.localizedDescription)
    }

    static func unsupportedType(_ type: String) -> String {
        format(.unsupportedType, type)
    }

    static func missingEntry(_ path: String) -> String {
        format(.missingEntry, path)
    }

    static func entryOutsideProject(_ path: String) -> String {
        format(.entryOutsideProject, path)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle {
        guard let path = resourceBundle.path(
            forResource: language.resourceName,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return resourceBundle
        }
        return bundle
    }

    private static let resourceBundle: Bundle = {
        let bundleName = "Wallflow_Wallflow.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName)
        ].compactMap { $0 }

        for candidate in candidates {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        fatalError("Wallflow localization resource bundle is missing.")
    }()
}
