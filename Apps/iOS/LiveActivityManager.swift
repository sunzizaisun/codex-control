@preconcurrency import ActivityKit
import Foundation
import CodexWatchCore

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<CodexTaskActivityAttributes>?
    private var pendingSnapshot: DashboardSnapshot?
    private var updateTask: Task<Void, Never>?
    private var lastAppliedSnapshot: DashboardSnapshot?
    private var lastAppliedAt = Date.distantPast

    private init() {
        activity = Activity<CodexTaskActivityAttributes>.activities.first
    }

    func update(from snapshot: DashboardSnapshot) {
        // Renew an unchanged running activity before its stale date. Suppress
        // high-frequency heartbeats between renewals, not the heartbeat itself.
        if updateTask == nil, let lastAppliedSnapshot,
           lastAppliedSnapshot.isVisuallyEquivalent(to: snapshot),
           Date().timeIntervalSince(lastAppliedAt) < 5 * 60 {
            return
        }
        pendingSnapshot = snapshot
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while let pending = pendingSnapshot {
                pendingSnapshot = nil
                await apply(pending)
            }
            updateTask = nil
        }
    }

    /// One serialized writer prevents rapid snapshots from creating multiple
    /// activities while the previous asynchronous end is still in flight.
    private func apply(_ snapshot: DashboardSnapshot) async {
        #if targetEnvironment(simulator)
        defer { recordLayoutRegressionInventory() }
        #endif
        let task = TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: activity?.attributes.taskID)
        let existing = Activity<CodexTaskActivityAttributes>.activities
        let resumable = existing.filter { $0.activityState == .active || $0.activityState == .stale }
        let retainedID = TaskLiveActivityPolicy.retainedActivityID(
            in: resumable.map { .init(id: $0.id, taskID: $0.attributes.taskID) },
            taskID: task?.id,
            preferredActivityID: activity?.id
        )
        activity = resumable.first { $0.id == retainedID }
        // Updating just `activities.first` left old/ended cards on the Lock
        // Screen and mirrored Smart Stack. Reconcile every owned activity.
        for obsolete in existing where obsolete.id != retainedID {
            await obsolete.end(nil, dismissalPolicy: .immediate)
        }
        let pendingApprovalCount = snapshot.pendingApprovals.filter { !$0.isExpired }.count
        guard let task else {
            markApplied(snapshot)
            return
        }

        let state = CodexTaskActivityAttributes.ContentState(
            title: TaskLiveActivityPolicy.title(task.title),
            detail: task.awaitingUserInput == true ? AppLocalizer.text("等待你的回复") : stateLabel(task.state),
            progress: TaskLiveActivityPolicy.progress(task.progress),
            state: task.state.rawValue,
            pendingApprovalCount: pendingApprovalCount,
            updatedAt: task.updatedAt
        )
        // The Mac bridge posts every few seconds while it is running.  A longer
        // stale date prevents the Watch mirror disappearing during a normal
        // iPhone background interval.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))

        if let activity, activity.attributes.taskID == task.id {
            await activity.update(content)
            markApplied(snapshot)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: CodexTaskActivityAttributes(taskID: task.id),
            content: content,
            pushType: nil
        )
        // Authorization denial and creation failures are not applied updates.
        // Allow the next heartbeat to retry instead of suppressing it for 5m.
        if activity != nil { markApplied(snapshot) }
    }

    private func markApplied(_ snapshot: DashboardSnapshot) {
        lastAppliedSnapshot = snapshot
        lastAppliedAt = Date()
    }

    #if targetEnvironment(simulator)
    /// Exercise real ActivityKit reconciliation in the isolated QA simulator,
    /// not in physical-device builds and never against production conversations.
    func seedLayoutRegressionActivities() async {
        guard ProcessInfo.processInfo.arguments.contains("-UIPreview"),
              ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityQA"),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = CodexTaskActivityAttributes.ContentState(
            title: "Old duplicate layout regression", detail: "Running",
            progress: nil, state: "running", pendingApprovalCount: 0, updatedAt: .now
        )
        for taskID in ["preview-active", "obsolete-layout-preview"] {
            _ = try? Activity<CodexTaskActivityAttributes>.request(
                attributes: .init(taskID: taskID), content: ActivityContent(state: state, staleDate: nil), pushType: nil
            )
        }
        recordLayoutRegressionInventory(filename: "live-activity-before.json")
    }

    private func recordLayoutRegressionInventory(filename: String = "live-activity-after.json") {
        guard ProcessInfo.processInfo.arguments.contains("-UIPreview"),
              ProcessInfo.processInfo.arguments.contains("-PreviewLiveActivityQA") else { return }
        let existing = Activity<CodexTaskActivityAttributes>.activities
        let data = try? JSONSerialization.data(withJSONObject: [
            "activeCount": existing.filter { $0.activityState == .active || $0.activityState == .stale }.count,
            "totalCount": existing.count,
            "capturedAt": Date().timeIntervalSince1970,
        ], options: [.sortedKeys])
        try? data?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(filename), options: .atomic)
    }
    #endif

    private func stateLabel(_ state: AgentTask.State) -> String {
        switch state {
        case .running: AppLocalizer.text("运行中")
        case .waitingForApproval: AppLocalizer.text("等待批准")
        case .idle: AppLocalizer.text("空闲")
        case .completed: AppLocalizer.text("已完成")
        case .failed: AppLocalizer.text("失败")
        case .unknown: AppLocalizer.text("处理中")
        }
    }
}
