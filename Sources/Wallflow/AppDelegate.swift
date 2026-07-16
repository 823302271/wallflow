import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wallpaperControllers: [DesktopWindowController] = []
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var backgroundPauseMenuItem: NSMenuItem?
    private var muteMenuItem: NSMenuItem?
    private var projectTitleMenuItem: NSMenuItem?
    private var propertiesMenuItem: NSMenuItem?
    private var propertiesWindowController: WallpaperPropertiesWindowController?
    private var isManuallyPaused = false
    private var isSystemSuspended = false
    private var isAudioMuted = false
    private var pauseWhenOtherApplicationActive = true
    private var isOtherApplicationActive = false
    private var currentProject = WallpaperProject.builtIn
    private var currentUserProperties: JSONValue = .object([:])
    private var displayConfigurationSignature = ""
    private var coverageEvaluationGeneration = 0
    private var spaceTransitionGeneration = 0
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []
    private let importService = WallpaperImportService()
    private let desktopFallbackManager = DesktopFallbackManager()
    private var fallbackRefreshGeneration = 0
    private let automaticallyPauseCoveredDisplays = !CommandLine.arguments.contains(
        "--no-auto-pause"
    )

    private static let savedProjectPathKey = "Wallflow.selectedProjectPath"
    private static let pauseWhenOtherApplicationActiveKey =
        "Wallflow.pauseWhenOtherApplicationActive"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadInitialProject()
        restoreBackgroundPausePreference()
        updateForegroundApplicationState()
        currentUserProperties = restoredUserProperties(for: currentProject)
        configureStatusItem()
        rebuildWallpaperWindows()
        registerForSystemEvents()
        didFinishLaunching = true
        if let sourceURL = pendingOpenURLs.first {
            pendingOpenURLs.removeAll()
            importWallpaper(from: sourceURL, persist: true)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingOpenURLs = urls
            return
        }
        guard let sourceURL = urls.first else { return }
        importWallpaper(from: sourceURL, persist: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopFallbackManager.restoreOriginalDesktops()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func togglePause() {
        isManuallyPaused.toggle()
        applyRenderingState()
    }

    @objc private func toggleMute() {
        isAudioMuted.toggle()
        applyAudioState()
    }

    @objc private func toggleBackgroundPause() {
        pauseWhenOtherApplicationActive.toggle()
        UserDefaults.standard.set(
            pauseWhenOtherApplicationActive,
            forKey: Self.pauseWhenOtherApplicationActiveKey
        )
        applyRenderingState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openWallpaper() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = L10n.text(.openPanelTitle)
        panel.message = L10n.text(.openPanelMessage)
        panel.prompt = L10n.text(.openPanelPrompt)
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        importWallpaper(from: selectedURL, persist: true)
    }

    @objc private func importWallpaperURL() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
        input.placeholderString = L10n.text(.importURLPlaceholder)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(.importURLTitle)
        alert.informativeText = L10n.text(.importURLMessage)
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.text(.importAction))
        alert.addButton(withTitle: L10n.text(.cancel))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceURL = URL(string: value), sourceURL.scheme != nil else {
            showError(WallpaperImportError.invalidURL)
            return
        }
        importWallpaper(from: sourceURL, persist: true)
    }

    @objc private func reloadWallpaper() {
        guard let sourceURL = currentProject.manifestURL
            ?? currentProject.entryURL
            ?? currentProject.rootURL else {
            rebuildWallpaperWindows()
            return
        }

        do {
            try selectProject(at: sourceURL, persist: false)
        } catch {
            showError(error)
        }
    }

    @objc private func showWallpaperProperties() {
        guard supportsEditableProperties else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = WallpaperPropertiesWindowController(
            title: currentProject.displayTitle,
            properties: currentUserProperties,
            onChange: { [weak self] key, value in
                self?.updateUserProperty(key: key, value: value)
            },
            onReset: { [weak self] in
                self?.resetUserProperties()
            }
        )
        propertiesWindowController?.close()
        propertiesWindowController = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func useBuiltInWallpaper() {
        currentProject = .builtIn
        currentUserProperties = restoredUserProperties(for: currentProject)
        propertiesWindowController?.close()
        propertiesWindowController = nil
        UserDefaults.standard.removeObject(forKey: Self.savedProjectPathKey)
        updateProjectTitle()
        rebuildWallpaperWindows()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let language = AppLanguage(menuTag: sender.tag),
              language != AppLanguage.current else {
            return
        }
        AppLanguage.current = language
        propertiesWindowController?.close()
        propertiesWindowController = nil
        rebuildStatusMenu()
    }

    @objc private func screenConfigurationChanged() {
        let signature = Self.currentDisplayConfigurationSignature()
        guard signature != displayConfigurationSignature else {
            prepareWallpaperWindowsForPresentation()
            return
        }
        reconcileWallpaperWindows()
    }

    @objc private func foregroundLayoutChanged() {
        updateForegroundApplicationState()
        scheduleForegroundCoverageEvaluation()
    }

    @objc private func activeSpaceChanged() {
        spaceTransitionGeneration += 1
        let generation = spaceTransitionGeneration
        wallpaperControllers.forEach { $0.beginSpaceTransition() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, generation == self.spaceTransitionGeneration else { return }
            self.wallpaperControllers.forEach { $0.finishSpaceTransition() }
        }
        scheduleForegroundCoverageEvaluation()
    }

    private func scheduleForegroundCoverageEvaluation() {
        coverageEvaluationGeneration += 1
        let generation = coverageEvaluationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, generation == self.coverageEvaluationGeneration else { return }
            self.updateForegroundApplicationState()
            self.evaluateForegroundCoverage()
        }
    }

    @objc private func systemWillSuspend() {
        isSystemSuspended = true
        applyRenderingState()
    }

    @objc private func systemDidResume() {
        isSystemSuspended = false
        prepareWallpaperWindowsForPresentation()
        applyRenderingState()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.path",
            accessibilityDescription: "Wallflow"
        )
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let title = NSMenuItem(
            title: L10n.projectTitle(for: currentProject),
            action: nil,
            keyEquivalent: ""
        )
        title.isEnabled = false
        menu.addItem(title)
        projectTitleMenuItem = title
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: L10n.text(.openWallpaper),
            action: #selector(openWallpaper),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        let openURLItem = NSMenuItem(
            title: L10n.text(.openWallpaperURL),
            action: #selector(importWallpaperURL),
            keyEquivalent: ""
        )
        openURLItem.target = self
        menu.addItem(openURLItem)

        let reloadItem = NSMenuItem(
            title: L10n.text(.reloadWallpaper),
            action: #selector(reloadWallpaper),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let propertiesItem = NSMenuItem(
            title: L10n.text(.wallpaperProperties),
            action: #selector(showWallpaperProperties),
            keyEquivalent: ","
        )
        propertiesItem.target = self
        propertiesItem.isEnabled = supportsEditableProperties
        menu.addItem(propertiesItem)
        propertiesMenuItem = propertiesItem

        let builtInItem = NSMenuItem(
            title: L10n.text(.useNativeDemo),
            action: #selector(useBuiltInWallpaper),
            keyEquivalent: ""
        )
        builtInItem.target = self
        menu.addItem(builtInItem)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: isManuallyPaused ? L10n.text(.resumeAnimation) : L10n.text(.pauseAnimation),
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        let backgroundPauseItem = NSMenuItem(
            title: L10n.text(.pauseWhenOtherAppActive),
            action: #selector(toggleBackgroundPause),
            keyEquivalent: ""
        )
        backgroundPauseItem.target = self
        backgroundPauseItem.state = pauseWhenOtherApplicationActive ? .on : .off
        menu.addItem(backgroundPauseItem)
        backgroundPauseMenuItem = backgroundPauseItem

        let muteItem = NSMenuItem(
            title: isAudioMuted ? L10n.text(.unmuteAudio) : L10n.text(.muteAudio),
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        muteItem.target = self
        menu.addItem(muteItem)
        muteMenuItem = muteItem

        menu.addItem(.separator())

        let languageItem = NSMenuItem(
            title: L10n.text(.language),
            action: nil,
            keyEquivalent: ""
        )
        let languageMenu = NSMenu(title: L10n.text(.language))
        for language in AppLanguage.allCases {
            let item = NSMenuItem(
                title: language.menuTitle,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = language.menuTag
            item.state = language == AppLanguage.current ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text(.quit),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    private func registerForSystemEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSuspend),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidResume),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSuspend),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidResume),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(foregroundLayoutChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func rebuildWallpaperWindows() {
        displayConfigurationSignature = Self.currentDisplayConfigurationSignature()
        let previousControllers = wallpaperControllers
        let newControllers = NSScreen.screens.enumerated().map { index, screen in
            DesktopWindowController(
                screen: screen,
                project: currentProject,
                playsAudio: index == 0
            )
        }
        wallpaperControllers = newControllers
        applyRenderingState()
        applyAudioState()
        wallpaperControllers.forEach { $0.applyUserProperties(currentUserProperties) }
        wallpaperControllers.forEach { $0.prepareForPresentation() }
        previousControllers.forEach { $0.close() }
        evaluateForegroundCoverage()
        scheduleFallbackRefresh()
    }

    private func reconcileWallpaperWindows() {
        displayConfigurationSignature = Self.currentDisplayConfigurationSignature()
        let previousControllers = wallpaperControllers
        var availableByDisplayID: [CGDirectDisplayID: DesktopWindowController] = [:]
        previousControllers.forEach { controller in
            if availableByDisplayID[controller.displayID] == nil {
                availableByDisplayID[controller.displayID] = controller
            }
        }
        var nextControllers: [DesktopWindowController] = []
        var reusedCount = 0

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = DesktopWindowController.displayID(for: screen)
            if let controller = availableByDisplayID.removeValue(forKey: displayID) {
                controller.update(screen: screen, playsAudio: index == 0)
                nextControllers.append(controller)
                reusedCount += 1
            } else {
                nextControllers.append(
                    DesktopWindowController(
                        screen: screen,
                        project: currentProject,
                        playsAudio: index == 0
                    )
                )
            }
        }

        wallpaperControllers = nextControllers
        applyRenderingState()
        applyAudioState()
        wallpaperControllers.forEach { $0.applyUserProperties(currentUserProperties) }
        let retainedControllers = Set(nextControllers.map(ObjectIdentifier.init))
        previousControllers
            .filter { !retainedControllers.contains(ObjectIdentifier($0)) }
            .forEach { $0.close() }
        evaluateForegroundCoverage()
        scheduleFallbackRefresh()
        NSLog(
            "Wallflow display reconciliation: reused %d, created %d, removed %d",
            reusedCount,
            max(0, nextControllers.count - reusedCount),
            availableByDisplayID.count
        )
    }

    private func prepareWallpaperWindowsForPresentation() {
        wallpaperControllers.forEach { $0.prepareForPresentation() }
    }

    private func applyRenderingState() {
        let backgroundPaused = pauseWhenOtherApplicationActive && isOtherApplicationActive
        let shouldRender = !isManuallyPaused && !isSystemSuspended && !backgroundPaused
        wallpaperControllers.forEach { $0.setRenderingEnabled(shouldRender) }
        pauseMenuItem?.title = isManuallyPaused
            ? L10n.text(.resumeAnimation)
            : L10n.text(.pauseAnimation)
        backgroundPauseMenuItem?.state = pauseWhenOtherApplicationActive ? .on : .off
    }

    private func applyAudioState() {
        wallpaperControllers.forEach { $0.setAudioMuted(isAudioMuted) }
        muteMenuItem?.title = isAudioMuted ? L10n.text(.unmuteAudio) : L10n.text(.muteAudio)
    }

    private func evaluateForegroundCoverage() {
        guard automaticallyPauseCoveredDisplays else {
            wallpaperControllers.forEach { $0.setCoveredByForegroundWindow(false) }
            return
        }
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for controller in wallpaperControllers {
            let screenBounds = controller.displayBounds
            let screenArea = screenBounds.width * screenBounds.height

            let isCovered = windowInfo.contains { info in
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                      ownerPID != ownPID,
                      let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(
                          dictionaryRepresentation: boundsDictionary as CFDictionary
                      ),
                      screenArea > 0 else {
                    return false
                }

                let intersection = bounds.intersection(screenBounds)
                let coveredArea = max(0, intersection.width) * max(0, intersection.height)
                return coveredArea / screenArea >= 0.97
            }

            let coverageChanged = controller.setCoveredByForegroundWindow(isCovered)
            if coverageChanged, isCovered {
                refreshFallback(for: controller)
            }
        }
    }

    private func loadInitialProject() {
        let commandLinePath = CommandLine.arguments.dropFirst().first {
            !$0.hasPrefix("--")
        }
        let savedPath = UserDefaults.standard.string(forKey: Self.savedProjectPathKey)
        guard let source = commandLinePath ?? savedPath else { return }

        do {
            currentProject = try WallpaperProjectLoader.load(Self.sourceURL(from: source))
            currentUserProperties = restoredUserProperties(for: currentProject)
        } catch {
            NSLog("Wallflow could not restore wallpaper: %@", error.localizedDescription)
            UserDefaults.standard.removeObject(forKey: Self.savedProjectPathKey)
        }
    }

    private func selectProject(at url: URL, persist: Bool) throws {
        let project = try WallpaperProjectLoader.load(url)
        currentProject = project
        currentUserProperties = restoredUserProperties(for: project)
        propertiesWindowController?.close()
        propertiesWindowController = nil
        if persist {
            let sourceURL = project.manifestURL ?? project.entryURL ?? url
            let savedSource = sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
            UserDefaults.standard.set(savedSource, forKey: Self.savedProjectPathKey)
        }
        updateProjectTitle()
        rebuildWallpaperWindows()
    }

    private func importWallpaper(from sourceURL: URL, persist: Bool) {
        projectTitleMenuItem?.title = L10n.text(.importing)
        importService.prepare(sourceURL: sourceURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let preparedURL):
                do {
                    try self.selectProject(at: preparedURL, persist: persist)
                } catch {
                    self.updateProjectTitle()
                    self.showError(error)
                }
            case .failure(let error):
                self.updateProjectTitle()
                self.showError(error)
            }
        }
    }

    private func updateProjectTitle() {
        projectTitleMenuItem?.title = L10n.projectTitle(for: currentProject)
        propertiesMenuItem?.isEnabled = supportsEditableProperties
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(.openErrorTitle)
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func updateUserProperty(key: String, value: JSONValue) {
        guard var allProperties = currentUserProperties.objectValue,
              var definition = allProperties[key]?.objectValue else {
            return
        }
        definition["value"] = value
        let changedDefinition = JSONValue.object(definition)
        allProperties[key] = changedDefinition
        currentUserProperties = .object(allProperties)
        persistUserProperties()
        let changed = JSONValue.object([key: changedDefinition])
        wallpaperControllers.forEach { $0.applyUserProperties(changed) }
        scheduleFallbackRefresh(delay: 0.35)
    }

    private func resetUserProperties() {
        currentUserProperties = currentProject.userProperties
        if let key = userPropertiesStorageKey(for: currentProject) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        wallpaperControllers.forEach { $0.applyUserProperties(currentUserProperties) }
        scheduleFallbackRefresh(delay: 0.35)
        propertiesWindowController?.close()
        propertiesWindowController = nil
        showWallpaperProperties()
    }

    private func restoredUserProperties(for project: WallpaperProject) -> JSONValue {
        guard let key = userPropertiesStorageKey(for: project),
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(JSONValue.self, from: data),
              let savedProperties = saved.objectValue else {
            return project.userProperties
        }

        var definitions = project.userProperties.objectValue ?? [:]
        for (propertyKey, savedDefinition) in savedProperties {
            guard var definition = definitions[propertyKey]?.objectValue,
                  let savedValue = savedDefinition.objectValue?["value"] else {
                continue
            }
            definition["value"] = savedValue
            definitions[propertyKey] = .object(definition)
        }
        return .object(definitions)
    }

    private func restoreBackgroundPausePreference() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.pauseWhenOtherApplicationActiveKey) != nil {
            pauseWhenOtherApplicationActive = defaults.bool(
                forKey: Self.pauseWhenOtherApplicationActiveKey
            )
        }
    }

    private func updateForegroundApplicationState() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            isOtherApplicationActive = false
            return
        }
        let isFinder = application.bundleIdentifier == "com.apple.finder"
        let isWallflow = application.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        let newValue = !isFinder
            && !isWallflow
            && Self.hasVisibleWindow(processIdentifier: application.processIdentifier)
        guard newValue != isOtherApplicationActive else { return }
        isOtherApplicationActive = newValue
        if didFinishLaunching {
            applyRenderingState()
        }
    }

    private static func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        return windowInfo.contains { info in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard ownerPID == processIdentifier,
                  layer == 0,
                  alpha > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return false
            }
            return bounds.width * bounds.height >= 4_096
        }
    }

    private func persistUserProperties() {
        guard let key = userPropertiesStorageKey(for: currentProject),
              let data = try? JSONEncoder().encode(currentUserProperties) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func userPropertiesStorageKey(for project: WallpaperProject) -> String? {
        guard let url = project.manifestURL ?? project.entryURL ?? project.rootURL else {
            return nil
        }
        let source = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        let encodedPath = Data(source.utf8).base64EncodedString()
        return "Wallflow.userProperties.\(encodedPath)"
    }

    private static func sourceURL(from source: String) -> URL {
        if let url = URL(string: source),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return url
        }
        return URL(fileURLWithPath: source)
    }

    private var supportsEditableProperties: Bool {
        currentProject.kind == .web
            && currentUserProperties.objectValue?.isEmpty == false
    }

    private func scheduleFallbackRefresh(delay: TimeInterval = 1.0) {
        fallbackRefreshGeneration += 1
        let generation = fallbackRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.fallbackRefreshGeneration else { return }
            self.wallpaperControllers.forEach { self.refreshFallback(for: $0) }
        }
        if delay <= 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, generation == self.fallbackRefreshGeneration else { return }
                self.wallpaperControllers.forEach { self.refreshFallback(for: $0) }
            }
        }
    }

    private func refreshFallback(for controller: DesktopWindowController) {
        controller.captureFrame { [weak self, weak controller] image in
            guard let self,
                  let controller,
                  let image,
                  let snapshot = WallpaperSnapshot.preparedImage(from: image) else {
                return
            }
            controller.setTransitionFrame(snapshot)
            self.desktopFallbackManager.update(
                image: snapshot,
                for: controller.screen,
                displayID: controller.displayID
            )
        }
    }

    private static func currentDisplayConfigurationSignature() -> String {
        NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value ?? 0
            let frame = screen.frame
            return [
                String(displayID),
                String(Double(frame.origin.x)),
                String(Double(frame.origin.y)),
                String(Double(frame.width)),
                String(Double(frame.height)),
                String(Double(screen.backingScaleFactor))
            ].joined(separator: ":")
        }
        .sorted()
        .joined(separator: "|")
    }
}
