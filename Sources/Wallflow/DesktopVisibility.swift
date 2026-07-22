import AppKit
import CoreGraphics
import Foundation

enum DesktopVisibility {
    /// Application windows that can cover the desktop wallpaper.
    /// Uses Quartz global coordinates (same as `CGDisplayBounds` / `CGWindowList`).
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
        // Layer 0 is normal app content. Full-screen and some utility windows can sit
        // slightly above 0 but still fully cover the desktop; ignore menu bar / dock
        // (typically 20+) and screensaver layers.
        let maxCoveringLayer = 15
        return windowInfo.compactMap { info in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard ownerPID != ownPID,
                  let layer,
                  layer >= 0,
                  layer <= maxCoveringLayer,
                  alpha > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }
            return bounds
        }
    }

    /// Quartz bounds of the usable desktop on a display (menu bar / dock excluded when present).
    static func desktopQuartzBounds(
        displayID: CGDirectDisplayID,
        screen: NSScreen
    ) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID)
        // Prefer converting the Cocoa visibleFrame into Quartz space so multi-monitor
        // layouts (above/below/primary offset) stay correct on secondary displays.
        let visible = quartzRect(fromCocoaRect: screen.visibleFrame)
        let intersection = visible.intersection(displayBounds)
        if intersection.isNull || intersection.width < 8 || intersection.height < 8 {
            return displayBounds
        }
        return intersection
    }

    /// Convert a Cocoa global rect (bottom-left origin) to Quartz global rect (top-left origin).
    static func quartzRect(fromCocoaRect rect: CGRect) -> CGRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.origin.x,
            y: mainHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    static func isDisplayHidden(
        _ screenBounds: CGRect,
        by windowBounds: [CGRect],
        coverageThreshold: CGFloat = 0.985
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
