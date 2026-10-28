import Foundation
import Testing
@testable import CodexWatchCore

/// These are stored-cloud timeline fixtures, not reads of official history.
private actor TimelineSyncFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    var rows: [DotMessage] = []
    var cursors: [String?] = []
    var failCursor: String?
    var cycleCursor = false
    var latestFails = false
    func failLatest(_ value: Bool) { latestFails = value }
    func setRows(_ rows: [DotMessage]) { self.rows = rows }
    func setFailure(_ cursor: String?) { failCursor = cursor }
    func setCycle() { cycleCursor = true }
    func clearCursors() { cursors = [] }
    func connection() async throws -> DotConnection { .init(connected: true, dotName: "dot", verifiedAt: 1) }
    func threads(cursor: String?) async throws -> DotThreadPage { .init(threads: [], nextCursor: nil) }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage { throw DotsError("must_use_timeline") }
    func send(_ command: DotCommand) async throws -> DotReceipt { throw DotsError("unexpected_post") }
    func receipt(_ id: String) async throws -> DotReceipt { throw DotsError("receipt_not_found") }
    func timeline(cursor: String?) async throws -> DotMessagePage {
        cursors.append(cursor)
        if cursor == nil && latestFails { throw DotsError("network_unavailable") }
        if let cursor, cursor == failCursor { throw DotsError("network_unavailable") }
        let end = min(cursor.flatMap(Int.init) ?? rows.count, rows.count)
        let start = max(0, end - 30)
        return .init(messages: Array(rows[start..<end]), nextCursor: cycleCursor && cursor != nil ? cursor : (start > 0 ? String(start) : nil), capturedAt: 1)
    }
}

