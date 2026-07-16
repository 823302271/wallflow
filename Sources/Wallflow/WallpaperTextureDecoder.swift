import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct WallpaperAnimationFrame {
    let image: CGImage
    let duration: TimeInterval
}

struct WallpaperTexture {
    let images: [CGImage]
    let textureWidth: Int
    let textureHeight: Int
    let imageWidth: Int
    let imageHeight: Int
    let isSprite: Bool
    let animationFrames: [WallpaperAnimationFrame]

    var image: CGImage { images[0] }
}

enum WallpaperTextureError: LocalizedError, Equatable {
    case truncated
    case invalidMagic(String)
    case invalidValue(String)
    case unsupportedFormat(Int)
    case unsupportedEmbeddedFormat(Int)
    case decompressionFailed
    case imageDecodeFailed

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "The Wallpaper Engine texture is truncated."
        case .invalidMagic(let magic):
            return "Unsupported Wallpaper Engine texture section: \(magic)."
        case .invalidValue(let name):
            return "The Wallpaper Engine texture has an invalid \(name)."
        case .unsupportedFormat(let format):
            return "Wallpaper Engine texture format \(format) is not supported."
        case .unsupportedEmbeddedFormat(let format):
            return "Embedded Wallpaper Engine image format \(format) is not supported."
        case .decompressionFailed:
            return "Wallpaper Engine LZ4 texture decompression failed."
        case .imageDecodeFailed:
            return "The decoded Wallpaper Engine texture could not be converted to an image."
        }
    }
}

enum WallpaperTextureDecoder {
    private static let maximumPayloadSize = 512 * 1024 * 1024

    static func decode(_ data: Data) throws -> WallpaperTexture {
        var cursor = TextureBinaryCursor(data: data)
        let texVersion = try cursor.readCString(maximumLength: 16)
        guard texVersion == "TEXV0005" else {
            throw WallpaperTextureError.invalidMagic(texVersion)
        }
        let imageVersion = try cursor.readCString(maximumLength: 16)
        guard imageVersion == "TEXI0001" else {
            throw WallpaperTextureError.invalidMagic(imageVersion)
        }

        let format = try cursor.readInt32()
        let flags = UInt32(bitPattern: Int32(try cursor.readInt32()))
        let textureWidth = try cursor.readDimension("texture width")
        let textureHeight = try cursor.readDimension("texture height")
        let imageWidth = try cursor.readDimension("image width")
        let imageHeight = try cursor.readDimension("image height")
        _ = try cursor.readInt32()

        let bodyMagic = try cursor.readCString(maximumLength: 16)
        guard bodyMagic.hasPrefix("TEXB"),
              let bodyVersion = Int(bodyMagic.dropFirst(4)),
              (1...4).contains(bodyVersion) else {
            throw WallpaperTextureError.invalidMagic(bodyMagic)
        }

        let imageCount = try cursor.readInt32()
        guard (1...512).contains(imageCount) else {
            throw WallpaperTextureError.invalidValue("image count")
        }

        var embeddedFormat = -1
        if bodyVersion >= 3 {
            embeddedFormat = try cursor.readInt32()
        }
        if bodyVersion >= 4 {
            _ = try cursor.readInt32()
        }

        let isSprite = flags & (1 << 2) != 0
        var decodedImages: [CGImage] = []
        decodedImages.reserveCapacity(imageCount)

        for _ in 0..<imageCount {
            let mipmapCount = try cursor.readInt32()
            guard (1...64).contains(mipmapCount) else {
                throw WallpaperTextureError.invalidValue("mipmap count")
            }

            var firstImage: CGImage?
            for mipmapIndex in 0..<mipmapCount {
                let mipWidth = try cursor.readDimension("mipmap width")
                let mipHeight = try cursor.readDimension("mipmap height")
                var isLZ4Compressed = false
                var decompressedSize = 0
                if bodyVersion >= 2 {
                    isLZ4Compressed = try cursor.readInt32() == 1
                    decompressedSize = try cursor.readInt32()
                    guard decompressedSize >= 0, decompressedSize <= maximumPayloadSize else {
                        throw WallpaperTextureError.invalidValue("decompressed size")
                    }
                }

                let payloadSize = try cursor.readInt32()
                guard payloadSize > 0, payloadSize <= maximumPayloadSize else {
                    throw WallpaperTextureError.invalidValue("payload size")
                }

                if mipmapIndex == 0 {
                    var payload = try cursor.readData(count: payloadSize)
                    if isLZ4Compressed {
                        payload = try LZ4BlockDecoder.decode(
                            payload,
                            expectedSize: decompressedSize
                        )
                    }
                    var image = try decodePayload(
                        payload,
                        format: format,
                        embeddedFormat: embeddedFormat,
                        width: mipWidth,
                        height: mipHeight
                    )
                    if !isSprite {
                        image = try cropImage(
                            image,
                            width: min(max(imageWidth, 1), image.width),
                            height: min(max(imageHeight, 1), image.height)
                        )
                    }
                    firstImage = image
                } else {
                    try cursor.skip(count: payloadSize)
                }
            }

            guard let firstImage else {
                throw WallpaperTextureError.imageDecodeFailed
            }
            decodedImages.append(firstImage)
        }

        let animationFrames: [WallpaperAnimationFrame]
        if isSprite {
            animationFrames = try decodeSpriteFrames(
                cursor: &cursor,
                images: decodedImages
            )
        } else {
            animationFrames = []
        }

        return WallpaperTexture(
            images: decodedImages,
            textureWidth: textureWidth,
            textureHeight: textureHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            isSprite: isSprite,
            animationFrames: animationFrames
        )
    }

