import CoreGraphics
import Foundation

/// Runs WindowServer enumeration and coverage geometry away from the main thread.
final class DesktopCoverageSampler {
    private let queue = DispatchQueue(
        label: "dev.wallflow.desktop-coverage",
        qos: .utility
    )

    private struct Request {
        let bounds: [CGDirectDisplayID: CGRect]
        let completion: (Set<CGDirectDisplayID>) -> Void
    }
    private var pending: [Request] = []
    private var isSampling = false

    func sample(
        screenBoundsByDisplay: [CGDirectDisplayID: CGRect],
        completion: @escaping (Set<CGDirectDisplayID>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending.append(Request(bounds: screenBoundsByDisplay, completion: completion))
        guard !isSampling else { return }
        isSampling = true
        // Collect same-turn probes across all displays into one WindowServer read.
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        let requests = pending
        pending.removeAll(keepingCapacity: true)
        queue.async {
            let windows = DesktopVisibility.visibleApplicationWindowBounds()
            let results = requests.map {
                Self.hiddenDisplayIDs(screenBoundsByDisplay: $0.bounds, windowBounds: windows)
            }
            DispatchQueue.main.async {
                for (request, result) in zip(requests, results) {
                    request.completion(result)
                }
                if self.pending.isEmpty {
                    self.isSampling = false
                } else {
                    self.drain()
                }
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
