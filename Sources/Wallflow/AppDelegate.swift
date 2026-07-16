import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wallpaperControllers: [DesktopWindowController] = []
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var muteMenuItem: NSMenuItem?
    private var projectTitleMenuItem: NSMenuItem?
    private var propertiesMenuItem: NSMenuItem?
    private var propertiesWindowController: WallpaperPropertiesWindowController?
    private var isManuallyPaused = false
    private var isSystemSuspended = false
    private var isAudioMuted = false
    private var currentProject = WallpaperProject.builtIn
    private var currentUserProperties: JSONValue = .object([:])
    private let automaticallyPauseCoveredDisplays = !CommandLine.arguments.contains(
        "--no-auto-pause"
    )

    private static let savedProjectPathKey = "Wallflow.selectedProjectPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadInitialProject()
        currentUserProperties = restoredUserProperties(for: currentProject)
        configureStatusItem()
        rebuildWallpaperWindows()
        registerForSystemEvents()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openWallpaper() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Open Wallpaper Engine Project"
        panel.message = "Choose a project folder, project.json, index.html, or scene.pkg."
        panel.prompt = "Open Wallpaper"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            try selectProject(at: selectedURL, persist: true)
        } catch {
            showError(error)
        }
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
        guard currentUserProperties.objectValue?.isEmpty == false else { return }
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

    @objc private func screenConfigurationChanged() {
        rebuildWallpaperWindows()
    }

    @objc private func foregroundLayoutChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.evaluateForegroundCoverage()
        }
    }

    @objc private func systemWillSuspend() {
        isSystemSuspended = true
        applyRenderingState()
    }

    @objc private func systemDidResume() {
        isSystemSuspended = false
        applyRenderingState()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.path",
            accessibilityDescription: "Wallflow"
        )

        let menu = NSMenu()
        let title = NSMenuItem(title: currentProject.displayTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        projectTitleMenuItem = title
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open Wallpaper...",
            action: #selector(openWallpaper),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        let reloadItem = NSMenuItem(
            title: "Reload Wallpaper",
            action: #selector(reloadWallpaper),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let propertiesItem = NSMenuItem(
            title: "Wallpaper Properties...",
            action: #selector(showWallpaperProperties),
            keyEquivalent: ","
        )
        propertiesItem.target = self
        propertiesItem.isEnabled = currentUserProperties.objectValue?.isEmpty == false
        menu.addItem(propertiesItem)
        propertiesMenuItem = propertiesItem

        let builtInItem = NSMenuItem(
            title: "Use Native Demo",
            action: #selector(useBuiltInWallpaper),
            keyEquivalent: ""
        )
        builtInItem.target = self
        menu.addItem(builtInItem)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: "Pause Animation",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        let muteItem = NSMenuItem(
            title: "Mute Audio",
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        muteItem.target = self
        menu.addItem(muteItem)
        muteMenuItem = muteItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Wallflow",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
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
            selector: #selector(foregroundLayoutChanged),
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
        wallpaperControllers.removeAll()
        wallpaperControllers = NSScreen.screens.enumerated().map { index, screen in
            DesktopWindowController(
                screen: screen,
                project: currentProject,
                playsAudio: index == 0
            )
        }
        applyRenderingState()
        applyAudioState()
        wallpaperControllers.forEach { $0.applyUserProperties(currentUserProperties) }
        evaluateForegroundCoverage()
    }

    private func applyRenderingState() {
        let shouldRender = !isManuallyPaused && !isSystemSuspended
        wallpaperControllers.forEach { $0.setRenderingEnabled(shouldRender) }
        pauseMenuItem?.title = isManuallyPaused ? "Resume Animation" : "Pause Animation"
    }

    private func applyAudioState() {
        wallpaperControllers.forEach { $0.setAudioMuted(isAudioMuted) }
        muteMenuItem?.title = isAudioMuted ? "Unmute Audio" : "Mute Audio"
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

            controller.setCoveredByForegroundWindow(isCovered)
        }
    }

    private func loadInitialProject() {
        let commandLinePath = CommandLine.arguments.dropFirst().first {
            !$0.hasPrefix("--")
        }
        let savedPath = UserDefaults.standard.string(forKey: Self.savedProjectPathKey)
        guard let path = commandLinePath ?? savedPath else { return }

        do {
            currentProject = try WallpaperProjectLoader.load(
                URL(fileURLWithPath: path)
            )
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
            UserDefaults.standard.set(sourceURL.path, forKey: Self.savedProjectPathKey)
        }
        updateProjectTitle()
        rebuildWallpaperWindows()
    }

    private func updateProjectTitle() {
        projectTitleMenuItem?.title = currentProject.displayTitle
        propertiesMenuItem?.isEnabled = currentUserProperties.objectValue?.isEmpty == false
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Open Wallpaper"
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
    }

    private func resetUserProperties() {
        currentUserProperties = currentProject.userProperties
        if let key = userPropertiesStorageKey(for: currentProject) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        wallpaperControllers.forEach { $0.applyUserProperties(currentUserProperties) }
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
        let encodedPath = Data(url.standardizedFileURL.path.utf8).base64EncodedString()
        return "Wallflow.userProperties.\(encodedPath)"
    }
}
