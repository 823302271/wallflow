import AppKit
import Foundation

enum WallflowSelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

enum WallflowSelfTest {
    static func run() throws {
        try testLocalizationResources()
        try testWallpaperSnapshotPreservesResolution()
        try testDesktopVisibilityRules()
        try testIncomingApplicationCoverage()
        try testDesktopCoverageSamplerIsolation()
        try testDisplayVisibilityProbeIsolation()
        try testSystemSuspensionState()
        try testDisplayWallpaperSourceMigration()
        try testLocalWallpaperImportIsPersistent()
        try testWallpaperLibrary()
        try testWebManifest()
        try testCanvasMetalSelection()
        try testRemoteWebProject()
        try testVideoProjects()
        try testUnsafeManifestEntry()
        try testScenePackageAndDocument()
        try testUnsafePackagePath()
        try testInvalidPackageRange()
        try testRawRGBATexture()
        try testLZ4Texture()
        try testEmbeddedPNGTexture()
        try testDXTTextures()
        try testSpriteTexture()
        try testSceneViewBuildsImageLayer()
    }

    private static func testLocalizationResources() throws {
        try expect(
            L10n.text(.openWallpaper, language: .english) == "Open Wallpaper...",
            "English localization resource was not loaded"
        )
        try expect(
            L10n.text(.openWallpaper, language: .simplifiedChinese) == "打开壁纸...",
            "Simplified Chinese localization resource was not loaded"
        )
        try expect(
            L10n.text(
                .pauseWhenDesktopHidden,
                language: .simplifiedChinese
            ) == "桌面不可见时暂停",
            "Desktop visibility localization resource was not loaded"
        )
        try expect(
            L10n.format(
                .propertiesWindowTitle,
                language: .simplifiedChinese,
                "Koi Pond"
            ) == "Koi Pond 属性",
            "Localized format string was not resolved"
        )
    }

    private static func testWallpaperSnapshotPreservesResolution() throws {
        let width = 2560
        let height = 1600
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let source = context.makeImage() else {
            throw WallflowSelfTestError.failed("Could not create snapshot fixture")
        }
        let image = NSImage(
            cgImage: source,
            size: NSSize(width: width, height: height)
        )
        guard let prepared = WallpaperSnapshot.preparedImage(from: image) else {
            throw WallflowSelfTestError.failed("Wallpaper snapshot preparation failed")
        }
        var proposedRect = CGRect(origin: .zero, size: prepared.size)
        let preparedImage = prepared.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
        try expect(
            preparedImage?.width == width && preparedImage?.height == height,
            "Wallpaper snapshot resolution was reduced"
        )
    }

