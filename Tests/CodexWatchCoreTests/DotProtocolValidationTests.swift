import Foundation
import Testing
@testable import CodexWatchCore

private let validationID = "aaaaaaaa-bbbb-4ccc-8ddd-111111111111"
private func validationRecord(_ changes: [String: Any] = [:]) throws -> DotsEventsClient.Record {
    var body: [String: Any] = ["id": validationID, "thread": validationID, "text": "中文 cafe\u{0301}🦦",
        "createdAt": 1000, "state": "queued"]
    body.merge(changes, uniquingKeysWith: { _, new in new })
    return try JSONDecoder().decode(DotsEventsClient.Record.self, from: JSONSerialization.data(withJSONObject: body))
}

@Test func dotReceiptCompletionRequiresActualReplyAndRejectsUnknownStates() throws {
    try validationRecord().validate()
    try validationRecord(["state": "replied", "reply": "正确🍁", "repliedAt": 2000]).validate()
    for changes: [String: Any] in [
        ["state": "completed"], ["state": "replied"],
        ["state": "replied", "reply": "正确🍁"],
        ["state": "replied", "repliedAt": 2000],
        ["state": "replied", "reply": " \n", "repliedAt": 2000],
        ["state": "delivered", "reply": "不能先冒充回复", "repliedAt": 2000],
        ["id": "another-app"], ["thread": "another-room"],
        ["createdAt": -1], ["createdAt": 1000.5], ["createdAt": 1e100],
        ["text": String(repeating: "字", count: 4001)],
        ["timing": ["readAt": -1]],
    ] {
        let record = try validationRecord(changes)
        #expect(throws: DotsError.self) { try record.validate() }
    }
}

@Test func dotReceiptValidationDoesNotConfuseDeviceClockSkewWithServerFailure() throws {
    // The server accepts bounded client clock skew. A real reply/read can
    // precede the client's timestamp without being forged or changed text.
    let record = try validationRecord(["state": "replied", "createdAt": 2000,
        "reply": "真实回复", "repliedAt": 1500, "timing": ["readAt": 1400]])
    try record.validate()
    #expect(record.receipt.text?.utf8.elementsEqual("中文 cafe\u{0301}🦦".utf8) == true)
}

@Test func dotTimelineRejectsDuplicateIDsWrongRolesAndCrossChannelFields() throws {
    let user = DotMessage(id: validationID + ".user", role: "user", text: "原文🍁", sentAt: 1000, deliveryState: "delivered")
    let reply = DotMessage(id: validationID + ".reply", role: "assistant", text: "答复🦦", sentAt: 2000)
    let official = DotMessage(id: "official.allowed-text", role: "assistant", text: "独立回复", sentAt: 3000)
    func page(_ messages: [DotMessage], at: Double = 4000) -> DotMessagePage {
        .init(messages: messages, nextCursor: nil, capturedAt: at)
    }
    try DotsEventsClient.validateTimeline(page([user, reply, official]))
    for messages in [
        [user, user], Array(repeating: official, count: 31),
        [.init(id: validationID + ".reply", role: "user", text: "wrong role", sentAt: 1)],
        [.init(id: validationID + ".user", role: "user", text: "missing state", sentAt: 1)],
        [.init(id: validationID + ".user", role: "user", text: "unknown state", sentAt: 1, deliveryState: "success")],
        [.init(id: "slack.1", role: "assistant", text: "wrong channel", sentAt: 1)],
        [.init(id: official.id, role: "assistant", text: "wrong channel flag", sentAt: 1, controlsInSlack: true)],
        [.init(id: official.id, role: "assistant", text: "fake status", sentAt: 1, deliveryState: "replied")],
        [.init(id: official.id, role: "assistant", text: "fake read", sentAt: 1, readAt: 2)],
        [.init(id: official.id, role: "assistant", text: "bad time", sentAt: .infinity)],
    ] {
        #expect(throws: DotsError.self) { try DotsEventsClient.validateTimeline(page(messages)) }
    }
    #expect(throws: DotsError.self) { try DotsEventsClient.validateTimeline(page([user], at: -1)) }
}

@Test func dotHistoryReceiptRejectsUnknownStatesAndInvalidDeadlines() {
    for (state, deadline) in [("success", 1.0), ("completed", 0.0), ("pending", Double.infinity), ("pending", 1.5)] {
        let receipt = DotHistorySyncReceipt(id: validationID, state: state, expiresAt: deadline, truncated: false)
        #expect(throws: DotsError.self) { try DotsEventsClient.validateHistoryReceipt(receipt) }
    }
}

@Test func dotColdStartAnchorWaitsForLatestPageAndIsNotConsumedByRestoredRows() {
    var state = DotChatScrollState()
    #expect(!state.hasAnchoredContent)
    let restoredRowsScroll = state.update(ids: ["old-import"], nearBottom: false, initialLoadComplete: false)
    #expect(!restoredRowsScroll)
    #expect(!state.hasAnchoredContent)
    let initialPageScroll = state.update(ids: ["old-import", "latest"], nearBottom: false, initialLoadComplete: true)
    #expect(initialPageScroll)
    #expect(state.hasAnchoredContent)
    let olderPageScroll = state.update(ids: ["older", "old-import", "latest"], nearBottom: false)
    #expect(!olderPageScroll)
    let readingHistoryScroll = state.update(ids: ["older", "old-import", "latest", "reply"], nearBottom: false)
    #expect(!readingHistoryScroll)
}
