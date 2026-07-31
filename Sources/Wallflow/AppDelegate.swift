import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wallpaperControllers: [DesktopWindowController] = []
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var desktopHiddenPauseMenuItem: NSMenuItem?
    private var muteMenuItem: NSMenuItem?
    private var projectTitleMenuItem: NSMenuItem?
    private var propertiesMenuItem: NSMenuItem?
    private var propertiesWindowController: WallpaperPropertiesWindowController?
    private var libraryWindowController: WallpaperLibraryWindowController?
    private var isManuallyPaused = false
    private var isSystemSuspended = false
    private var isAudioMuted = false
    private var pauseWhenDesktopHidden = true
    private var currentProject = WallpaperProject.builtIn
    private var currentUserProperties: JSONValue = .object([:])
    private var currentFitMode: WallpaperFitMode = .automatic
    /// Project loaded for each attached display (source of truth for rendering).
    private var projectsByDisplayID: [CGDirectDisplayID: WallpaperProject] = [:]
    private var displayConfigurationSignature = ""
    private var coverageEvaluationGeneration = 0
    private var coverageWatchdog: Timer?
    private var fallbackRefreshGeneration = 0
    /// Per-display resume debounce so brief Space-transition "visible" blips
    /// cannot start the playhead and produce a future-frame jump.
    private var resumeDebounceGeneration: [CGDirectDisplayID: Int] = [:]
    /// Per-display Space holds. The workspace Space notification has no display
    /// identity, so concrete transitions are keyed by wallpaper-window occlusion.
    private var displaySpaceTransitions = DisplaySpaceTransitionState()
    /// Per-display generation for host-driven pause-session commit.
    private var sessionCommitGeneration: [CGDirectDisplayID: Int] = [:]
    /// Quiet period before the affected display may resume.
    private static let spaceTransitionQuietPeriod: TimeInterval = 0.85
    /// Continuous live play required before unlocking the pause-session timeline.
    private static let pauseSessionCommitDelay: TimeInterval = 1.5
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []
    private let importService = WallpaperImportService()
    private let wallpaperLibrary = WallpaperLibrary()
    private let desktopFallbackManager = DesktopFallbackManager()
    private let displayWallpaperStore = DisplayWallpaperStore()
    private let automaticallyPauseCoveredDisplays = !CommandLine.arguments.contains(
        "--no-auto-pause"
    )

    private static let savedProjectPathKey = "Wallflow.selectedProjectPath"
    private static let pauseWhenDesktopHiddenKey = "Wallflow.pauseWhenDesktopHidden"

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreDesktopVisibilityPreference()
        loadProjectsForAttachedDisplays()
        syncFocusedProjectState()
        registerCurrentProjectInLibrary()
        configureStatusItem()
        rebuildWallpaperWindows()
        registerForSystemEvents()
        startCoverageWatchdog()
        didFinishLaunching = true
        if let sourceURL = pendingOpenURLs.first {
            pendingOpenURLs.removeAll()
            importWallpaper(from: sourceURL, persist: true, target: .all)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingOpenURLs = urls
            return
        }
        guard let sourceURL = urls.first else { return }
        importWallpaper(from: sourceURL, persist: true, target: .all)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coverageWatchdog?.invalidate()
        coverageWatchdog = nil
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

    @objc private func toggleDesktopHiddenPause() {
        pauseWhenDesktopHidden.toggle()
        UserDefaults.standard.set(
            pauseWhenDesktopHidden,
            forKey: Self.pauseWhenDesktopHiddenKey
        )
        desktopHiddenPauseMenuItem?.state = pauseWhenDesktopHidden ? .on : .off
        // Turning the preference off must resume immediately.
        if !pauseWhenDesktopHidden {
            displaySpaceTransitions.clear()
        }
        evaluateForegroundCoverage()
        NSLog(
            "Wallflow pause-when-hidden %@",
            pauseWhenDesktopHidden ? "enabled" : "disabled"
        )
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openWallpaper() {
        guard let selectedURL = chooseWallpaperSource() else { return }
        importWallpaper(from: selectedURL, persist: true, target: .all)
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
        importWallpaper(from: sourceURL, persist: true, target: .all)
    }

    @objc private func showWallpaperLibrary() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if libraryWindowController == nil {
            libraryWindowController = WallpaperLibraryWindowController(
                entries: wallpaperLibrary.entries,
                activeAssignments: currentDisplayAssignments(),
                displayOptions: libraryDisplayOptions(),
                enginePackInstalled: EngineAssetStore.shared.isParticlePackInstalled,
                onUse: { [weak self] entry, target in
                    self?.activateLibraryEntry(entry, target: target)
                },
                onLocateUnavailable: { [weak self] entry in
                    self?.locateUnavailableLibraryEntry(entry)
                },
                onRemove: { [weak self] entry in
                    self?.confirmLibraryRemoval(entry)
                },
                onReveal: { entry in
                    NSWorkspace.shared.activateFileViewerSelecting([entry.sourceURL])
                },
                onImportFile: { [weak self] in
                    self?.openWallpaper()
                },
                onImportURL: { [weak self] in
                    self?.importWallpaperURL()
                },
                onImportEnginePack: { [weak self] in
                    self?.importEngineParticlePack()
                }
            )
        }
        refreshLibraryWindow()
        libraryWindowController?.window?.center()
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func reloadWallpaper() {
        // Reload each display from its assigned source so multi-monitor setups
        // keep independent wallpapers.
        loadProjectsForAttachedDisplays()
        syncFocusedProjectState()
        rebuildWallpaperWindows()
        updateProjectTitle()
    }

    @objc private func showWallpaperProperties() {
        guard supportsEditableProperties else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = WallpaperPropertiesWindowController(
            title: currentProject.displayTitle,
            properties: currentUserProperties,
            fitMode: currentFitMode,
            onChange: { [weak self] key, value in
                self?.updateUserProperty(key: key, value: value)
            },
            onFitModeChange: { [weak self] fitMode in
                self?.updateFitMode(fitMode)
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
        applyBuiltIn(target: .all)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let language = AppLanguage(menuTag: sender.tag),
              language != AppLanguage.current else {
            return
        }
        AppLanguage.current = language
        propertiesWindowController?.close()
        propertiesWindowController = nil
        libraryWindowController?.close()
        libraryWindowController = nil
        rebuildStatusMenu()
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        let signature = Self.currentDisplayConfigurationSignature()
        guard signature != displayConfigurationSignature else {
            // Geometry-only change: re-layer each window without pausing others.
            wallpaperControllers.forEach { $0.ensureDesktopLayering() }
            return
        }
        reconcileWallpaperWindows()
    }

    @objc private func foregroundLayoutChanged(_ notification: Notification) {
        evaluateForegroundCoverage()
        scheduleForegroundCoverageEvaluation()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        // NSWorkspace provides no display ID or userInfo here. Use this only as a
        // prompt to re-evaluate; the per-window occlusion notification below owns
        // display-specific transition holds and pause-session pinning.
        NSLog("Wallflow active Space changed")
        evaluateForegroundCoverage()
        scheduleForegroundCoverageEvaluation(after: 0.6)
    }

    @objc private func wallpaperWindowOcclusionChanged(_ notification: Notification) {
        guard isCoverageAutoPauseEnabled,
              let window = notification.object as? NSWindow,
              let controller = wallpaperControllers.first(where: {
                  $0.manages(window: window)
              }) else {
            return
        }
        // Apple identifies the changed NSWindow here, which gives us the physical
        // display that NSWorkspace.activeSpaceDidChangeNotification omits.
        beginSpaceTransition(for: controller)
    }

    private func isInSpaceTransitionQuietPeriod(
        for displayID: CGDirectDisplayID
    ) -> Bool {
        displaySpaceTransitions.isQuiet(
            for: displayID,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Pin only the display whose wallpaper window changed occlusion.
    private func beginSpaceTransition(for controller: DesktopWindowController) {
        guard isCoverageAutoPauseEnabled else { return }
        let displayID = controller.displayID
        let generation = displaySpaceTransitions.begin(
            for: displayID,
            now: ProcessInfo.processInfo.systemUptime,
            quietPeriod: Self.spaceTransitionQuietPeriod
        )
        resumeDebounceGeneration[displayID, default: 0] += 1
        sessionCommitGeneration[displayID, default: 0] += 1
        let changed = controller.pinDesktopForSpaceTransition()
        if changed {
            NSLog("Wallflow display %u rendering paused", displayID)
        }
        NSLog(
            "Wallflow display %u Space transition pinned (generation=%d)",
            displayID,
            generation
        )
        let quiet = Self.spaceTransitionQuietPeriod
        scheduleSpaceSettledCoverageEvaluation(
            for: controller,
            after: quiet,
            transitionGeneration: generation
        )
        scheduleSpaceSettledCoverageEvaluation(
            for: controller,
            after: quiet + 0.4,
            transitionGeneration: generation
        )
    }

    private func scheduleForegroundCoverageEvaluation(after delay: TimeInterval = 0.35) {
        coverageEvaluationGeneration += 1
        let generation = coverageEvaluationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.coverageEvaluationGeneration else { return }
            self.evaluateForegroundCoverage()
        }
    }

    /// A later hop on this display cancels its pending evaluation. Other displays
    /// have independent generations and continue rendering without interruption.
    private func scheduleSpaceSettledCoverageEvaluation(
        for controller: DesktopWindowController,
        after delay: TimeInterval,
        transitionGeneration: Int
    ) {
        let displayID = controller.displayID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            [weak self, weak controller] in
            guard let self,
                  let controller,
                  transitionGeneration == self.displaySpaceTransitions.generation(
                      for: displayID
                  ) else {
                return
            }
            self.evaluateForegroundCoverage(for: controller)
        }
    }

    private func startCoverageWatchdog() {
        guard coverageWatchdog == nil else { return }
        // Adaptive interval: when every display is already frozen, poll less often
        // so background CPU stays below live-desktop rendering.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.evaluateForegroundCoverage()
            self?.retuneCoverageWatchdog()
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        coverageWatchdog = timer
    }

    private func retuneCoverageWatchdog() {
        guard let coverageWatchdog else { return }
        let allHidden = !wallpaperControllers.isEmpty
            && wallpaperControllers.allSatisfy(\.isDesktopHidden)
        let desired: TimeInterval = allHidden ? 3.0 : 1.0
        // Timer.timeInterval is read-only after create — rebuild when regime changes.
        if abs(coverageWatchdog.timeInterval - desired) < 0.05 { return }
        coverageWatchdog.invalidate()
        self.coverageWatchdog = nil
        let timer = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
            self?.evaluateForegroundCoverage()
            self?.retuneCoverageWatchdog()
        }
        timer.tolerance = desired * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.coverageWatchdog = timer
    }

    @objc private func systemWillSuspend(_ notification: Notification) {
        isSystemSuspended = true
        applyRenderingState()
    }

    @objc private func systemDidResume(_ notification: Notification) {
        isSystemSuspended = false
        wallpaperControllers.forEach { $0.ensureDesktopLayering() }
        applyRenderingState()
        evaluateForegroundCoverage()
        scheduleFallbackRefresh(delay: 0.8)
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
        menu.delegate = self
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

        let libraryItem = NSMenuItem(
            title: L10n.text(.wallpaperLibrary),
            action: #selector(showWallpaperLibrary),
            keyEquivalent: "l"
        )
        libraryItem.target = self
        menu.addItem(libraryItem)

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

        let desktopHiddenPauseItem = NSMenuItem(
            title: L10n.text(.pauseWhenDesktopHidden),
            action: #selector(toggleDesktopHiddenPause),
            keyEquivalent: ""
        )
        desktopHiddenPauseItem.target = self
        desktopHiddenPauseItem.state = pauseWhenDesktopHidden ? .on : .off
        menu.addItem(desktopHiddenPauseItem)
        desktopHiddenPauseMenuItem = desktopHiddenPauseItem

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
            selector: #selector(screenConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(wallpaperWindowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSuspend(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSuspend(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(foregroundLayoutChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func rebuildWallpaperWindows() {
        displaySpaceTransitions.clear()
        displayConfigurationSignature = Self.currentDisplayConfigurationSignature()
        loadProjectsForAttachedDisplays()
        let previousControllers = wallpaperControllers
        let newControllers = NSScreen.screens.enumerated().map { index, screen in
            let displayID = DesktopWindowController.displayID(for: screen)
            let project = project(for: displayID)
            return makeDesktopController(
                screen: screen,
                project: project,
                playsAudio: index == 0
            )
        }
        wallpaperControllers = newControllers
        applyRenderingState()
        applyAudioState()
        for controller in wallpaperControllers {
            let project = project(for: controller.displayID)
            controller.applyUserProperties(restoredUserProperties(for: project))
        }
        wallpaperControllers.forEach { $0.prepareForPresentation() }
        previousControllers.forEach { $0.close() }
        evaluateForegroundCoverage()
        // Seed a desktop still for each screen after first paint.
        scheduleFallbackRefresh()
        syncFocusedProjectState()
        updateProjectTitle()
    }

    private func reconcileWallpaperWindows() {
        displayConfigurationSignature = Self.currentDisplayConfigurationSignature()
        loadProjectsForAttachedDisplays()
        let previousControllers = wallpaperControllers
        var availableByDisplayID: [CGDirectDisplayID: DesktopWindowController] = [:]
        previousControllers.forEach { controller in
            if availableByDisplayID[controller.displayID] == nil {
                availableByDisplayID[controller.displayID] = controller
            }
        }
        var nextControllers: [DesktopWindowController] = []
        var reusedCount = 0
        var recreatedCount = 0

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = DesktopWindowController.displayID(for: screen)
            let project = project(for: displayID)
            if let controller = availableByDisplayID.removeValue(forKey: displayID),
               controller.projectIdentity == Self.projectIdentity(project) {
                controller.update(screen: screen, playsAudio: index == 0)
                nextControllers.append(controller)
                reusedCount += 1
            } else {
                availableByDisplayID.removeValue(forKey: displayID)?.close()
                nextControllers.append(
                    makeDesktopController(
                        screen: screen,
                        project: project,
                        playsAudio: index == 0
                    )
                )
                recreatedCount += 1
            }
        }

        wallpaperControllers = nextControllers
        displaySpaceTransitions.retain(
            displayIDs: Set(nextControllers.map(\.displayID))
        )
        applyRenderingState()
        applyAudioState()
        for controller in wallpaperControllers {
            let project = project(for: controller.displayID)
            controller.applyUserProperties(restoredUserProperties(for: project))
        }
        let retainedControllers = Set(nextControllers.map(ObjectIdentifier.init))
        previousControllers
            .filter { !retainedControllers.contains(ObjectIdentifier($0)) }
            .forEach { $0.close() }
        evaluateForegroundCoverage()
        scheduleFallbackRefresh()
        syncFocusedProjectState()
        updateProjectTitle()
        NSLog(
            "Wallflow display reconciliation: reused %d, created %d, removed %d",
            reusedCount,
            recreatedCount,
            availableByDisplayID.count
        )
    }

    private func makeDesktopController(
        screen: NSScreen,
        project: WallpaperProject,
        playsAudio: Bool
    ) -> DesktopWindowController {
        let fitMode = wallpaperLibrary.entry(for: project)?.fitMode ?? .automatic
        let controller = DesktopWindowController(
            screen: screen,
            project: project,
            playsAudio: playsAudio,
            fitMode: fitMode
        )
        controller.projectIdentity = Self.projectIdentity(project)
        bindPausedFrameHandler(to: controller)
        return controller
    }

    private func bindPausedFrameHandler(to controller: DesktopWindowController) {
        controller.onPausedFrameCaptured = { [weak self, weak controller] image in
            guard let self, let controller else { return }
            self.desktopFallbackManager.update(
                image: image,
                for: controller.screen,
                displayID: controller.displayID
            )
        }
    }

    private func applyRenderingState() {
        let shouldRender = !isManuallyPaused && !isSystemSuspended
        wallpaperControllers.forEach { $0.setRenderingEnabled(shouldRender) }
        pauseMenuItem?.title = isManuallyPaused
            ? L10n.text(.resumeAnimation)
            : L10n.text(.pauseAnimation)
        desktopHiddenPauseMenuItem?.state = pauseWhenDesktopHidden ? .on : .off
    }

    private func applyAudioState() {
        wallpaperControllers.forEach { $0.setAudioMuted(isAudioMuted) }
        muteMenuItem?.title = isAudioMuted ? L10n.text(.unmuteAudio) : L10n.text(.muteAudio)
    }

    /// Whether coverage-based auto-pause is active (menu preference + CLI flag).
    private var isCoverageAutoPauseEnabled: Bool {
        automaticallyPauseCoveredDisplays && pauseWhenDesktopHidden
    }

    /// Recompute desktop visibility. When `target` is set, only that display is updated.
    private func evaluateForegroundCoverage(
        for target: DesktopWindowController? = nil
    ) {
        let controllers = target.map { [$0] } ?? wallpaperControllers
        guard isCoverageAutoPauseEnabled else {
            // Preference off: cancel probes and keep every display live.
            for controller in controllers {
                forceDesktopLive(controller)
            }
            return
        }
        let windowBounds = DesktopVisibility.visibleApplicationWindowBounds()
        for controller in controllers {
            // Mid multi-hop swipe on this display: never resume its intermediate
            // desktop, but leave every other display untouched.
            if isInSpaceTransitionQuietPeriod(for: controller.displayID) {
                requestDesktopHidden(true, for: controller)
                continue
            }
            // Refresh Quartz bounds in case the display layout moved.
            let screenBounds = DesktopVisibility.desktopQuartzBounds(
                displayID: controller.displayID,
                screen: controller.screen
            )
            let coveredByWindows = DesktopVisibility.isDisplayHidden(
                screenBounds,
                by: windowBounds
            )
            // Occluded (full-screen Space, or window not on this Space) => hidden.
            let isDesktopHidden = coveredByWindows || !controller.isWindowVisible
            requestDesktopHidden(isDesktopHidden, for: controller)
        }
    }

    /// Cancel pending resume/pause probes and force the live surface on.
    private func forceDesktopLive(_ controller: DesktopWindowController) {
        let displayID = controller.displayID
        resumeDebounceGeneration[displayID, default: 0] += 1
        applyDesktopHidden(false, to: controller)
    }

    /// Pause immediately; resume only after a short per-display stable period.
    private func requestDesktopHidden(
        _ hidden: Bool,
        for controller: DesktopWindowController
    ) {
        // Menu preference (or --no-auto-pause) must fully disable coverage pauses.
        guard isCoverageAutoPauseEnabled else {
            forceDesktopLive(controller)
            return
        }

        let displayID = controller.displayID
        if hidden {
            // Cancel any pending resume and pause right away so the playhead freezes.
            resumeDebounceGeneration[displayID, default: 0] += 1
            applyDesktopHidden(true, to: controller)
            return
        }

        // Still swiping through Spaces — do not arm resume yet.
        if isInSpaceTransitionQuietPeriod(for: displayID) {
            resumeDebounceGeneration[displayID, default: 0] += 1
            applyDesktopHidden(true, to: controller)
            return
        }

        // Already live — nothing to do.
        if !controller.isDesktopHidden {
            return
        }

        let generation = (resumeDebounceGeneration[displayID] ?? 0) + 1
        resumeDebounceGeneration[displayID] = generation
        // Base stability delay after Space has been quiet.
        let delay: TimeInterval = 0.35
        // Three consecutive visible samples (~0.2s apart) before resume.
        scheduleResumeVisibilityProbe(
            displayID: displayID,
            generation: generation,
            controller: controller,
            delay: delay,
            remainingSamples: 3
        )
    }

    private func scheduleResumeVisibilityProbe(
        displayID: CGDirectDisplayID,
        generation: Int,
        controller: DesktopWindowController,
        delay: TimeInterval,
        remainingSamples: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.resumeDebounceGeneration[displayID] == generation,
                  controller.isDesktopHidden else {
                return
            }
            // Preference flipped off while a probe was in flight — go live now.
            guard self.isCoverageAutoPauseEnabled else {
                self.forceDesktopLive(controller)
                return
            }
            // A new Space hop started while we were probing — abort resume.
            if self.isInSpaceTransitionQuietPeriod(for: displayID) {
                self.applyDesktopHidden(true, to: controller)
                return
            }
            let windowBounds = DesktopVisibility.visibleApplicationWindowBounds()
            let screenBounds = DesktopVisibility.desktopQuartzBounds(
                displayID: controller.displayID,
                screen: controller.screen
            )
            let stillHidden = DesktopVisibility.isDisplayHidden(
                screenBounds,
                by: windowBounds
            ) || !controller.isWindowVisible
            guard !stillHidden else {
                // Stay paused; a later coverage pass re-arms resume when stable.
                self.applyDesktopHidden(true, to: controller)
                return
            }
            if remainingSamples <= 1 {
                // Final sample: refuse resume if another Space hop began.
                guard !self.isInSpaceTransitionQuietPeriod(for: displayID) else {
                    self.applyDesktopHidden(true, to: controller)
                    return
                }
                self.applyDesktopHidden(false, to: controller)
                return
            }
            self.scheduleResumeVisibilityProbe(
                displayID: displayID,
                generation: generation,
                controller: controller,
                delay: 0.2,
                remainingSamples: remainingSamples - 1
            )
        }
    }

    private func applyDesktopHidden(
        _ hidden: Bool,
        to controller: DesktopWindowController
    ) {
        // Normal visibility polling is idempotent; only the per-window Space path
        // above explicitly re-pins an already hidden renderer.
        let changed = controller.setDesktopHidden(hidden)
        if hidden {
            sessionCommitGeneration[controller.displayID, default: 0] += 1
            if changed {
                NSLog(
                    "Wallflow display %u rendering paused",
                    controller.displayID
                )
            }
            return
        }
        guard changed else { return }
        NSLog(
            "Wallflow display %u rendering resumed",
            controller.displayID
        )
        schedulePauseSessionCommit(for: controller)
    }

    /// Unlock renderer pause-session locks only after continuous live play with no
    /// Space hop — so 1→2→3 intermediate resumes cannot rewrite the timeline.
    private func schedulePauseSessionCommit(for controller: DesktopWindowController) {
        let displayID = controller.displayID
        let commitGeneration = (sessionCommitGeneration[displayID] ?? 0) + 1
        sessionCommitGeneration[displayID] = commitGeneration
        let transitionGeneration = displaySpaceTransitions.generation(for: displayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseSessionCommitDelay) {
            [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.sessionCommitGeneration[displayID] == commitGeneration,
                  transitionGeneration == self.displaySpaceTransitions.generation(
                      for: displayID
                  ),
                  !self.isInSpaceTransitionQuietPeriod(for: displayID),
                  !controller.isDesktopHidden else {
                return
            }
            controller.commitPauseSession()
            NSLog(
                "Wallflow display %u pause session committed",
                displayID
            )
        }
    }

    private func loadProjectsForAttachedDisplays() {
        var next: [CGDirectDisplayID: WallpaperProject] = [:]
        // Optional CLI wallpaper seeds every display on first launch path.
        let commandLinePath = CommandLine.arguments.dropFirst().first {
            !$0.hasPrefix("--")
        }
        if let commandLinePath {
            do {
                let project = try WallpaperProjectLoader.load(Self.sourceURL(from: commandLinePath))
                let token = Self.sourceToken(for: project)
                let ids = NSScreen.screens.map { DesktopWindowController.displayID(for: $0) }
                displayWallpaperStore.setSource(token, for: ids)
                for displayID in ids {
                    next[displayID] = project
                }
                projectsByDisplayID = next
                return
            } catch {
                NSLog("Wallflow could not load CLI wallpaper: %@", error.localizedDescription)
            }
        }

        for screen in NSScreen.screens {
            let displayID = DesktopWindowController.displayID(for: screen)
            next[displayID] = loadProject(for: displayID)
        }
        projectsByDisplayID = next
    }

    private func loadProject(for displayID: CGDirectDisplayID) -> WallpaperProject {
        guard let source = displayWallpaperStore.source(for: displayID),
              source != DisplayWallpaperStore.builtInToken else {
            return .builtIn
        }
        do {
            return try WallpaperProjectLoader.load(Self.sourceURL(from: source))
        } catch {
            NSLog(
                "Wallflow could not restore wallpaper for display %u: %@",
                displayID,
                error.localizedDescription
            )
            displayWallpaperStore.setBuiltIn(for: displayID)
            return .builtIn
        }
    }

    private func project(for displayID: CGDirectDisplayID) -> WallpaperProject {
        projectsByDisplayID[displayID] ?? loadProject(for: displayID)
    }

    private func focusedDisplayID() -> CGDirectDisplayID {
        if let main = NSScreen.main {
            return DesktopWindowController.displayID(for: main)
        }
        if let first = wallpaperControllers.first {
            return first.displayID
        }
        if let screen = NSScreen.screens.first {
            return DesktopWindowController.displayID(for: screen)
        }
        return 0
    }

    private func syncFocusedProjectState() {
        let displayID = focusedDisplayID()
        currentProject = project(for: displayID)
        currentFitMode = wallpaperLibrary.entry(for: currentProject)?.fitMode ?? .automatic
        currentUserProperties = restoredUserProperties(for: currentProject)
    }

    private func selectProject(
        at url: URL,
        persist: Bool,
        target: DisplayWallpaperTarget
    ) throws {
        let project = try WallpaperProjectLoader.load(url)
        let sourceURL = project.manifestURL ?? project.entryURL ?? url
        let token = sourceURL.isFileURL
            ? sourceURL.standardizedFileURL.path
            : sourceURL.absoluteString
        if persist {
            wallpaperLibrary.install(project: project, sourceURL: sourceURL)
            UserDefaults.standard.set(token, forKey: Self.savedProjectPathKey)
        }
        applyProject(project, sourceToken: token, target: target)
    }

    private func applyBuiltIn(target: DisplayWallpaperTarget) {
        propertiesWindowController?.close()
        propertiesWindowController = nil
        let ids = displayIDs(for: target)
        displayWallpaperStore.setBuiltIn(for: ids)
        for displayID in ids {
            projectsByDisplayID[displayID] = .builtIn
        }
        if case .all = target {
            UserDefaults.standard.removeObject(forKey: Self.savedProjectPathKey)
        }
        rebuildWallpaperWindows()
    }

    private func applyProject(
        _ project: WallpaperProject,
        sourceToken: String,
        target: DisplayWallpaperTarget
    ) {
        propertiesWindowController?.close()
        propertiesWindowController = nil
        let ids = displayIDs(for: target)
        displayWallpaperStore.setSource(sourceToken, for: ids)
        for displayID in ids {
            projectsByDisplayID[displayID] = project
        }
        rebuildWallpaperWindows()
    }

    private func displayIDs(for target: DisplayWallpaperTarget) -> [CGDirectDisplayID] {
        switch target {
        case .all:
            return NSScreen.screens.map { DesktopWindowController.displayID(for: $0) }
        case .display(let id):
            return [id]
        }
    }

    private func importWallpaper(
        from sourceURL: URL,
        persist: Bool,
        target: DisplayWallpaperTarget
    ) {
        projectTitleMenuItem?.title = L10n.text(.importing)
        importService.prepare(sourceURL: sourceURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let preparedURL):
                do {
                    try self.selectProject(at: preparedURL, persist: persist, target: target)
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
        let titles = NSScreen.screens.map { screen -> String in
            let id = DesktopWindowController.displayID(for: screen)
            return L10n.projectTitle(for: project(for: id))
        }
        let unique = Array(Set(titles))
        if unique.count == 1 {
            projectTitleMenuItem?.title = unique[0]
        } else if unique.isEmpty {
            projectTitleMenuItem?.title = L10n.projectTitle(for: .builtIn)
        } else {
            projectTitleMenuItem?.title = L10n.text(.multiDisplayWallpapers)
        }
        propertiesMenuItem?.isEnabled = supportsEditableProperties
        refreshLibraryWindow()
    }

    private func currentDisplayAssignments() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let id = DesktopWindowController.displayID(for: screen)
            if let stored = displayWallpaperStore.source(for: id) {
                result[id] = stored
            } else {
                result[id] = DisplayWallpaperStore.builtInToken
            }
        }
        return result
    }

    private func libraryDisplayOptions() -> [(target: DisplayWallpaperTarget, title: String)] {
        var options: [(DisplayWallpaperTarget, String)] = [
            (.all, L10n.text(.libraryApplyAllDisplays))
        ]
        for (index, screen) in NSScreen.screens.enumerated() {
            let id = DesktopWindowController.displayID(for: screen)
            let name = screen.localizedName
            let title = name.isEmpty
                ? L10n.format(.libraryDisplayIndex, index + 1)
                : name
            options.append((.display(id), title))
        }
        return options
    }

    private static func projectIdentity(_ project: WallpaperProject) -> String {
        sourceToken(for: project)
    }

    private static func sourceToken(for project: WallpaperProject) -> String {
        if project.kind == .builtIn { return DisplayWallpaperStore.builtInToken }
        guard let url = project.manifestURL ?? project.entryURL ?? project.rootURL else {
            return DisplayWallpaperStore.builtInToken
        }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
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
        let token = Self.sourceToken(for: currentProject)
        for controller in wallpaperControllers {
            guard Self.sourceToken(for: project(for: controller.displayID)) == token else {
                continue
            }
            controller.applyUserProperties(changed)
        }
        scheduleFallbackRefresh(delay: 0.35)
    }

    private func updateFitMode(_ fitMode: WallpaperFitMode) {
        guard currentProject.kind != .builtIn else { return }
        currentFitMode = fitMode
        if !wallpaperLibrary.setFitMode(fitMode, for: currentProject),
           let sourceURL = currentProject.manifestURL
            ?? currentProject.entryURL
            ?? currentProject.rootURL {
            wallpaperLibrary.install(project: currentProject, sourceURL: sourceURL)
            wallpaperLibrary.setFitMode(fitMode, for: currentProject)
        }
        let token = Self.sourceToken(for: currentProject)
        for controller in wallpaperControllers {
            guard Self.sourceToken(for: project(for: controller.displayID)) == token else {
                continue
            }
            controller.setFitMode(fitMode)
        }
        refreshLibraryWindow()
        scheduleFallbackRefresh(delay: 0.35)
    }

    private func resetUserProperties() {
        currentFitMode = .automatic
        wallpaperLibrary.setFitMode(.automatic, for: currentProject)
        currentUserProperties = currentProject.userProperties
        if let key = userPropertiesStorageKey(for: currentProject) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let token = Self.sourceToken(for: currentProject)
        for controller in wallpaperControllers {
            guard Self.sourceToken(for: project(for: controller.displayID)) == token else {
                continue
            }
            controller.applyUserProperties(currentUserProperties)
            controller.setFitMode(.automatic)
        }
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

    private func restoreDesktopVisibilityPreference() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.pauseWhenDesktopHiddenKey) != nil {
            pauseWhenDesktopHidden = defaults.bool(
                forKey: Self.pauseWhenDesktopHiddenKey
            )
        }
    }

    private func registerCurrentProjectInLibrary() {
        guard currentProject.kind != .builtIn,
              let sourceURL = currentProject.manifestURL
                ?? currentProject.entryURL
                ?? currentProject.rootURL else {
            return
        }
        wallpaperLibrary.install(project: currentProject, sourceURL: sourceURL)
    }

    private var currentLibraryEntryID: UUID? {
        wallpaperLibrary.entry(for: currentProject)?.id
    }

    private func refreshLibraryWindow() {
        libraryWindowController?.update(
            entries: wallpaperLibrary.entries,
            activeAssignments: currentDisplayAssignments(),
            displayOptions: libraryDisplayOptions(),
            enginePackInstalled: EngineAssetStore.shared.isParticlePackInstalled
        )
    }

    private func importEngineParticlePack() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(.libraryEnginePackTitle)
        alert.informativeText = L10n.text(.libraryEnginePackMessage)
        alert.addButton(withTitle: L10n.text(.choose))
        alert.addButton(withTitle: L10n.text(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text(.importAction)
        panel.message = L10n.text(.libraryEnginePackMessage)
        // Prefer the user's Downloads/particle if present.
        let downloadsParticle = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/particle", isDirectory: true)
        if FileManager.default.fileExists(atPath: downloadsParticle.path) {
            panel.directoryURL = downloadsParticle.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let installed = try EngineAssetStore.shared.installParticlePack(from: url)
            // Rebuild scene controllers so particles pick up the new textures.
            rebuildWallpaperWindows()
            refreshLibraryWindow()
            let done = NSAlert()
            done.alertStyle = .informational
            done.messageText = L10n.text(.libraryEnginePackInstalled)
            done.informativeText = installed.path
            done.addButton(withTitle: "OK")
            done.runModal()
            NSLog("Wallflow installed engine particle pack at %@", installed.path)
        } catch {
            showError(error)
        }
    }

    private func activateLibraryEntry(
        _ entry: WallpaperLibraryEntry?,
        target: DisplayWallpaperTarget
    ) {
        guard let entry else {
            applyBuiltIn(target: target)
            return
        }
        do {
            try selectProject(at: entry.sourceURL, persist: true, target: target)
        } catch {
            showError(error)
        }
    }

    private func confirmLibraryRemoval(_ entry: WallpaperLibraryEntry) {
        let isManaged = wallpaperLibrary.isManaged(entry)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.libraryRemoveTitle(entry.title)
        alert.informativeText = L10n.text(
            isManaged ? .libraryRemoveManagedMessage : .libraryRemoveReferenceMessage
        )
        alert.addButton(withTitle: L10n.text(.libraryRemove))
        alert.addButton(withTitle: L10n.text(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasCurrent = currentLibraryEntryID == entry.id
        do {
            try wallpaperLibrary.remove(entry, deleteManagedFiles: isManaged)
            if wasCurrent {
                useBuiltInWallpaper()
            }
            refreshLibraryWindow()
        } catch {
            showError(error)
        }
    }

    private func locateUnavailableLibraryEntry(_ entry: WallpaperLibraryEntry) {
        guard let sourceURL = chooseWallpaperSource() else { return }
        projectTitleMenuItem?.title = L10n.text(.importing)
        importService.prepare(sourceURL: sourceURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let preparedURL):
                do {
                    try self.selectProject(
                        at: preparedURL,
                        persist: true,
                        target: .all
                    )
                    try self.wallpaperLibrary.remove(entry, deleteManagedFiles: false)
                    self.refreshLibraryWindow()
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

    private func chooseWallpaperSource() -> URL? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L10n.text(.openPanelTitle)
        panel.message = L10n.text(.openPanelMessage)
        panel.prompt = L10n.text(.openPanelPrompt)
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
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
        currentProject.kind != .builtIn
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Keep checkbox state in sync every time the status menu opens.
        pauseMenuItem?.title = isManuallyPaused
            ? L10n.text(.resumeAnimation)
            : L10n.text(.pauseAnimation)
        desktopHiddenPauseMenuItem?.state = pauseWhenDesktopHidden ? .on : .off
        muteMenuItem?.title = isAudioMuted
            ? L10n.text(.unmuteAudio)
            : L10n.text(.muteAudio)
        propertiesMenuItem?.isEnabled = supportsEditableProperties
    }
}
