import CoreGraphics
import Foundation

/// Tracks Space-transition quiet windows independently for each physical display.
struct DisplaySpaceTransitionState {
    private var holdUntilByDisplayID: [CGDirectDisplayID: TimeInterval] = [:]
    private var generationByDisplayID: [CGDirectDisplayID: Int] = [:]

    mutating func begin(
        for displayID: CGDirectDisplayID,
        now: TimeInterval,
        quietPeriod: TimeInterval
    ) -> Int {
        let generation = (generationByDisplayID[displayID] ?? 0) + 1
        generationByDisplayID[displayID] = generation
        holdUntilByDisplayID[displayID] = now + quietPeriod
        return generation
    }

    func isQuiet(for displayID: CGDirectDisplayID, now: TimeInterval) -> Bool {
        now < (holdUntilByDisplayID[displayID] ?? 0)
    }

    func generation(for displayID: CGDirectDisplayID) -> Int {
        generationByDisplayID[displayID] ?? 0
    }

    mutating func clear() {
        holdUntilByDisplayID.removeAll()
        generationByDisplayID.removeAll()
    }

    mutating func retain(displayIDs: Set<CGDirectDisplayID>) {
        holdUntilByDisplayID = holdUntilByDisplayID.filter {
            displayIDs.contains($0.key)
        }
        generationByDisplayID = generationByDisplayID.filter {
            displayIDs.contains($0.key)
        }
    }
}