private func timelineRows(_ count: Int) -> [DotMessage] {
    (0..<count).map { .init(id: "official.test-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "原文\($0)🦦", sentAt: Double($0 + 1)) }
}

@Test @MainActor func dotTimelineReadyRequiresASuccessfulLatestReadNotJustPrepareReturning() async {
    let name = "DotTimelineReady.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = TimelineSyncFixture()
    await transport.setRows(timelineRows(2))
    await transport.failLatest(true)
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    #expect(!store.hasLoadedTimeline)
    await store.prepareConversation()
    #expect(!store.hasLoadedTimeline)
    await transport.failLatest(false)
    await store.prepareConversation()
    #expect(store.hasLoadedTimeline)
    #expect(store.messages == timelineRows(2))
}

@Test @MainActor func dotTimelineSyncBridgesOfflineGapAndKeepsExpandedOlderPages() async {
    let name = "DotTimelineGap.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = TimelineSyncFixture()
    await transport.setRows(timelineRows(100))
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.refreshMessages()
    await store.refreshMessages(more: true)
    #expect(store.messages.map(\.id) == Array(timelineRows(100).dropFirst(40)).map(\.id))
    #expect(store.nextCursor == "40")
    // Fifty records arrived while this client was disconnected. The newest
    // thirty do not overlap its previous latest page.
    await transport.setRows(timelineRows(150))
    await transport.clearCursors()
    await store.refreshMessages()
    #expect(store.messages.map(\.id) == Array(timelineRows(150).dropFirst(40)).map(\.id))
    #expect(store.nextCursor == "40")
    #expect(await transport.cursors.count <= 3) // latest plus at most two catch-up GETs
    await store.refreshMessages(more: true)
    await store.refreshMessages(more: true)
    #expect(store.messages == timelineRows(150))
    #expect(store.nextCursor == nil)
    await store.refreshMessages()
    #expect(store.messages == timelineRows(150))
    #expect(Set(store.messages.map(\.id)).count == 150)
}

@Test @MainActor func dotTimelineSyncNeverRegressesARepliedReceiptFromAnOlderPage() async {
    let name = "DotTimelineState.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = TimelineSyncFixture()
    let id = UUID().uuidString.lowercased()
    let answered = DotMessage(id: id + ".user", role: "user", text: "中文🙂", sentAt: 1, deliveryState: "replied", readAt: 2)
    let reply = DotMessage(id: id + ".reply", role: "assistant", text: "中文🙂", sentAt: 3)
    await transport.setRows([answered, reply])
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.refreshMessages()
    await transport.setRows([.init(id: id + ".user", role: "user", text: answered.text, sentAt: 1, deliveryState: "delivered")])
    await store.refreshMessages()
    #expect(store.messages == [answered, reply])
    #expect(!store.waitingForReply)
    #expect(store.messages.first?.readAt == 2)
}

@Test @MainActor func dotTimelineSyncBoundsLargeGapRecoveryAndRestartsAfterAnotherDisconnect() async {
    let name = "DotTimelineLongGap.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = TimelineSyncFixture()
    await transport.setRows(timelineRows(60))
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.refreshMessages()
    await transport.setRows(timelineRows(260))
    await transport.clearCursors()
    await store.refreshMessages()
    #expect(await transport.cursors.count == 3)
    #expect(store.nextCursor == "170")
    // Another interval starts before the first one was completely recovered.
    await transport.setRows(timelineRows(360))
    for _ in 0..<6 {
        await transport.clearCursors()
        await store.refreshMessages()
        #expect(await transport.cursors.count <= 3)
    }
    #expect(store.nextCursor == "30")
    await store.refreshMessages(more: true)
    #expect(store.messages == timelineRows(360))
    #expect(store.nextCursor == nil)
}

@Test @MainActor func dotTimelineSyncRetainsGapCursorAfterNetworkFailureAndStopsCursorCycles() async {
    let name = "DotTimelineRecovery.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = TimelineSyncFixture()
    await transport.setRows(timelineRows(60))
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.refreshMessages()
    await transport.setRows(timelineRows(120))
    await transport.setFailure("90")
    await store.refreshMessages()
    #expect(store.errorCode == "network_unavailable")
    #expect(store.nextCursor == "90")
    await transport.setFailure(nil)
    await store.refreshMessages()
    #expect(store.errorCode == nil)
    #expect(store.messages == Array(timelineRows(120).dropFirst(30)))
    await transport.setRows(timelineRows(200))
    await transport.setCycle()
    await transport.clearCursors()
    await store.refreshMessages()
    #expect(store.errorCode == "invalid_response")
    #expect(await transport.cursors.count == 2)
    #expect(store.nextCursor == "170")
}

@Test func dotTimelineSyncReconcilesOnlyExactVerifiedMirrorsAlreadyCached() {
    let id = UUID().uuidString.lowercased()
    let user = DotMessage(id: id + ".user", role: "user", text: "原文\n  不改空格🦦", sentAt: 1, deliveryState: "delivered")
    let reply = DotMessage(id: id + ".reply", role: "assistant", text: "答复🍁", sentAt: 2)
    let text = "来自手机／手表 用户：\(user.text) \n dot：\(reply.text)\t同步编号：\(id)\n"
    let mirror = DotMessage(id: "official.mirror", role: "assistant", text: text, sentAt: 3)
    #expect(DotMessage.mergingEvents([mirror], [user]).count == 2) // no reply, no proof
    let merged = DotMessage.mergingEvents([mirror, user], [reply])
    #expect(merged.map(\.id) == [user.id, reply.id])
    #expect(merged.first?.deliveryState == "replied")
    #expect(merged.first?.readAt == nil) // never fabricate read time
    let changed = DotMessage(id: "official.changed", role: "assistant", text: text.replacingOccurrences(of: "不改空格", with: "不 改 空 格"), sentAt: 4)
    let independent = DotMessage(id: "official.independent", role: "assistant", text: reply.text, sentAt: 5)
    let quoted = DotMessage(id: "official.quote", role: "user", text: text, sentAt: 6)
    #expect(DotMessage.mergingEvents(merged, [changed, independent, quoted]).count == 5)
    #expect(DotMessage.mergingEvents(merged, [mirror, mirror]) == merged)
    let accentedUser = DotMessage(id: id + ".user", role: "user", text: "caf\u{00e9}", sentAt: 1)
    let differentBytes = DotMessage(id: "official.normalized", role: "assistant", text: "来自手机／手表\n用户：cafe\u{0301}\ndot：\(reply.text)\n同步编号：\(id)", sentAt: 3)
    #expect(DotMessage.mergingEvents([accentedUser, reply], [differentBytes]).count == 3)
    let crlf = DotMessage(id: mirror.id, role: mirror.role, text: "来自手机／手表\r\n用户：\(user.text)\r\ndot：\(reply.text)\r\n同步编号：\(id)", sentAt: 3)
    #expect(DotMessage.mergingEvents([user, reply], [crlf]).count == 2)
}

@Test func dotTimelineSyncPreservesTerminalStatesButStillAllowsSlackEdits() {
    let failed = DotMessage(id: "a.user", role: "user", text: "草稿", sentAt: 1, deliveryState: "delivery_failed", readAt: 2)
    let stale = DotMessage(id: failed.id, role: "user", text: failed.text, sentAt: 1, deliveryState: "queued")
    #expect(DotMessage.mergingEvents([failed], [stale]) == [failed])
    let edited = DotMessage(id: "slack.timestamp", role: "assistant", text: "更正", sentAt: 1)
    let original = DotMessage(id: edited.id, role: edited.role, text: "初稿", sentAt: 1)
    #expect(DotMessage.merging([original], [edited]) == [edited])
}

private actor HistoryResumeFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    let id = UUID().uuidString.lowercased()
    var completed = false
    var requests = 0
    var statusIDs: [String] = []
    var latestRows: [DotMessage]?
    var importedRows: [DotMessage]?
    var hiddenIDs: [String]?
    var statusFails = false
    var loseAcknowledgement = false
    var submittedID: String?
    func loseNextAcknowledgement() { loseAcknowledgement = true }
    func complete() { completed = true }
    func setBatch(_ rows: [DotMessage], hidden: [String]) { importedRows = rows; hiddenIDs = hidden }
    func setLatest(_ rows: [DotMessage]) { latestRows = rows }
    func failStatus(_ value: Bool) { statusFails = value }
    func connection() async throws -> DotConnection { .init(connected: true, dotName: "dot", verifiedAt: 1) }
    func threads(cursor: String?) async throws -> DotThreadPage { .init(threads: [], nextCursor: nil) }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage { throw DotsError("must_use_timeline") }
    func send(_ command: DotCommand) async throws -> DotReceipt { throw DotsError("unexpected_post") }
    func receipt(_ id: String) async throws -> DotReceipt { throw DotsError("receipt_not_found") }
    func timeline(cursor: String?) async throws -> DotMessagePage { .init(messages: latestRows ?? (completed ? timelineRows(2) : []), nextCursor: nil, capturedAt: 1) }
    func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt {
        requests += 1
        submittedID = request.id
        if loseAcknowledgement { loseAcknowledgement = false; throw DotsError("delivery_uncertain") }
        return currentReceipt()
    }
    func historySyncStatus(_ id: String) async throws -> DotHistorySyncReceipt {
        statusIDs.append(id)
        if statusFails { throw DotsError("network_unavailable") }
        return currentReceipt()
    }
    private func currentReceipt() -> DotHistorySyncReceipt {
        .init(id: submittedID ?? id, state: completed ? "completed" : "delayed", expiresAt: Date().timeIntervalSince1970 * 1000 - 1000,
              truncated: completed, recoverableUntil: Date().timeIntervalSince1970 * 1000 + 600_000,
              messages: completed ? importedRows : nil, hiddenMessageIDs: completed ? hiddenIDs : nil)
    }
}

@Test @MainActor func dotHistoryLostAcknowledgementRestoresOriginalReceiptWithoutAnotherPOST() async {
    let name = "DotHistoryLostAck.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    await transport.loseNextAcknowledgement()
    let first = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await first.prepareConversation()
    let submitted = await transport.submittedID
    #expect(submitted != nil)
    #expect(first.historySync?.id == submitted)
    await transport.complete()
    let restored = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await restored.prepareConversation()
    #expect(restored.historySync?.id == submitted)
    #expect(restored.historySync?.state == "completed")
    #expect(restored.messages == timelineRows(2))
    #expect(await transport.requests == 1)
}

@Test @MainActor func dotTimelineSyncResumesDelayedHistoryAcrossRelaunchWithoutNewControlPOST() async {
    let name = "DotHistoryResume.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    let first = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await first.prepareConversation()
    #expect(first.historySync?.state == "delayed")
    let second = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    #expect(second.historySync?.id == first.historySync?.id)
    await second.prepareConversation()
    #expect(await transport.requests == 1)
    #expect(await transport.statusIDs == [first.historySync!.id])
    await transport.complete()
    await second.refreshConversation()
    #expect(second.historySync?.state == "completed")
    #expect(second.messages == timelineRows(2))
    #expect(await transport.requests == 1)
    let third = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await third.prepareConversation()
    #expect(third.historySync?.truncated == true)
    #expect(await transport.requests == 1)
}

@Test @MainActor func dotTimelineSyncRecoveryMetadataIsIsolatedByGatewayCredentials() async {
    let name = "DotHistoryScope.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    let configA = DotsConfiguration(baseURL: URL(string: "https://fixture.invalid")!, relaySecret: String(repeating: "a", count: 64), channel: .mcpEvents)!
    let configB = DotsConfiguration(baseURL: configA.baseURL, relaySecret: String(repeating: "b", count: 64), channel: .mcpEvents)!
    let first = DotsStore(unifiedConversation: true, configuration: configA, defaults: defaults, transport: transport)
    await first.prepareConversation()
    let other = DotsStore(unifiedConversation: true, configuration: configB, defaults: defaults, transport: transport)
    #expect(other.historySync == nil)
    await other.prepareConversation()
    #expect(await transport.requests == 2)
    #expect(await transport.statusIDs.isEmpty)
}

@Test @MainActor func dotTimelineSyncOldCompletedRestoreDoesNotPostponeFreshOpenRefresh() async throws {
    let name = "DotHistoryOldComplete.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    await transport.complete()
    let first = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await first.prepareConversation()
    try ageCompletedHistory(defaults)
    let restored = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await restored.prepareConversation()
    #expect(await transport.statusIDs.count == 1) // recover its known batch once
    #expect(await transport.requests == 2) // but do not falsely renew its cooldown
    #expect(restored.messages == timelineRows(2))
}

private func ageCompletedHistory(_ defaults: UserDefaults) throws {
    let key = try #require(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("dots.history.events.shared.") })
    let data = try #require(defaults.data(forKey: key))
    var saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    saved["requestedAt"] = Date().addingTimeInterval(-120).timeIntervalSinceReferenceDate
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: key)
}

