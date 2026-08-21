import CoreGraphics
import Foundation

/// Runs WindowServer enumeration and coverage geometry away from the main thread.
final class DesktopCoverageSampler {
    private let queue = DispatchQueue(
        label: "dev.wallflow.desktop-coverage",
        qos: .utility
    )

    func sample(
        screenBoundsByDisplay: [CGDirectDisplayID: CGRect],
        completion: @escaping (Set<CGDirectDisplayID>) -> Void
    ) {
        queue.async {
            let windowBounds = DesktopVisibility.visibleApplicationWindowBounds()
            let hiddenDisplayIDs = Self.hiddenDisplayIDs(
                screenBoundsByDisplay: screenBoundsByDisplay,
                windowBounds: windowBounds
            )
            DispatchQueue.main.async {
                completion(hiddenDisplayIDs)
            }
        }
    }

    static func hiddenDisplayIDs(
        screenBoundsByDisplay: [CGDirectDisplayID: CGRect],
        windowBounds: [CGRect]
    ) -> Set<CGDirectDisplayID> {
        Set(screenBoundsByDisplay.compactMap { displayID, screenBounds in
            DesktopVisibility.isDisplayHidden(screenBounds, by: windowBounds)
                ? displayID
                : nil
        })
    }
}
