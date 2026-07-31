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

    /// Whether a wallpaper click/feed should be delivered at this Quartz point.
    /// Ignores desktop chrome (Finder desktop shell, Dock, menu extras) that would
    /// otherwise make the entire desktop look "covered" and block left-click feeds.
    static func isDesktopExposed(at quartzPoint: CGPoint) -> Bool {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowInfo = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // Fail open: better to deliver a feed click than never receive one.
            return true
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenBounds = NSScreen.screens.map { desktopQuartzBounds(for: $0) }
        let coveringBounds = windowInfo.compactMap { info -> CGRect? in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard ownerPID != ownPID,
                  let layer,
                  layer >= 0,
                  // Menus / Dock / overlays sit above normal app content.
                  layer <= 15,
                  alpha > 0.05,
                  !isWallpaperInputIgnoredOwner(owner),
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.width > 2,
                  bounds.height > 2 else {
                return nil
            }
            // Finder (and similar) keep a full-display shell window for icons.
            // It covers empty desktop pixels too and must not block wallpaper clicks.
            if isLikelyDesktopShellWindow(owner: owner, bounds: bounds, screens: screenBounds) {
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

    /// AppKit global (bottom-left) → Quartz global (top-left of primary).
    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first(where: {
            $0.frame.origin == .zero
        })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func desktopQuartzBounds(for screen: NSScreen) -> CGRect {
        let id = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value ?? 0
        return desktopQuartzBounds(displayID: CGDirectDisplayID(id), screen: screen)
    }

    private static func isWallpaperInputIgnoredOwner(_ owner: String) -> Bool {
        let ignored: Set<String> = [
            "Dock",
            "Control Center",
            "Notification Center",
            "SystemUIServer",
            "Window Server",
            "Spotlight",
            "TextInputMenuAgent",
            "TextInputSwitcher",
            "loginwindow",
            "Wallpaper",
            "Wallpapers"
        ]
        return ignored.contains(owner)
    }

    private static func isLikelyDesktopShellWindow(
        owner: String,
        bounds: CGRect,
        screens: [CGRect]
    ) -> Bool {
        // Full-display Finder windows are the desktop/icon surface, not apps.
        guard owner == "Finder" else { return false }
        return screens.contains { screen in
            abs(bounds.width - screen.width) < 4
                && abs(bounds.height - screen.height) < 80
                && abs(bounds.minX - screen.minX) < 4
                && abs(bounds.minY - screen.minY) < 80
        }
    }
}
