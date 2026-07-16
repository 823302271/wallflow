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
        try testWebManifest()
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
        try """
        { "file": "scene.pkg", "type": "scene", "title": "Scene Fixture" }
        """.write(
            to: directory.appendingPathComponent("project.json"),
            atomically: true,
            encoding: .utf8
        )

        let project = try WallpaperProjectLoader.load(directory)
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