@Test @MainActor func dotTimelineSyncFailedRestoredBatchReadDoesNotCreateAnotherControlEvent() async throws {
    let name = "DotHistoryRestoreReadFailure.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    await transport.complete()
    let first = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await first.prepareConversation()
    try ageCompletedHistory(defaults)
    await transport.failStatus(true)
    let restored = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await restored.prepareConversation()
    #expect(restored.historySyncError == "network_unavailable")
    #expect(await transport.requests == 1)
    await transport.failStatus(false)
    await restored.prepareConversation()
    #expect(restored.historySyncError == nil)
    #expect(await transport.requests == 2)
}

@Test @MainActor func dotTimelineSyncAppliesOlderImportedBatchAndHiddenIDsAfterRelaunch() async {
    let name = "DotHistoryBatch.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = HistoryResumeFixture()
    let old = [DotMessage(id: "official.earlier-user", role: "user", text: "官方旧消息🦦", sentAt: 1),
               DotMessage(id: "official.earlier-reply", role: "assistant", text: "官方旧回复🍁", sentAt: 2)]
    let newer = (0..<29).map { DotMessage(id: "official.later-\($0)", role: "user", text: "较新\($0)", sentAt: Double($0 + 100)) }
    let mirror = DotMessage(id: "official.verified-hidden-mirror", role: "assistant", text: "已由云端核对的转贴", sentAt: 99)
    await transport.setLatest([mirror] + newer)
    await transport.setBatch(old, hidden: [mirror.id])
    let first = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await first.prepareConversation()
    #expect(first.messages.count == 30)
    await transport.complete()
    for _ in 0..<3 { await first.refreshMessages() }
    #expect(first.messages == old + newer) // including a stale latest page cannot resurrect the mirror
    let savedData = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("dots.history.events.shared.") }.values.compactMap { $0 as? Data }
    #expect(savedData.count == 1)
    #expect(savedData.allSatisfy { data in
        let text = String(decoding: data, as: UTF8.self)
        return !text.contains(old[0].text) && !text.contains(old[1].text) && !text.contains("earlier-user")
    })
    let restored = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    for _ in 0..<3 { await restored.refreshMessages() }
    #expect(restored.messages == first.messages)
    #expect(await transport.statusIDs.count == 2) // one completion read, one relaunch read
    #expect(await transport.requests == 1)
}

@Test func dotTimelineSyncWireBatchRejectsOutOfScopeDeletionAndOversizedPayload() throws {
    let id = UUID().uuidString.lowercased()
    let row = DotMessage(id: "official.valid", role: "assistant", text: "原文🦦", sentAt: 1)
    try DotsEventsClient.validateHistoryReceipt(.init(id: id, state: "completed", expiresAt: 1, truncated: false, messages: [row], hiddenMessageIDs: ["official.hidden"]))
    let invalid = [
        DotHistorySyncReceipt(id: id, state: "completed", expiresAt: 1, truncated: false, hiddenMessageIDs: [id + ".user"]),
        .init(id: id, state: "pending", expiresAt: 1, truncated: false, messages: [row]),
        .init(id: id, state: "completed", expiresAt: 1, truncated: false, messages: [row, row]),
        .init(id: id, state: "completed", expiresAt: 1, truncated: false, messages: [row], hiddenMessageIDs: [row.id]),
        .init(id: id, state: "completed", expiresAt: 1, truncated: false, hiddenMessageIDs: (0..<31).map { "official.\($0)" }),
    ]
    for receipt in invalid {
        #expect(throws: DotsError.self) { try DotsEventsClient.validateHistoryReceipt(receipt) }
    }
}
