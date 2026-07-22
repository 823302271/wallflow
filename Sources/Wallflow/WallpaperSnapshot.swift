import AppKit
import Metal

enum WallpaperSnapshot {
    static func preparedImage(from image: NSImage) -> NSImage? {
        var sourceRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &sourceRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        return NSImage(
            cgImage: source,
            size: NSSize(width: source.width, height: source.height)
        )
    }

    static func pngData(from image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    static func pngData(from cgImage: CGImage) -> Data? {
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .png,
            properties: [:]
        )
    }

    static func image(fromBGRA8 texture: MTLTexture) -> NSImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [
                    CGBitmapInfo.byteOrder32Little,
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                ],
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: width, height: height)
        )
    }
}
