import Foundation

struct SystemSuspensionState {
    enum Reason: String, CaseIterable, Hashable {
        case systemSleep
        case screensSleep
        case sessionInactive
        case screenLocked
    }

    private(set) var activeReasons: Set<Reason> = []

    var isSuspended: Bool {
        !activeReasons.isEmpty
    }

    var description: String {
        activeReasons
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    @discardableResult
    mutating func set(_ reason: Reason, active: Bool) -> Bool {
        if active {
            return activeReasons.insert(reason).inserted
        }
        return activeReasons.remove(reason) != nil
    }
}