    private static func decodePayload(
        _ payload: Data,
        format: Int,
        embeddedFormat: Int,
        width: Int,
        height: Int
    ) throws -> CGImage {
        if embeddedFormat >= 0 || detectedEmbeddedImage(payload) {
            guard embeddedFormat != 35 else {
                throw WallpaperTextureError.unsupportedEmbeddedFormat(embeddedFormat)
            }
            return try decodeImageContainer(payload)
        }
        return try decodeRawTexture(payload, format: format, width: width, height: height)
    }

    private static func decodeSpriteFrames(
        cursor: inout TextureBinaryCursor,
        images: [CGImage]
    ) throws -> [WallpaperAnimationFrame] {
        let spriteMagic = try cursor.readCString(maximumLength: 16)
        guard spriteMagic.hasPrefix("TEXS"),
              let spriteVersion = Int(spriteMagic.dropFirst(4)),
              (1...3).contains(spriteVersion) else {
            throw WallpaperTextureError.invalidMagic(spriteMagic)
        }

        let frameCount = try cursor.readInt32()
        guard (1...100_000).contains(frameCount) else {
            throw WallpaperTextureError.invalidValue("sprite frame count")
        }
        if spriteVersion >= 3 {
            _ = try cursor.readDimension("sprite atlas width")
            _ = try cursor.readDimension("sprite atlas height")
        }

        var frames: [WallpaperAnimationFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let imageIndex = try cursor.readInt32()
            let duration = max(TimeInterval(try cursor.readFloat32()), 1.0 / 240.0)
            let values: [Double]
            if spriteVersion == 1 {
                values = try (0..<6).map { _ in Double(try cursor.readInt32()) }
            } else {
                values = try (0..<6).map { _ in Double(try cursor.readFloat32()) }
            }

            guard images.indices.contains(imageIndex) else {
                continue
            }
            let frame = try makeSpriteFrame(
                source: images[imageIndex],
                x: values[0],
                y: values[1],
                widthX: values[2],
                widthY: values[3],
                heightX: values[4],
                heightY: values[5]
            )
            frames.append(WallpaperAnimationFrame(image: frame, duration: duration))
        }
        return frames
    }

