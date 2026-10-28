import Foundation

/// Keep one stable task on the system surfaces instead of replacing the Live
/// Activity whenever another running thread receives a newer timestamp.
public enum TaskLiveActivityPolicy {
    public struct ExistingActivity: Equatable, Sendable {
        public var id: String
        public var taskID: String

        public init(id: String, taskID: String) {
            self.id = id
            self.taskID = taskID
        }
    }

    public static func task(
        in snapshot: DashboardSnapshot,
        preferredTaskID: String?
    ) -> AgentTask? {
        guard snapshot.bridgeConnected else { return nil }
        let active = snapshot.tasks.filter {
            !$0.isChat && !$0.isNativeChat && $0.isInProgress
                && AgentTaskPresentation.isVisible($0)
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        let waiting = active.filter { $0.state == .waitingForApproval || $0.awaitingUserInput == true }
        let candidates = waiting.isEmpty ? active : waiting
        return candidates.first { $0.id == preferredTaskID } ?? candidates.first
    }

    /// Reconcile all system activities, including leftovers from previous
    /// versions/processes. Only this app's typed ActivityKit activities enter.
    public static func retainedActivityID(
        in activities: [ExistingActivity],
        taskID: String?,
        preferredActivityID: String?
    ) -> String? {
        guard let taskID else { return nil }
        let matching = activities.filter { $0.taskID == taskID }
        return matching.first { $0.id == preferredActivityID }?.id
            ?? matching.map(\.id).sorted().first
    }

    public static func title(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func progress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