    private static func testDesktopVisibilityRules() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        try expect(
            DesktopVisibility.isDisplayHidden(
                screen,
                by: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
            ),
            "A full-screen window did not hide the desktop"
        )
        try expect(
            !DesktopVisibility.isDisplayHidden(
                screen,
                by: [
                    CGRect(x: 0, y: 0, width: 600, height: 900),
                    CGRect(x: 620, y: 100, width: 380, height: 800)
                ]
            ),
            "Normal application windows incorrectly hid the desktop"
        )
        try expect(
            DesktopVisibility.isDisplayHidden(
                screen,
                by: [
                    CGRect(x: 0, y: 0, width: 1000, height: 100),
                    CGRect(x: 0, y: 100, width: 1000, height: 900)
                ]
            ),
            "Fragmented full-screen application windows did not hide the desktop"
        )
        try expect(
            !DesktopVisibility.isDisplayHidden(
                screen,
                by: [
                    CGRect(x: 0, y: 0, width: 1000, height: 600),
                    CGRect(x: 0, y: 0, width: 1000, height: 600)
                ]
            ),
            "Overlapping windows were counted more than once"
        )
        let applicationWindow = CGRect(x: 100, y: 100, width: 500, height: 500)
        try expect(
            !DesktopVisibility.isDesktopExposed(
                at: CGPoint(x: 200, y: 200),
                coveredBy: [applicationWindow]
            ),
            "A click over an application window reached the desktop"
        )
        try expect(
            DesktopVisibility.isDesktopExposed(
                at: CGPoint(x: 800, y: 800),
                coveredBy: [applicationWindow]
            ),
            "A click on exposed desktop was incorrectly blocked"
        )
        // Full-display shell windows (Finder desktop) must not block wallpaper feeds.
        try expect(
            DesktopVisibility.isDesktopExposed(
                at: CGPoint(x: 100, y: 100),
                coveredBy: []
            ),
            "Empty cover list should expose the desktop"
        )
    }

    private static func testIncomingApplicationCoverage() throws {
        let mainDisplay = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondaryDisplay = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let coveringMain = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let coveringSecondary = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let smallOnMain = CGRect(x: 40, y: 40, width: 320, height: 240)

        try expect(
            DesktopVisibility.shouldFreezeForIncomingApplication(
                screenBounds: mainDisplay,
                onScreenWindowBounds: [coveringMain],
                allWindowBounds: [coveringMain]
            ),
            "An on-screen maximized window did not freeze the desktop"
        )
        try expect(
            DesktopVisibility.shouldFreezeForIncomingApplication(
                screenBounds: mainDisplay,
                onScreenWindowBounds: [],
                allWindowBounds: [coveringMain]
            ),
            "Dock-clicking a maximized window on another Space did not freeze"
        )
        try expect(
            !DesktopVisibility.shouldFreezeForIncomingApplication(
                screenBounds: mainDisplay,
                onScreenWindowBounds: [smallOnMain],
                allWindowBounds: [smallOnMain, coveringMain]
            ),
            "A normal window froze the desktop because the same app has a full-screen window elsewhere"
        )
        try expect(
            DesktopVisibility.shouldFreezeForIncomingApplication(
                screenBounds: secondaryDisplay,
                onScreenWindowBounds: [],
                allWindowBounds: [coveringSecondary]
            ),
            "An incoming covering window on the secondary display was ignored"
        )
        try expect(
            !DesktopVisibility.shouldFreezeForIncomingApplication(
                screenBounds: mainDisplay,
                onScreenWindowBounds: [],
                allWindowBounds: [coveringSecondary]
            ),
            "A covering window on the secondary display froze the main display"
        )
        try expect(
            DesktopVisibility.hasSignificantWindow(
                in: [smallOnMain],
                on: mainDisplay
            ),
            "A visible application window was not treated as significant"
        )
        try expect(
            !DesktopVisibility.hasSignificantWindow(
                in: [CGRect(x: 10, y: 10, width: 20, height: 20)],
                on: mainDisplay
            ),
            "A tiny palette was treated as a significant window"
        )
    }

    private static func testDesktopCoverageSamplerIsolation() throws {
        let mainDisplay: CGDirectDisplayID = 1
        let secondaryDisplay: CGDirectDisplayID = 2
        let mainBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondaryBounds = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let hiddenDisplayIDs = DesktopCoverageSampler.hiddenDisplayIDs(
            screenBoundsByDisplay: [
                mainDisplay: mainBounds,
                secondaryDisplay: secondaryBounds
            ],
            windowBounds: [secondaryBounds]
        )
        try expect(
            hiddenDisplayIDs == Set([secondaryDisplay]),
            "Secondary coverage incorrectly marked the main display hidden"
        )
    }

    private static func testDisplayVisibilityProbeIsolation() throws {
        let mainDisplay: CGDirectDisplayID = 1
        let secondaryDisplay: CGDirectDisplayID = 3
        var state = DisplayVisibilityProbeState()

        let mainGeneration = try expectValue(
            state.begin(for: mainDisplay),
            "Main display visibility probe did not start"
        )
        try expect(
            state.begin(for: mainDisplay) == nil,
            "Watchdog restarted an in-flight main display visibility probe"
        )
        let secondaryGeneration = try expectValue(
            state.begin(for: secondaryDisplay),
            "Secondary display visibility probe did not start independently"
        )
        state.cancel(for: mainDisplay)
        try expect(
            !state.isCurrent(mainGeneration, for: mainDisplay),
            "Canceled main display visibility probe remained current"
        )
        try expect(
            state.finish(secondaryGeneration, for: secondaryDisplay),
            "Secondary display visibility probe was invalidated by the main display"
        )
        // A finished probe must be re-armable, otherwise a display that resumed
        // once could never be probed again.
        try expect(
            state.begin(for: secondaryDisplay) != nil,
            "Finished visibility probe blocked the next probe on that display"
        )
    }

    private static func testSystemSuspensionState() throws {
        var state = SystemSuspensionState()
        try expect(!state.isSuspended, "System suspension started active")

        try expect(
            state.set(.screenLocked, active: true) && state.isSuspended,
            "Screen lock did not suspend rendering"
        )
        _ = state.set(.systemSleep, active: true)
        _ = state.set(.screensSleep, active: true)
        _ = state.set(.systemSleep, active: false)
        _ = state.set(.screensSleep, active: false)
        try expect(
            state.isSuspended,
            "Wake notifications resumed rendering while the screen was still locked"
        )

        _ = state.set(.sessionInactive, active: true)
        _ = state.set(.screenLocked, active: false)
        try expect(
            state.isSuspended,
            "Unlock resumed rendering before the user session became active"
        )
        _ = state.set(.sessionInactive, active: false)
        try expect(
            !state.isSuspended,
            "Rendering did not resume after every suspension reason cleared"
        )
    }

    private static func testDisplayWallpaperSourceMigration() throws {
        let suiteName = "WallflowDisplayMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw WallflowSelfTestError.failed("Could not create display migration defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mainDisplay: CGDirectDisplayID = 11
        let secondaryDisplay: CGDirectDisplayID = 22
        let untouchedDisplay: CGDirectDisplayID = 33
        let oldSource = "/tmp/external/project.json"
        let managedSource = "/tmp/managed/project.json"
        let untouchedSource = "/tmp/other/project.json"
        let store = DisplayWallpaperStore(defaults: defaults)
        store.setSource(oldSource, for: [mainDisplay, secondaryDisplay])
        store.setSource(untouchedSource, for: untouchedDisplay)

        let changed = store.replaceSource(oldSource, with: managedSource)
        try expect(
            Set(changed) == Set([mainDisplay, secondaryDisplay]),
            "External wallpaper assignments were not migrated together"
        )
        let reloaded = DisplayWallpaperStore(defaults: defaults)
        try expect(
            reloaded.source(for: mainDisplay) == managedSource
                && reloaded.source(for: secondaryDisplay) == managedSource,
            "Managed wallpaper assignments were not persisted"
        )
        try expect(
            reloaded.source(for: untouchedDisplay) == untouchedSource,
            "Unrelated display assignment changed during migration"
        )
    }

    private static func testLocalWallpaperImportIsPersistent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appendingPathComponent("Source", isDirectory: true)
        let importedRoot = directory.appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        try "<!doctype html><title>Persistent</title>".write(
            to: sourceRoot.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { "file": "index.html", "type": "web", "title": "Persistent Import" }
        """.write(
            to: sourceRoot.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = WallpaperImportService(importedRootURL: importedRoot)
        let installedURL = try service.installLocalProject(sourceRoot)
        try expect(
            installedURL.standardizedFileURL.path.hasPrefix(
                importedRoot.standardizedFileURL.path + "/"
            ),
            "Local wallpaper was not copied into Wallflow storage"
        )
        try FileManager.default.removeItem(at: sourceRoot)
        let project = try WallpaperProjectLoader.load(installedURL)
        try expect(
            project.displayTitle == "Persistent Import",
            "Installed wallpaper depended on its deleted source"
        )
    }

    private static func testWallpaperLibrary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importedRoot = directory.appendingPathComponent("Imported", isDirectory: true)
        let installRoot = importedRoot.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        try "<!doctype html>".write(
            to: installRoot.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { "file": "index.html", "type": "web", "title": "Library Fixture" }
        """.write(
            to: installRoot.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let suiteName = "WallflowTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw WallflowSelfTestError.failed("Could not create library test defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = WallpaperLibrary(
            defaults: defaults,
            importedRootURL: importedRoot
        )
        try expect(library.entries.count == 1, "Managed wallpaper was not discovered")
        let entry = try expectValue(
            library.entries.first,
            "Managed wallpaper library entry was missing"
        )
        try expect(entry.title == "Library Fixture", "Wallpaper title was not persisted")
        try expect(library.isManaged(entry), "Managed wallpaper was classified as external")
        try expect(entry.fitMode == .automatic, "New wallpaper did not default to automatic fit")

        try expect(
            library.setFitMode(.fit, for: try WallpaperProjectLoader.load(installRoot)),
            "Wallpaper fit mode could not be updated"
        )

        let reloaded = WallpaperLibrary(
            defaults: defaults,
            importedRootURL: importedRoot
        )
        try expect(reloaded.entries.count == 1, "Wallpaper library entry was duplicated")
        try expect(
            reloaded.entries.first?.fitMode == .fit,
            "Wallpaper fit mode was not persisted"
        )

        let legacyData = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "source": "/tmp/legacy/project.json",
              "title": "Legacy",
              "kind": "web",
              "addedAt": 0
            }
            """.utf8
        )
        let legacyEntry = try JSONDecoder().decode(
            WallpaperLibraryEntry.self,
            from: legacyData
        )
        try expect(
            legacyEntry.fitMode == .automatic,
            "Legacy wallpaper entry did not migrate to automatic fit"
        )
        try reloaded.remove(entry, deleteManagedFiles: true)
        try expect(
            !FileManager.default.fileExists(atPath: installRoot.path),
            "Managed wallpaper files were not removed"
        )

        let externalRoot = directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        try "<!doctype html><title>Legacy</title>".write(
            to: externalRoot.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { "file": "index.html", "type": "web", "title": "Legacy External" }
        """.write(
            to: externalRoot.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )
        let externalProject = try WallpaperProjectLoader.load(externalRoot)
        let externalSource = externalProject.manifestURL ?? externalRoot
        let externalEntry = reloaded.install(
            project: externalProject,
            sourceURL: externalSource
        )
        try expect(
            reloaded.externalLocalEntries.map(\.id).contains(externalEntry.id),
            "External local wallpaper was not selected for migration"
        )
        try expect(
            reloaded.setFitMode(.fill, for: externalProject),
            "External wallpaper fit mode could not be set"
        )

        let importService = WallpaperImportService(importedRootURL: importedRoot)
        let managedURL = try importService.installLocalProject(externalRoot)
        let managedProject = try WallpaperProjectLoader.load(managedURL)
        let managedSource = managedProject.manifestURL ?? managedProject.entryURL ?? managedURL
        let entryBeforeReplacement = try expectValue(
            reloaded.entries.first(where: { $0.id == externalEntry.id }),
            "External wallpaper disappeared before migration"
        )
        let migratedEntry = try expectValue(
            reloaded.replace(
                entryBeforeReplacement,
                with: managedProject,
                sourceURL: managedSource
            ),
            "External wallpaper library entry was not replaced"
        )
        try expect(
            migratedEntry.id == externalEntry.id && migratedEntry.fitMode == .fill,
            "Wallpaper identity or display mode changed during migration"
        )
        try expect(
            reloaded.isManaged(migratedEntry),
            "Migrated wallpaper was not classified as managed"
        )

        try FileManager.default.removeItem(at: externalRoot)
        _ = try WallpaperProjectLoader.load(migratedEntry.sourceURL)
        let migratedReload = WallpaperLibrary(
            defaults: defaults,
            importedRootURL: importedRoot
        )
        try expect(
            migratedReload.entries.count == 1
                && migratedReload.entries.first?.id == externalEntry.id
                && migratedReload.entries.first?.fitMode == .fill,
            "Migrated wallpaper metadata was not preserved after reload"
        )
    }

    private static func testRemoteWebProject() throws {
        let url = URL(string: "https://example.com/wallpaper/index.html")!
        let project = try WallpaperProjectLoader.load(url)
        try expect(project.kind == .web, "Remote web project kind was not detected")
        try expect(project.entryURL == url, "Remote web entry URL was not preserved")
        try expect(project.rootURL == nil, "Remote web project unexpectedly has a local root")
    }

    private static func testVideoProjects() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("wallflow-test.mp4")
        try Data().write(to: videoURL)
        let directProject = try WallpaperProjectLoader.load(videoURL)
        try expect(directProject.kind == .video, "Local MP4 project kind was not detected")
        try expect(directProject.entryURL == videoURL, "Local MP4 entry URL was not preserved")

        let remoteURL = URL(string: "https://example.com/wallpaper/demo.mp4")!
        let remoteProject = try WallpaperProjectLoader.load(remoteURL)
        try expect(remoteProject.kind == .video, "Remote MP4 project kind was not detected")

        try """
        { "file": "wallflow-test.mp4", "type": "video", "title": "Video Fixture" }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )
        let manifestProject = try WallpaperProjectLoader.load(directory)
        try expect(manifestProject.kind == .video, "Video manifest kind was not detected")
        try expect(manifestProject.displayTitle == "Video Fixture", "Video title was not decoded")
    }

    private static func testWebManifest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "<!doctype html><canvas></canvas>".write(
            to: directory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "file": "index.html",
          "type": "web",
          "title": "Web Fixture",
          "general": {
            "properties": {
              "speed": { "type": "slider", "value": 2 }
            }
          }
        }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let project = try WallpaperProjectLoader.load(directory)
        try expect(project.kind == .web, "Web project kind was not detected")
        try expect(project.displayTitle == "Web Fixture", "Web project title was not decoded")
        try expect(
            project.userProperties.objectValue?["speed"]?.objectValue?["value"]
                == .number(2),
            "Web user property defaults were not decoded"
        )
    }

    private static func testCanvasMetalSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        <!doctype html><canvas id="wallpaper"></canvas><script src="wallpaper.js"></script>
        """.write(
            to: directory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        const canvas = document.getElementById('wallpaper');
        const ctx = canvas.getContext('2d');
        function draw() {
          ctx.clearRect(0, 0, innerWidth, innerHeight);
          ctx.beginPath();
          ctx.arc(40, 40, 20, 0, Math.PI * 2);
          ctx.fillStyle = '#fff';
          ctx.fill();
          requestAnimationFrame(draw);
        }
        requestAnimationFrame(draw);
        """.write(
            to: directory.appendingPathComponent("wallpaper.js"),
            atomically: true,
            encoding: .utf8
        )
        try """
        { "file": "index.html", "type": "web", "title": "Canvas Fixture" }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let project = try WallpaperProjectLoader.load(directory)
        try expect(
            CanvasMetalProgramLoader.load(project: project) != nil,
            "Compatible Canvas wallpaper did not select Metal"
        )

        try "ctx.drawImage(image, 0, 0);".write(
            to: directory.appendingPathComponent("wallpaper.js"),
            atomically: true,
            encoding: .utf8
        )
        try expect(
            CanvasMetalProgramLoader.load(project: project) == nil,
            "Unsupported Canvas wallpaper did not fall back to WebKit"
        )
    }

    private static func testUnsafeManifestEntry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outsideURL = directory.deletingLastPathComponent().appendingPathComponent(
            "wallflow-outside-\(UUID().uuidString).html"
        )
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)
        try """
        { "file": "../\(outsideURL.lastPathComponent)", "type": "web" }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try WallpaperProjectLoader.load(directory)
            throw WallflowSelfTestError.failed("Unsafe manifest entry was accepted")
        } catch WallpaperProjectLoaderError.entryOutsideProject {
            return
        }
    }

    private static func testScenePackageAndDocument() throws {
        let sceneJSON = Data(
            """
            {
              "version": 7,
              "general": {
                "clearcolor": [0.1, 0.2, 0.3],
                "cameraparallax": true,
                "cameraparallaxamount": 0.4,
                "cameraparallaxdelay": 0.12,
                "cameraparallaxmouseinfluence": 0.8,
                "orthogonalprojection": { "width": 1920, "height": 1080 }
              },
              "objects": [
                { "image": "models/background.json" },
                { "particle": "particles/sparks.json" },
                {
                  "id": 9,
                  "name": "Loop",
                  "sound": ["sounds/loop.mp3"],
                  "playbackmode": "loop",
                  "volume": 0.5,
                  "startsilent": true
                }
              ]
            }
            """.utf8
        )
        let imageJSON = Data(
            """
            { "width": 1920, "height": 1080, "material": "materials/background.json" }
            """.utf8
        )
        let materialJSON = Data(
            """
            { "shader": "genericimage2", "textures": ["background"] }
            """.utf8
        )
        let textureData = makeTexture(
            format: 0,
            bodyVersion: 1,
            width: 1,
            height: 1,
            payload: Data([255, 0, 0, 255])
        )
        let package = try ScenePackage(
            data: makePackage(
                version: "PKGV0020",
                entries: [
                    ("scene.json", sceneJSON),
                    ("models/background.json", imageJSON),
                    ("materials/background.json", materialJSON),
                    ("materials/background.tex", textureData)
                ]
            )
        )
        let document = try SceneDocument(package: package)

        try expect(package.version == "PKGV0020", "Package version was not decoded")
        try expect(package.entries.count == 4, "Package entry table was not decoded")
        try expect(
            try package.data(forPath: "/models/background.json") == imageJSON,
            "Package entry data did not round-trip"
        )
        try expect(document.sceneVersion == 7, "Scene JSON version was not decoded")
        try expect(document.general.cameraParallax, "Scene camera parallax was not decoded")
        try expect(document.compatibility.imageObjects == 1, "Image objects were not counted")
        try expect(document.compatibility.particleObjects == 1, "Particles were not counted")
        try expect(document.compatibility.soundObjects == 1, "Sounds were not counted")
        try expect(document.sounds.count == 1, "Scene sound object was not parsed")
        try expect(
            document.sounds[0].paths == ["sounds/loop.mp3"],
            "Scene sound paths were not parsed"
        )
        try expect(document.sounds[0].volume == 0.5, "Scene sound volume was not parsed")
        try expect(document.imageLayers.count == 1, "Scene image layer was not resolved")
        try expect(
            document.imageLayers.first?.texturePath == "/materials/background.tex",
            "Scene material texture path was not resolved"
        )

        // Workshop-style packaging: string vectors + material.passes textures.
        let workshopScene = Data(
            """
            {
              "general": {
                "clearcolor": "0.7 0.7 0.7",
                "orthogonalprojection": { "width": 5120, "height": 2880 }
              },
              "objects": [
                {
                  "id": 16,
                  "image": "models/pc.json",
                  "origin": "2560.0 1440.0 0.0",
                  "size": "5120.0 2880.0",
                  "scale": "1 1 1"
                }
              ]
            }
            """.utf8
        )
        let workshopModel = Data(
            """
            { "autosize": true, "material": "materials/pc.json" }
            """.utf8
        )
        let workshopMaterial = Data(
            """
            {
              "passes": [
                { "shader": "genericimage4", "textures": ["pc"] }
              ]
            }
            """.utf8
        )
        let workshopPackage = try ScenePackage(
            data: makePackage(
                version: "PKGV0021",
                entries: [
                    ("scene.json", workshopScene),
                    ("models/pc.json", workshopModel),
                    ("materials/pc.json", workshopMaterial),
                    ("materials/pc.tex", textureData)
                ]
            )
        )
        let workshopDocument = try SceneDocument(package: workshopPackage)
        try expect(
            workshopDocument.imageLayers.count == 1,
            "Workshop-style scene image layer was not resolved"
        )
        try expect(
            abs((workshopDocument.imageLayers.first?.width ?? 0) - 5120) < 0.1,
            "Workshop scene object size string was not parsed"
        )
        try expect(
            workshopDocument.imageLayers.first?.texturePath == "/materials/pc.tex",
            "Workshop material passes texture was not resolved"
        )
        try expect(
            abs((workshopDocument.general.clearColor.first ?? 0) - 0.7) < 0.01,
            "Workshop clearcolor string was not parsed"
        )

        // Mouse-petal style particle system (control-point flags + passes material).
        let petalScene = Data(
            """
            {
              "general": { "orthogonalprojection": { "width": 1000, "height": 1000 } },
              "objects": [
                {
                  "id": 71,
                  "particle": "particles/petals.json",
                  "origin": "500 500 0",
                  "visible": { "user": "newproperty", "value": true }
                }
              ]
            }
            """.utf8
        )
        let petalSystem = Data(
            """
            {
              "controlpoint": [{ "flags": 1, "id": 0, "offset": "0 0 0" }],
              "emitter": [{ "name": "sphererandom", "rate": 20, "distancemax": 32, "distancemin": 0 }],
              "initializer": [
                { "name": "lifetimerandom", "min": 2, "max": 4 },
                { "name": "sizerandom", "min": 36, "max": 72 },
                { "name": "velocityrandom", "min": "-100 -100 0", "max": "50 50 0" },
                { "name": "colorrandom", "min": "255 132 241", "max": "255 255 255" }
              ],
              "material": "materials/particle/halo_3.json",
              "maxcount": 100,
              "operator": [
                { "name": "movement", "drag": 0.4 },
                { "name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.1 }
              ],
              "starttime": 0
            }
            """.utf8
        )
        let petalMaterial = Data(
            """
            { "passes": [{ "shader": "genericparticle", "textures": ["particle/nature/rosepetals"] }] }
            """.utf8
        )
        let petalPackage = try ScenePackage(
            data: makePackage(
                version: "PKGV0021",
                entries: [
                    ("scene.json", petalScene),
                    ("particles/petals.json", petalSystem),
                    ("materials/particle/halo_3.json", petalMaterial)
                ]
            )
        )
        let petalDocument = try SceneDocument(package: petalPackage)
        try expect(
            petalDocument.particleSystems.count == 1,
            "Mouse petal particle system was not parsed"
        )
        try expect(
            petalDocument.particleSystems[0].followMouse,
            "Particle control-point flags did not enable mouse follow"
        )
        try expect(
            petalDocument.particleSystems[0].visibility.userPropertyKey == "newproperty",
            "Particle user-property visibility was not parsed"
        )
    }

    private static func testUnsafePackagePath() throws {
        do {
            _ = try ScenePackage(
                data: makePackage(
                    version: "PKGV0005",
                    entries: [("../scene.json", Data("{}".utf8))]
                )
            )
            throw WallflowSelfTestError.failed("Unsafe scene package path was accepted")
        } catch ScenePackageError.invalidPath("../scene.json") {
            return
        }
    }

    private static func testInvalidPackageRange() throws {
        var data = Data()
        appendString("PKGV0005", to: &data)
        appendInt32(1, to: &data)
        appendString("scene.json", to: &data)
        appendInt32(999, to: &data)
        appendInt32(4, to: &data)

        do {
            _ = try ScenePackage(data: data)
            throw WallflowSelfTestError.failed("Out-of-range scene package entry was accepted")
        } catch ScenePackageError.invalidRange("/scene.json") {
            return
        }
    }

    private static func testRawRGBATexture() throws {
        let texture = try WallpaperTextureDecoder.decode(
            makeTexture(
                format: 0,
                bodyVersion: 1,
                width: 2,
                height: 1,
                payload: Data([255, 0, 0, 255, 0, 255, 0, 255])
            )
        )
        try expect(texture.image.width == 2, "Raw RGBA texture width was incorrect")
        try expect(texture.image.height == 1, "Raw RGBA texture height was incorrect")
        let representation = NSBitmapImageRep(cgImage: texture.image)
        try expect(
            (representation.colorAt(x: 0, y: 0)?.redComponent ?? 0) > 0.9,
            "Raw RGBA texture channel order was incorrect"
        )
    }

    private static func testLZ4Texture() throws {
        let raw = Data([10, 20, 30, 255])
        var literalBlock = Data([0x40])
        literalBlock.append(raw)
        let texture = try WallpaperTextureDecoder.decode(
            makeTexture(
                format: 0,
                bodyVersion: 2,
                width: 1,
                height: 1,
                payload: literalBlock,
                lz4DecompressedSize: raw.count
            )
        )
        try expect(texture.image.width == 1, "LZ4 texture did not decode")
    }

    private static func testEmbeddedPNGTexture() throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        )!
        bitmap.setColor(
            NSColor(calibratedRed: 0.1, green: 0.7, blue: 0.6, alpha: 1),
            atX: 0,
            y: 0
        )
        let png = try expectValue(
            bitmap.representation(using: .png, properties: [:]),
            "Could not create PNG texture fixture"
        )
        let texture = try WallpaperTextureDecoder.decode(
            makeTexture(
                format: 0,
                bodyVersion: 3,
                width: 1,
                height: 1,
                payload: png,
                embeddedFormat: 13
            )
        )
        try expect(texture.image.width == 1, "Embedded PNG texture did not decode")
    }

    private static func testDXTTextures() throws {
        let colorBlock: [UInt8] = [
            0x00, 0xf8,
            0xe0, 0x07,
            0x00, 0x00, 0x00, 0x00
        ]
        let fixtures: [(Int, Data, String)] = [
            (7, Data(colorBlock), "DXT1"),
            (6, Data(repeating: 0xff, count: 8) + Data(colorBlock), "DXT3"),
            (
                4,
                Data([255, 0, 0, 0, 0, 0, 0, 0]) + Data(colorBlock),
                "DXT5"
            )
        ]

        for (format, payload, name) in fixtures {
            let texture = try WallpaperTextureDecoder.decode(
                makeTexture(
                    format: format,
                    bodyVersion: 1,
                    width: 4,
                    height: 4,
                    payload: payload
                )
            )
            try expect(texture.image.width == 4, "\(name) texture did not decode")
            try expect(texture.image.height == 4, "\(name) texture height was incorrect")
        }
    }

    private static func testSpriteTexture() throws {
        let texture = try WallpaperTextureDecoder.decode(makeSpriteTexture())
        try expect(texture.isSprite, "Sprite texture flag was not decoded")
        try expect(texture.animationFrames.count == 2, "Sprite frame table was not decoded")
        try expect(
            abs(texture.animationFrames[0].duration - 0.1) < 0.001,
            "Sprite frame duration was incorrect"
        )

        let first = NSBitmapImageRep(cgImage: texture.animationFrames[0].image)
        let second = NSBitmapImageRep(cgImage: texture.animationFrames[1].image)
        try expect(
            (first.colorAt(x: 0, y: 0)?.redComponent ?? 0) > 0.9,
            "First sprite frame crop was incorrect"
        )
        try expect(
            (second.colorAt(x: 0, y: 0)?.greenComponent ?? 0) > 0.9,
            "Second sprite frame crop was incorrect"
        )
    }

    private static func testSceneViewBuildsImageLayer() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sceneJSON = Data(
            """
            {
              "general": {
                "clearcolor": [0, 0, 0],
                "cameraparallax": true,
                "orthogonalprojection": { "width": 4, "height": 4 }
              },
              "objects": [
                {
                  "id": 1,
                  "name": "Fixture Layer",
                  "image": "models/fixture.json",
                  "origin": [2, 2, 0],
                  "scale": [1, 1, 1],
                  "angles": [0, 0, 0]
                }
              ]
            }
            """.utf8
        )
        let descriptor = Data(
            """
            { "width": 4, "height": 4, "material": "materials/fixture.json" }
            """.utf8
        )
        let material = Data(
            """
            { "shader": "genericimage2", "textures": ["fixture"] }
            """.utf8
        )
        let texture = makeSpriteTexture()
        let package = makePackage(
            version: "PKGV0020",
            entries: [
                ("scene.json", sceneJSON),
                ("models/fixture.json", descriptor),
                ("materials/fixture.json", material),
                ("materials/fixture.tex", texture)
            ]
        )
        try package.write(to: directory.appendingPathComponent("scene.pkg"))
        // Wallpaper Engine workshop projects declare scene.json while the bytes
        // live in scene.pkg — the loader must resolve that packaging layout.
        try """
        { "file": "scene.json", "type": "Scene", "title": "Scene Fixture" }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let project = try WallpaperProjectLoader.load(directory)
        try expect(
            project.kind == .scene,
            "Scene project with capitalised type was not recognised"
        )
        try expect(
            project.entryURL?.lastPathComponent == "scene.pkg",
            "Scene project did not resolve scene.json to scene.pkg"
        )
        let view = SceneWallpaperView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180),
            desktopFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            project: project,
            playsAudio: false
        )
        view.layoutSubtreeIfNeeded()
        defer { view.setRenderingEnabled(false) }

        let contentLayers = view.layer?.sublayers?.filter {
            !$0.isHidden && $0.contents != nil
        } ?? []
        try expect(contentLayers.count == 1, "Scene view did not build a texture layer")
        try expect(
            contentLayers[0].animation(forKey: "wallflow.sprite") != nil,
            "Scene view did not attach sprite animation"
        )
        view.setRenderingEnabled(false)
        try expect(view.layer?.speed == 0, "Scene animations did not pause")
        view.setRenderingEnabled(true)
        // Resume deliberately starts on the next run-loop turn so the host can
        // drop its freeze overlay while the layer is still on the pause frame.
        let deadline = Date().addingTimeInterval(0.5)
        while (view.layer?.speed ?? 0) != 1, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try expect(view.layer?.speed == 1, "Scene animations did not resume")
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw WallflowSelfTestError.failed(message)
        }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw WallflowSelfTestError.failed(message) }
        return value
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func makePackage(
        version: String,
        entries: [(String, Data)]
    ) -> Data {
        var data = Data()
        appendString(version, to: &data)
        appendInt32(entries.count, to: &data)

        var offset = 0
        for (path, bytes) in entries {
            appendString(path, to: &data)
            appendInt32(offset, to: &data)
            appendInt32(bytes.count, to: &data)
            offset += bytes.count
        }
        for (_, bytes) in entries {
            data.append(bytes)
        }
        return data
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendInt32(bytes.count, to: &data)
        data.append(bytes)
    }

    private static func appendInt32(_ value: Int, to data: inout Data) {
        let unsigned = UInt32(bitPattern: Int32(value))
        data.append(UInt8(unsigned & 0xff))
        data.append(UInt8((unsigned >> 8) & 0xff))
        data.append(UInt8((unsigned >> 16) & 0xff))
        data.append(UInt8((unsigned >> 24) & 0xff))
    }

    private static func appendCString(_ value: String, to data: inout Data) {
        data.append(Data(value.utf8))
        data.append(0)
    }

    private static func appendFloat32(_ value: Float, to data: inout Data) {
        let bits = value.bitPattern
        data.append(UInt8(bits & 0xff))
        data.append(UInt8((bits >> 8) & 0xff))
        data.append(UInt8((bits >> 16) & 0xff))
        data.append(UInt8((bits >> 24) & 0xff))
    }

    private static func makeTexture(
        format: Int,
        bodyVersion: Int,
        width: Int,
        height: Int,
        payload: Data,
        lz4DecompressedSize: Int? = nil,
        embeddedFormat: Int = -1
    ) -> Data {
        var data = Data()
        appendCString("TEXV0005", to: &data)
        appendCString("TEXI0001", to: &data)
        appendInt32(format, to: &data)
        appendInt32(0, to: &data)
        appendInt32(width, to: &data)
        appendInt32(height, to: &data)
        appendInt32(width, to: &data)
        appendInt32(height, to: &data)
        appendInt32(0, to: &data)
        appendCString(String(format: "TEXB%04d", bodyVersion), to: &data)
        appendInt32(1, to: &data)
        if bodyVersion >= 3 {
            appendInt32(embeddedFormat, to: &data)
        }
        if bodyVersion >= 4 {
            appendInt32(0, to: &data)
        }
        appendInt32(1, to: &data)
        appendInt32(width, to: &data)
        appendInt32(height, to: &data)
        if bodyVersion >= 2 {
            appendInt32(lz4DecompressedSize == nil ? 0 : 1, to: &data)
            appendInt32(lz4DecompressedSize ?? payload.count, to: &data)
        }
        appendInt32(payload.count, to: &data)
        data.append(payload)
        return data
    }

    private static func makeSpriteTexture() -> Data {
        var data = Data()
        appendCString("TEXV0005", to: &data)
        appendCString("TEXI0001", to: &data)
        appendInt32(0, to: &data)
        appendInt32(1 << 2, to: &data)
        appendInt32(2, to: &data)
        appendInt32(1, to: &data)
        appendInt32(1, to: &data)
        appendInt32(1, to: &data)
        appendInt32(0, to: &data)
        appendCString("TEXB0001", to: &data)
        appendInt32(1, to: &data)
        appendInt32(1, to: &data)
        appendInt32(2, to: &data)
        appendInt32(1, to: &data)
        let atlas = Data([255, 0, 0, 255, 0, 255, 0, 255])
        appendInt32(atlas.count, to: &data)
        data.append(atlas)

        appendCString("TEXS0003", to: &data)
        appendInt32(2, to: &data)
        appendInt32(2, to: &data)
        appendInt32(1, to: &data)
        appendSpriteFrame(x: 0, duration: 0.1, to: &data)
        appendSpriteFrame(x: 1, duration: 0.2, to: &data)
        return data
    }

    private static func appendSpriteFrame(
        x: Float,
        duration: Float,
        to data: inout Data
    ) {
        appendInt32(0, to: &data)
        appendFloat32(duration, to: &data)
        appendFloat32(x, to: &data)
        appendFloat32(0, to: &data)
        appendFloat32(1, to: &data)
        appendFloat32(0, to: &data)
        appendFloat32(0, to: &data)
        appendFloat32(1, to: &data)
    }
}
