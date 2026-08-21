import CoreGraphics

/// Owns one in-flight desktop-visibility probe per physical display.
///
/// Probes confirm a coverage change over several consecutive samples, so a
/// repeated request (watchdog tick, app activation) must join the probe that is
/// already running instead of restarting it — otherwise a display whose probe is
/// slower than the polling interval never reaches a decision.
struct DisplayVisibilityProbeState {
    private var pendingDisplayIDs: Set<CGDirectDisplayID> = []
    private var generations: [CGDirectDisplayID: Int] = [:]

    mutating func begin(for displayID: CGDirectDisplayID) -> Int? {
        guard pendingDisplayIDs.insert(displayID).inserted else { return nil }
        let generation = (generations[displayID] ?? 0) + 1
        generations[displayID] = generation
        return generation
    }

    mutating func cancel(for displayID: CGDirectDisplayID) {
        pendingDisplayIDs.remove(displayID)
        generations[displayID, default: 0] += 1
    }

    func isCurrent(_ generation: Int, for displayID: CGDirectDisplayID) -> Bool {
        pendingDisplayIDs.contains(displayID)
            && generations[displayID] == generation
    }

    mutating func finish(_ generation: Int, for displayID: CGDirectDisplayID) -> Bool {
        guard isCurrent(generation, for: displayID) else { return false }
        pendingDisplayIDs.remove(displayID)
        return true
    }

    mutating func clear() {
        pendingDisplayIDs.removeAll()
        generations.removeAll()
    }

    mutating func retain(displayIDs: Set<CGDirectDisplayID>) {
        pendingDisplayIDs.formIntersection(displayIDs)
        generations = generations.filter { displayIDs.contains($0.key) }
    }
}
