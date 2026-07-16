import CoreGraphics
import Foundation

enum DesktopVisibility {
    static func visibleApplicationWindowBounds() -> [CGRect] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windowInfo.compactMap { info in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard ownerPID != ownPID,
                  layer == 0,
                  alpha > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }
            return CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        }
    }

    static func isDisplayHidden(
        _ screenBounds: CGRect,
        by windowBounds: [CGRect],
        coverageThreshold: CGFloat = 0.97
    ) -> Bool {
        let screenArea = screenBounds.width * screenBounds.height
        guard screenArea > 0 else { return false }
        let clippedBounds = windowBounds.compactMap { bounds -> CGRect? in
            let intersection = bounds.intersection(screenBounds)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0 else {
                return nil
            }
            return intersection
        }
        guard !clippedBounds.isEmpty else { return false }

        let xCoordinates = Set(
            clippedBounds.flatMap { [$0.minX, $0.maxX] }
        ).sorted()
        var coveredArea: CGFloat = 0

        for (left, right) in zip(xCoordinates, xCoordinates.dropFirst()) {
            let width = right - left
            guard width > 0 else { continue }
            let intervals = clippedBounds.compactMap { bounds -> ClosedRange<CGFloat>? in
                guard bounds.minX < right, bounds.maxX > left else { return nil }
                return bounds.minY...bounds.maxY
            }
            .sorted { $0.lowerBound < $1.lowerBound }
            guard var current = intervals.first else { continue }
            var coveredHeight: CGFloat = 0

            for interval in intervals.dropFirst() {
                if interval.lowerBound <= current.upperBound {
                    current = current.lowerBound...max(
                        current.upperBound,
                        interval.upperBound
                    )
                } else {
                    coveredHeight += current.upperBound - current.lowerBound
                    current = interval
                }
            }
            coveredHeight += current.upperBound - current.lowerBound
            coveredArea += width * coveredHeight

            if coveredArea / screenArea >= coverageThreshold {
                return true
            }
        }
        return false
    }

    static func isDesktopExposed(at quartzPoint: CGPoint) -> Bool {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let coveringBounds = windowInfo.compactMap { info -> CGRect? in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard ownerPID != ownPID,
                  let layer,
                  layer >= 0,
                  alpha > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return nil
            }
            return bounds
        }
        return isDesktopExposed(at: quartzPoint, coveredBy: coveringBounds)
    }

    static func isDesktopExposed(
        at point: CGPoint,
        coveredBy windowBounds: [CGRect]
    ) -> Bool {
        !windowBounds.contains { $0.contains(point) }
    }
}
