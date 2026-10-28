#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct CodexTaskActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var detail: String
        public var progress: Double?
        public var state: String
        public var pendingApprovalCount: Int
        public var updatedAt: Date

        public init(
            title: String,
            detail: String,
            progress: Double?,
            state: String,
            pendingApprovalCount: Int,
            updatedAt: Date
        ) {
            self.title = title
            self.detail = detail
            self.progress = progress
            self.state = state
            self.pendingApprovalCount = pendingApprovalCount
            self.updatedAt = updatedAt
        }
    }

    public var taskID: String

    public init(taskID: String) {
        self.taskID = taskID
    }
}
#endif
