import AppKit

enum WallpaperSnapshot {
    private static let maximumPixelSize = CGSize(width: 1920, height: 1080)

    static func preparedImage(from image: NSImage) -> NSImage? {
        var sourceRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &sourceRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }

        let scale = min(
            1,
            maximumPixelSize.width / CGFloat(source.width),
            maximumPixelSize.height / CGFloat(source.height)
        )
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return nil }
        return NSImage(
            cgImage: result,
            size: NSSize(width: width, height: height)
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
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .png,
            properties: [:]
        )
    }
}