    private static func makeSpriteFrame(
        source: CGImage,
        x: Double,
        y: Double,
        widthX: Double,
        widthY: Double,
        heightX: Double,
        heightY: Double
    ) throws -> CGImage {
        let signedWidth = widthX != 0 ? widthX : heightX
        let signedHeight = heightY != 0 ? heightY : widthY
        let cropX = min(x, x + signedWidth)
        let cropYFromTop = min(y, y + signedHeight)
        let cropWidth = abs(signedWidth)
        let cropHeight = abs(signedHeight)
        guard cropWidth >= 1, cropHeight >= 1 else {
            throw WallpaperTextureError.invalidValue("sprite frame bounds")
        }

        let cropRect = CGRect(
            x: max(0, cropX),
            y: max(0, Double(source.height) - cropYFromTop - cropHeight),
            width: min(cropWidth, Double(source.width) - max(0, cropX)),
            height: min(
                cropHeight,
                Double(source.height) - max(0, Double(source.height) - cropYFromTop - cropHeight)
            )
        ).integral
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else {
            throw WallpaperTextureError.imageDecodeFailed
        }

        let heightSign = signedHeight < 0 ? -1.0 : 1.0
        let widthSign = signedWidth < 0 ? -1.0 : 1.0
        let rotation = -(atan2(heightSign, widthSign) - .pi / 4)
        guard abs(rotation) > 0.001 else { return cropped }

        let transformed = CIImage(cgImage: cropped)
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(rotation)))
        let normalized = transformed.transformed(
            by: CGAffineTransform(
                translationX: -transformed.extent.minX,
                y: -transformed.extent.minY
            )
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rotated = context.createCGImage(normalized, from: normalized.extent) else {
            throw WallpaperTextureError.imageDecodeFailed
        }
        return rotated
    }

    private static func cropImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        if width == image.width, height == image.height { return image }
        guard let cropped = image.cropping(
            to: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            throw WallpaperTextureError.imageDecodeFailed
        }
        return cropped
    }

    private static func detectedEmbeddedImage(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.count >= 8,
           Array(data.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] {
            return true
        }
        if data.count >= 3, data[0] == 0xff, data[1] == 0xd8, data[2] == 0xff {
            return true
        }
        if data.count >= 6,
           String(data: data.prefix(6), encoding: .ascii)?.hasPrefix("GIF") == true {
            return true
        }
        if data.count >= 2, data[0] == 0x42, data[1] == 0x4d {
            return true
        }
        if data.count >= 12,
           String(data: data.prefix(4), encoding: .ascii) == "RIFF",
           String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" {
            return true
        }
        if data.count >= 4,
           ((data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2a && data[3] == 0x00)
            || (data[0] == 0x4d && data[1] == 0x4d && data[2] == 0x00 && data[3] == 0x2a)) {
            return true
        }
        if data.count >= 12,
           String(data: data.subdata(in: 4..<8), encoding: .ascii) == "ftyp" {
            return true
        }
        return false
    }

    private static func decodeImageContainer(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WallpaperTextureError.imageDecodeFailed
        }
        return image
    }

    private static func decodeRawTexture(
        _ data: Data,
        format: Int,
        width: Int,
        height: Int
    ) throws -> CGImage {
        switch format {
        case 0:
            guard data.count >= width * height * 4 else {
                throw WallpaperTextureError.truncated
            }
            return try makeRGBAImage(Data(data.prefix(width * height * 4)), width: width, height: height)
        case 8:
            guard data.count >= width * height * 2 else {
                throw WallpaperTextureError.truncated
            }
            var rgba = Data(count: width * height * 4)
            rgba.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    guard let outputBase = output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let inputBase = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for pixel in 0..<(width * height) {
                        outputBase[pixel * 4] = inputBase[pixel * 2]
                        outputBase[pixel * 4 + 1] = inputBase[pixel * 2 + 1]
                        outputBase[pixel * 4 + 2] = 0
                        outputBase[pixel * 4 + 3] = 255
                    }
                }
            }
            return try makeRGBAImage(rgba, width: width, height: height)
        case 9:
            guard data.count >= width * height else {
                throw WallpaperTextureError.truncated
            }
            guard let provider = CGDataProvider(data: Data(data.prefix(width * height)) as CFData),
                  let image = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else {
                throw WallpaperTextureError.imageDecodeFailed
            }
            return image
        case 4, 6, 7:
            return try decodeDDS(data, format: format, width: width, height: height)
        default:
            throw WallpaperTextureError.unsupportedFormat(format)
        }
    }

    private static func makeRGBAImage(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.last.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw WallpaperTextureError.imageDecodeFailed
        }
        return image
    }

    private static func decodeDDS(
        _ data: Data,
        format: Int,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let fourCC: [UInt8]
        switch format {
        case 4: fourCC = Array("DXT5".utf8)
        case 6: fourCC = Array("DXT3".utf8)
        case 7: fourCC = Array("DXT1".utf8)
        default: throw WallpaperTextureError.unsupportedFormat(format)
        }

        var dds = Data("DDS ".utf8)
        appendUInt32(124, to: &dds)
        appendUInt32(0x0008_1007, to: &dds)
        appendUInt32(UInt32(height), to: &dds)
        appendUInt32(UInt32(width), to: &dds)
        appendUInt32(UInt32(data.count), to: &dds)
        appendUInt32(0, to: &dds)
        appendUInt32(1, to: &dds)
        for _ in 0..<11 { appendUInt32(0, to: &dds) }
        appendUInt32(32, to: &dds)
        appendUInt32(0x4, to: &dds)
        dds.append(contentsOf: fourCC)
        for _ in 0..<5 { appendUInt32(0, to: &dds) }
        appendUInt32(0x1000, to: &dds)
        for _ in 0..<4 { appendUInt32(0, to: &dds) }
        dds.append(data)

        return try decodeImageContainer(dds)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}

