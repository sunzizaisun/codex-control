import Foundation
import Testing
@testable import CodexWatchCore

@Test func numericJSONOutsideIntegerRangeCannotCrashDecoding() throws {
    for value in [Double.infinity, -Double.infinity, Double.nan, 1e100, -1e100, Double(Int.max), 1.5] {
        #expect(JSONValue.number(value).intValue == nil)
    }
    #expect(JSONValue.number(42).intValue == 42)
    #expect(JSONValue.number(Double(Int.min)).intValue == Int.min)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("1e100".utf8))
    #expect(decoded.intValue == nil)
}

@Test func outboxExpiryIsBoundedEvenAfterAnOfflineDay() {
    let now = Date(timeIntervalSince1970: 100_000)
    for kind in [BridgeMessageKind.approvalDecision, .usageReset, .taskCommand] {
        let lifetime: TimeInterval = kind == .taskCommand ? 86_400 : 900
        let expired = BridgeEnvelope(sentAt: now.addingTimeInterval(-lifetime), kind: kind, senderDeviceID: "fixture")
        #expect(!RelayOutboxPolicy.isDeliverable(expired, now: now))
        var before = expired; before.sentAt = before.sentAt.addingTimeInterval(1)
        #expect(RelayOutboxPolicy.isDeliverable(before, now: now))
    }
    let future = BridgeEnvelope(sentAt: now.addingTimeInterval(61), kind: .taskCommand, senderDeviceID: "fixture")
    #expect(!RelayOutboxPolicy.isDeliverable(future, now: now))
}

@Test func repeatedTaskAndMessageIDsAreMergedWithoutCrashingOrDuplicatingRows() {
    let now = Date(timeIntervalSince1970: 100_000)
    let message = ChatMessage(id: "m", role: .assistant, text: "first", createdAt: now)
    var old = AgentTask(id: "task", title: "test", state: .running, updatedAt: now, messages: [message, message])
    let previous = DashboardSnapshot(tasks: [old, old], bridgeConnected: true, capturedAt: now)
    old.state = .completed; old.updatedAt = now.addingTimeInterval(1)
    var latest = old; latest.title = "latest"; latest.updatedAt = now.addingTimeInterval(2)
    latest.messages = [ChatMessage(id: "m", role: .assistant, text: "complete", createdAt: now)]
    let current = DashboardSnapshot(tasks: [old, latest], bridgeConnected: true, capturedAt: now)
    let merged = current.mergingRecentTasks(from: previous, now: now)
    #expect(merged.tasks.count == 1)
    #expect(merged.tasks.first?.title == "latest")
    #expect(merged.tasks.first?.messages.count == 1)
    #expect(merged.tasks.first?.messages.first?.text == "complete")
}

@Test func retainedMissingTaskDoesNotPretendItsOldTurnIsStillRunning() {
    let now = Date(timeIntervalSince1970: 100_000)
    var active = AgentTask(id: "active", title: "test", state: .running, activeTurnID: "turn", updatedAt: now)
    active.awaitingUserInput = true
    let previous = DashboardSnapshot(tasks: [active], bridgeConnected: true, capturedAt: now)
    let merged = DashboardSnapshot(bridgeConnected: true, capturedAt: now).mergingRecentTasks(from: previous, now: now)
    #expect(merged.tasks.count == 1)
    #expect(merged.tasks.first?.state == .unknown)
    #expect(merged.tasks.first?.isInProgress == false)
    #expect(merged.tasks.first?.activeTurnID == nil)
}

@Test func staleMacSnapshotRetainsHistoryWithoutClaimingTasksAreRunning() {
    let now = Date(timeIntervalSince1970: 100_000)
    let message = ChatMessage(id: "m", role: .assistant, text: "已同步记录")
    var task = AgentTask(id: "active", title: "项目", state: .running, activeTurnID: "turn", updatedAt: now, messages: [message])
    task.awaitingUserInput = true
    task.progress = 0.5
    let offline = DashboardSnapshot(tasks: [task], bridgeConnected: true,
        capturedAt: now.addingTimeInterval(-151)).reconcilingMacPresence(now: now)
    #expect(!offline.bridgeConnected)
    #expect(offline.tasks.first?.state == .unknown)
    #expect(offline.tasks.first?.activeTurnID == nil)
    #expect(offline.tasks.first?.awaitingUserInput == nil)
    #expect(offline.tasks.first?.progress == nil)
    #expect(offline.tasks.first?.messages == [message])
    let online = DashboardSnapshot(tasks: [task], bridgeConnected: true, capturedAt: now).reconcilingMacPresence(now: now)
    #expect(online.tasks.first?.state == .running)
}

@Test func relayPlaintextDeadlineCannotExtendAnAuthenticatedApproval() {
    let envelope = BridgeEnvelope(sentAt: Date(timeIntervalSince1970: 100), kind: .approvalDecision, senderDeviceID: "fixture")
    #expect(RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: 100_000, expiresAtMilliseconds: 1_000_000))
    #expect(RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: 100_000, expiresAtMilliseconds: nil))
    #expect(!RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: 100_000, expiresAtMilliseconds: 86_500_000))
    #expect(!RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: 200_000, expiresAtMilliseconds: 1_000_000))
}

@Test func firstSeenTaskAndRetentionBothNormalizeDuplicateIDs() {
    let now = Date()
    let message = ChatMessage(id: "m", role: .assistant, text: "reply")
    let task = AgentTask(id: "a", title: "a", state: .completed, updatedAt: now, messages: [message, message])
    let second = AgentTask(id: "b", title: "b", state: .completed, updatedAt: now, messages: [message])
    let empty = DashboardSnapshot(bridgeConnected: true, capturedAt: now)
    let first = DashboardSnapshot(tasks: [task], bridgeConnected: true, capturedAt: now).mergingRecentTasks(from: empty)
    #expect(first.tasks.first?.messages.count == 1)
    let previous = DashboardSnapshot(tasks: [task, task, second], bridgeConnected: true, capturedAt: now)
    let retained = empty.mergingRecentTasks(from: previous, now: now, maximumRetainedTasks: 2)
    #expect(retained.tasks.map(\.id) == ["a", "b"])
    #expect(retained.tasks.first?.messages.count == 1)
}

#if os(macOS)
@Test func systemHTTPSFallbackRequiresARealSuccessfulHTTPStatus() throws {
    #expect(try RemoteRelayClient.systemHTTPBody(Data("hello\n200".utf8), exitStatus: 0) == Data("hello".utf8))
    #expect(try RemoteRelayClient.systemHTTPBody(Data("\n204".utf8), exitStatus: 0).isEmpty)
    for code in [302, 307, 401, 413, 500] {
        #expect(throws: RemoteRelayError.self) { try RemoteRelayClient.systemHTTPBody(Data("body\n\(code)".utf8), exitStatus: 0) }
    }
    #expect(throws: RemoteRelayError.self) { try RemoteRelayClient.systemHTTPBody(Data("partial\n200".utf8), exitStatus: 28) }
}
#endif
