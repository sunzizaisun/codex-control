import Foundation
import Testing
@testable import CodexWatchCore

private func activityTask(_ id: String, state: AgentTask.State = .running, time: Double = 0) -> AgentTask {
    AgentTask(id: id, title: "Task \(id)", state: state, updatedAt: Date(timeIntervalSince1970: time))
}

@Test func liveActivityKeepsItsRunningTaskWhenAnotherTaskGetsNewer() {
    let snapshot = DashboardSnapshot(tasks: [activityTask("current"), activityTask("newer", time: 100)], bridgeConnected: true, capturedAt: .now)
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: "current")?.id == "current")
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: nil)?.id == "newer")
}

@Test func liveActivityPrioritizesApprovalWithoutRotatingBetweenApprovals() {
    let snapshot = DashboardSnapshot(tasks: [activityTask("running", time: 200), activityTask("waiting", state: .waitingForApproval), activityTask("waiting-newer", state: .waitingForApproval, time: 100)], bridgeConnected: true, capturedAt: .now)
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: "running")?.id == "waiting-newer")
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: "waiting")?.id == "waiting")
}

@Test func liveActivityEndsForOfflineAndInactiveTasks() {
    var snapshot = DashboardSnapshot(tasks: [activityTask("running")], bridgeConnected: false, capturedAt: .now)
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: "running") == nil)
    snapshot.bridgeConnected = true
    snapshot.tasks = [.idle, .completed, .failed, .unknown].enumerated().map { activityTask("\($0.offset)", state: $0.element) }
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: nil) == nil)
}

@Test func liveActivityRejectsChatAndProtocolArtifacts() {
    var chat = activityTask("chat")
    chat.isChat = true
    var native = activityTask("native")
    native.isNativeChat = true
    var artifact = activityTask("artifact")
    artifact.title = "file:///implementation"
    let snapshot = DashboardSnapshot(tasks: [chat, native, artifact], bridgeConnected: true, capturedAt: .now)
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: nil) == nil)
}

@Test func liveActivitySelectionIsDeterministicForEqualTimestamps() {
    let snapshot = DashboardSnapshot(tasks: [activityTask("b"), activityTask("a")], bridgeConnected: true, capturedAt: .now)
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: "missing")?.id == "a")
}

@Test func liveActivityReconciliationRetainsOnlyOneMatchingCard() {
    let cards: [TaskLiveActivityPolicy.ExistingActivity] = [
        .init(id: "old-other", taskID: "other"), .init(id: "b", taskID: "task"), .init(id: "a", taskID: "task")
    ]
    #expect(TaskLiveActivityPolicy.retainedActivityID(in: cards, taskID: "task", preferredActivityID: "b") == "b")
    #expect(TaskLiveActivityPolicy.retainedActivityID(in: cards, taskID: "task", preferredActivityID: "old-other") == "a")
    #expect(TaskLiveActivityPolicy.retainedActivityID(in: cards, taskID: nil, preferredActivityID: "b") == nil)
    #expect(TaskLiveActivityPolicy.retainedActivityID(in: cards, taskID: "new", preferredActivityID: "b") == nil)
}

@Test func liveActivityTitlePreservesUnicodeAndRemovesInvisibleLineBreaks() {
    #expect(TaskLiveActivityPolicy.title("  控制\nApple\tWatch   GPT 🙂 ") == "控制 Apple Watch GPT 🙂")
    #expect(TaskLiveActivityPolicy.title("رسالة جديدة") == "رسالة جديدة")
}

@Test func liveActivityProgressRejectsNonfiniteAndClampsOutOfRangeValues() {
    #expect(TaskLiveActivityPolicy.progress(nil) == nil)
    #expect(TaskLiveActivityPolicy.progress(.nan) == nil)
    #expect(TaskLiveActivityPolicy.progress(.infinity) == nil)
    #expect(TaskLiveActivityPolicy.progress(-1) == 0)
    #expect(TaskLiveActivityPolicy.progress(2) == 1)
    #expect(TaskLiveActivityPolicy.progress(0.68) == 0.68)
}