private struct TextureBinaryCursor {
    let data: Data
    var offset = 0

    mutating func readInt32() throws -> Int {
        guard offset <= data.count - 4 else { throw WallpaperTextureError.truncated }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return Int(Int32(bitPattern: value))
    }

    mutating func readFloat32() throws -> Float {
        guard offset <= data.count - 4 else { throw WallpaperTextureError.truncated }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return Float(bitPattern: value)
    }

    mutating func readDimension(_ name: String) throws -> Int {
        let value = try readInt32()
        guard (1...16_384).contains(value) else {
            throw WallpaperTextureError.invalidValue(name)
        }
        return value
    }

    mutating func readCString(maximumLength: Int) throws -> String {
        let start = offset
        while offset < data.count, offset - start <= maximumLength {
            if data[offset] == 0 {
                let bytes = data.subdata(in: start..<offset)
                offset += 1
                guard let value = String(data: bytes, encoding: .ascii) else {
                    throw WallpaperTextureError.invalidMagic("non-ASCII")
                }
                return value
            }
            offset += 1
        }
        throw WallpaperTextureError.truncated
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw WallpaperTextureError.truncated
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func skip(count: Int) throws {
        guard count >= 0, offset <= data.count - count else {
            throw WallpaperTextureError.truncated
        }
        offset += count
    }
}

private enum LZ4BlockDecoder {
    static func decode(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            throw WallpaperTextureError.decompressionFailed
        }

        let source = [UInt8](input)
        var sourceIndex = 0
        var output = [UInt8]()
        output.reserveCapacity(expectedSize)

        while sourceIndex < source.count {
            let token = source[sourceIndex]
            sourceIndex += 1

            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                literalLength += try readExtendedLength(source, index: &sourceIndex)
            }
            guard sourceIndex <= source.count - literalLength,
                  output.count <= expectedSize - literalLength else {
                throw WallpaperTextureError.decompressionFailed
            }
            output.append(contentsOf: source[sourceIndex..<(sourceIndex + literalLength)])
            sourceIndex += literalLength

            if sourceIndex == source.count { break }
            guard sourceIndex <= source.count - 2 else {
                throw WallpaperTextureError.decompressionFailed
            }
            let matchOffset = Int(source[sourceIndex]) | (Int(source[sourceIndex + 1]) << 8)
            sourceIndex += 2
            guard matchOffset > 0, matchOffset <= output.count else {
                throw WallpaperTextureError.decompressionFailed
            }

            var matchLength = Int(token & 0x0f) + 4
            if token & 0x0f == 15 {
                matchLength += try readExtendedLength(source, index: &sourceIndex)
            }
            guard output.count <= expectedSize - matchLength else {
                throw WallpaperTextureError.decompressionFailed
            }

            for _ in 0..<matchLength {
                output.append(output[output.count - matchOffset])
            }
        }

        guard output.count == expectedSize else {
            throw WallpaperTextureError.decompressionFailed
        }
        return Data(output)
    }

    private static func readExtendedLength(
        _ source: [UInt8],
        index: inout Int
    ) throws -> Int {
        var result = 0
        while true {
            guard index < source.count else {
                throw WallpaperTextureError.decompressionFailed
            }
            let value = Int(source[index])
            index += 1
            result += value
            if value != 255 { return result }
        }
    }
}
