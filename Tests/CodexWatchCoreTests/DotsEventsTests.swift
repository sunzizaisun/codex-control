import CryptoKit
import Foundation
import Testing
@testable import CodexWatchCore

@Test func dotEventsAuthAndPendingPersistenceAreSeparateFromSlack() {
    let root = String(repeating: "a", count: 64)
    let expected = HMAC<SHA256>.authenticationCode(for: Data("codex-control/dot-inbox/device/v1".utf8), using: SymmetricKey(data: Data(root.utf8)))
    #expect(DotsConfiguration.derivedKey(relaySecret: root, channel: .mcpEvents) == Data(expected).base64EncodedString())
    #expect(DotsConfiguration.derivedKey(relaySecret: root, channel: .mcpEvents) != DotsConfiguration.derivedKey(relaySecret: root))
}
@Test func dotEventsPreserveUnicodeAndChronologicalMessageOrder() throws {
    let data = Data(#"{"id":"eeeeeeee-1234-4abc-8def-0123456789ab","thread":"eeeeeeee-1234-4abc-8def-0123456789ab","text":"你好，你是什么模型？🙂","createdAt":1000,"state":"replied","reply":"中文跟进收发一致，测试结束🙂","repliedAt":2000}"#.utf8)
    let record = try JSONDecoder().decode(DotsEventsClient.Record.self, from: data)
    #expect(record.messages.map(\.text) == ["你好，你是什么模型？🙂", "中文跟进收发一致，测试结束🙂"])
    let followup = DotMessage(id: "aaaaaaaa-1234-4abc-8def-0123456789ab.user", role: "user", text: "继续", sentAt: 3000)
    #expect(DotMessage.merging(record.messages, [followup]).map(\.text) == [record.text, record.reply!, "继续"])
    #expect(record.receipt.state == "replied")
    #expect(record.messages.allSatisfy { !$0.controlsInSlack })
}
@Test func dotEventTranslationsCoverEverySupportedLanguage() {
    for language in AppLanguage.allCases where language != .system {
        for key in ["dot 云端渠道说明", "dot 连接就绪", "dot 尚未订阅", "dot 回复较慢", "dot 投递失败", "dot 正在同步", "dot 近期记录", "dot 同步延迟", "dot 云端日额度耗尽"] {
            #expect(DotsTranslations.text(key, language: language)?.isEmpty == false)
            #expect(AppLocalizer.text(key, language: language) != key)
        }
    }
}

@Test func dotEventLabelsSeparateCloudAcceptanceFromActualReadAndReply() {
    let cases: [(String, Double?, String)] = [("queued", nil, "dot 云端已接收"),
        ("delivered", nil, "dot 等待读取"), ("delivered", 2, "dot 已收到"),
        ("replied", nil, "dot 已回复"), ("expired", nil, "dot 投递失败")]
    for (state, readAt, key) in cases {
        let message = DotMessage(id: "qa.user", role: "user", text: "测试", sentAt: 1, deliveryState: state, readAt: readAt)
        #expect(message.eventDeliveryLabelKey == key)
        for language in AppLanguage.allCases where language != .system {
            // This established Chinese label intentionally includes "dot".
            if language == .simplifiedChinese && key == "dot 已收到" {
                #expect(AppLocalizer.text(key, language: language) == "dot 已收到")
            } else { #expect(AppLocalizer.text(key, language: language) != key) }
        }
    }
}

private final class DotEventsURLFixture: URLProtocol, @unchecked Sendable {
    static let root = "eeeeeeee-1234-4abc-8def-0123456789ab"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dot-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let expectedKey = DotsConfiguration.derivedKey(relaySecret: String(repeating: "a", count: 64), channel: .mcpEvents)
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedKey)" else { throw DotsError("fixture_wrong_auth_domain") }
            let originalPath = request.url!.path
            let normalize = originalPath.hasPrefix("/normalize/")
            let invalidCompletion = originalPath.hasPrefix("/invalid-completion/")
            let path = normalize ? String(originalPath.dropFirst("/normalize".count))
                : (invalidCompletion ? String(originalPath.dropFirst("/invalid-completion".count)) : originalPath)
            var status = 200
            let body: [String: Any]
            if path == "/v2/status" {
                body = ["subscribed": true, "expiresAt": Date().timeIntervalSince1970 * 1000 + 60_000, "transport": "mcp-events"]
            } else if path == "/v2/threads" {
                body = ["threads": [["id": Self.root, "title": "中文🙂", "updatedAt": 2000]], "nextCursor": NSNull()]
            } else if path == "/v2/threads/\(Self.root)/messages" {
                body = ["messages": [["id": Self.root, "thread": Self.root, "text": "你好，你是什么模型？🙂", "createdAt": 1000, "state": "replied", "reply": "中文收发一致🙂", "repliedAt": 2000]], "nextCursor": NSNull(), "capturedAt": 3000]
            } else if path == "/v3/messages" {
                body = ["messages": [["id": "official.qa-user", "role": "user", "text": "官方原文：海狸-428🍁", "sentAt": 1000, "controlsInSlack": false], ["id": "official.qa-reply", "role": "assistant", "text": "官方回复：海狸-428🍁", "sentAt": 2000, "controlsInSlack": false]], "nextCursor": NSNull(), "capturedAt": 3000]
            } else if path == "/v3/sync" || path == "/v3/sync/\(Self.root)" {
                body = ["id": Self.root, "state": "pending", "expiresAt": 9999999999999, "truncated": false]
            } else if path == "/v2/messages", request.httpMethod == "POST" {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let command = try JSONDecoder().decode(DotCommand.self, from: data)
                body = ["id": command.id, "thread": command.thread ?? command.id, "text": normalize ? command.text.precomposedStringWithCanonicalMapping : command.text, "createdAt": command.createdAt, "state": invalidCompletion ? "replied" : "queued"]
            } else { status = 404; body = ["error": path.hasPrefix("/v3/") ? "not_found" : "message_not_found"] }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func eventWireClient(path: String = "") -> DotsEventsClient {
    let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [DotEventsURLFixture.self]
    let configuration = DotsConfiguration(baseURL: URL(string: "https://dot-fixture.invalid" + path)!, relaySecret: String(repeating: "a", count: 64), channel: .mcpEvents)!
    return DotsEventsClient(configuration: configuration, session: URLSession(configuration: settings))
}
@Test func dotEventsHTTPClientUsesV2RoutesAndMapsActualWireHistory() async throws {
    let client = eventWireClient()
    #expect(try await client.connection().connected)
    #expect(try await client.threads(cursor: nil).threads.first?.title == "中文🙂")
    let page = try await client.messages(thread: DotEventsURLFixture.root, cursor: nil, after: nil)
    #expect(page.messages.map(\.text) == ["你好，你是什么模型？🙂", "中文收发一致🙂"])
    #expect(page.messages.map(\.role) == ["user", "assistant"])
    #expect(page.nextCursor == nil)
}
@Test func dotEventsHTTPClientKeepsExactSendPayloadAndMapsMissingReceipts() async throws {
    let client = eventWireClient(), command = DotCommand(text: "你好，你是什么模型？🙂\n3 < 5 & 文本", thread: nil)
    let receipt = try await client.send(command)
    #expect(receipt.id == command.id)
    #expect(receipt.thread == command.id)
    #expect(receipt.text == command.text)
    #expect(receipt.state == "queued")
    do { _ = try await client.receipt(command.id); Issue.record("Expected missing receipt") }
    catch let error as DotsError { #expect(error.code == "receipt_not_found") }
}

@Test func dotEventsHTTPAcknowledgementRequiresExactUnicodeBytes() async {
    let client = eventWireClient(path: "/normalize")
    let command = DotCommand(text: "cafe\u{0301} 🦦", thread: nil)
    do {
        _ = try await client.send(command)
        Issue.record("Canonically equal text with different bytes must remain unconfirmed")
    } catch let error as DotsError { #expect(error.code == "delivery_uncertain") }
    catch { Issue.record("Unexpected fixture error") }
}
@Test @MainActor func dotMalformedCompletedAcknowledgementRetainsOriginalLookupAndDraftAcrossRestart() async {
    let name = "DotMalformedAck.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let client = eventWireClient(path: "/invalid-completion")
    let store = DotsStore(configuration: nil, defaults: defaults, transport: client)
    await store.send("不能把缺失回复当成成功🦦")
    #expect(store.deliveryState == "uncertain")
    #expect(store.pending?.text == "不能把缺失回复当成成功🦦")
    #expect(store.threadID == nil)
    #expect(!store.isSending)
    let restored = DotsStore(configuration: nil, defaults: defaults, transport: client)
    #expect(restored.pending == store.pending)
    #expect(restored.deliveryState == "uncertain")
}
@Test func dotEventsHTTPClientDecodesOfficialHistoryAndCoalescedSyncReceipt() async throws {
    let client = eventWireClient()
    let receipt = try await client.requestHistorySync(.init())
    #expect(receipt.id == DotEventsURLFixture.root)
    #expect(receipt.state == "pending")
    #expect(try await client.historySyncStatus(receipt.id).id == receipt.id)
    let page = try await client.timeline(cursor: nil)
    #expect(page.messages.map(\.role) == ["user", "assistant"])
    #expect(page.messages.map(\.text) == ["官方原文：海狸-428🍁", "官方回复：海狸-428🍁"])
    #expect(page.messages.allSatisfy { $0.deliveryState == nil })
    #expect(DotMessage.merging(page.messages, page.messages).count == 2)
}

private actor EventStoreFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    enum Mode: Sendable { case queued, lostAcknowledgement, failed, expired, unsubscribed }
    var mode: Mode
    var commands: [DotCommand] = []
    var cursors: [String?] = []
    var latestHasReply = false
    var connectionFails = false
    var connectionCalls = 0
    var changedReceiptText = false
    func changeReceiptText() { changedReceiptText = true }
    init(_ mode: Mode) { self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func setReply() { latestHasReply = true }
    func failConnection() { connectionFails = true }
    func restoreConnection() { connectionFails = false }
    func connection() async throws -> DotConnection {
        connectionCalls += 1
        if connectionFails { throw DotsError("network_unavailable") }
        return DotConnection(connected: true, dotName: "dot", verifiedAt: 1)
    }
    func threads(cursor: String?) async throws -> DotThreadPage { DotThreadPage(threads: [], nextCursor: nil) }
    func send(_ command: DotCommand) async throws -> DotReceipt {
        commands.append(command)
        if mode == .unsubscribed { throw DotsError("dot_not_subscribed") }
        if mode == .lostAcknowledgement { throw DotsError("delivery_uncertain") }
        return receiptFor(command)
    }
    func receipt(_ id: String) async throws -> DotReceipt {
        guard let command = commands.first(where: { $0.id == id }) else { throw DotsError("receipt_not_found") }
        return receiptFor(command)
    }
    private func receiptFor(_ command: DotCommand) -> DotReceipt {
        DotReceipt(id: command.id, state: mode == .failed ? "delivery_failed" : (mode == .expired ? "expired" : "queued"), thread: command.thread ?? command.id,
                   timestamp: command.id + ".user", error: nil, text: changedReceiptText ? "另一个消息" : command.text, createdAt: Double(command.createdAt))
    }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage {
        cursors.append(cursor)
        guard let command = commands.last else { return DotMessagePage(messages: [], nextCursor: "30", capturedAt: 1) }
        let user = DotMessage(id: command.id + ".user", role: "user", text: command.text, sentAt: Double(command.createdAt), deliveryState: mode == .failed ? "delivery_failed" : (mode == .expired ? "expired" : (latestHasReply ? "replied" : "delivered")))
        var messages = [user]
        if latestHasReply { messages.append(DotMessage(id: command.id + ".reply", role: "assistant", text: "收到中文🙂", sentAt: Double(command.createdAt) + 1000)) }
        return DotMessagePage(messages: messages, nextCursor: cursor == nil ? "30" : nil, capturedAt: 1)
    }
}

@Test @MainActor func dotForegroundRefreshStoreTracksSendReplyAndErrorRecovery() async {
    let name = "DotsRefresh.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    #expect(store.foregroundRefreshMessageID == nil)
    #expect(store.foregroundRefreshInterval(active: false) == nil)
    #expect(store.foregroundRefreshInterval(active: true) == 12)
    await store.send("等待回复🙂")
    #expect(store.foregroundRefreshMessageID == (await transport.commands.last?.id))
    #expect(store.foregroundRefreshInterval(active: true) == 1)
    await transport.failConnection(); await store.refreshInbox(); await store.refreshInbox()
    #expect(store.foregroundRefreshInterval(active: true) == 6)
    await transport.restoreConnection(); await store.refreshInbox()
    #expect(store.foregroundRefreshInterval(active: true) == 1)
    await transport.setReply(); await store.refreshMessages()
    #expect(store.foregroundRefreshMessageID == nil)
    #expect(store.foregroundRefreshInterval(active: true) == 3)
    #expect(store.foregroundRefreshInterval(active: true, now: Date().addingTimeInterval(120)) == 12)
    #expect(await transport.commands.count == 1)
}

@Test @MainActor func dotForegroundRefreshCancelledTaskDoesNotStartNetworkReads() async {
    let name = "DotsCancelledRefresh.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    let store = DotsStore(thread: UUID().uuidString.lowercased(), configuration: nil, defaults: defaults, transport: transport)
    let task = Task { @MainActor in
        while !Task.isCancelled { await Task.yield() }
        await store.refreshInbox(); await store.refreshMessages()
    }
    task.cancel(); await task.value
    #expect(await transport.connectionCalls == 0)
    #expect(await transport.cursors.isEmpty)
    #expect(store.errorCode == nil)
}

private actor SharedDotFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    var commands: [DotCommand] = []
    var replied = false
    var hideLatest = false
    var syncCalls = 0
    var syncOperationOrder: [String] = []
    var syncCompleted = false
    var syncDelayed = false
    let syncID = UUID().uuidString.lowercased()
    func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt {
        syncOperationOrder.append("request")
        syncCalls += 1
        return .init(id: syncID, state: "pending", expiresAt: Date().timeIntervalSince1970 * 1000 + 300_000, truncated: false)
    }
    func historySyncStatus(_ id: String) async throws -> DotHistorySyncReceipt {
        .init(id: syncID, state: syncCompleted ? "completed" : (syncDelayed ? "delayed" : "pending"), expiresAt: Date().timeIntervalSince1970 * 1000 + 300_000, truncated: syncCompleted)
    }
    func finishSync() { syncCompleted = true }
    func delaySync() { syncDelayed = true }
    func hideTimelinePage() { hideLatest = true }
    func connection() async throws -> DotConnection { DotConnection(connected: true, dotName: "dot", verifiedAt: 1) }
    func threads(cursor: String?) async throws -> DotThreadPage { .init(threads: [], nextCursor: nil) }
    func send(_ command: DotCommand) async throws -> DotReceipt {
        commands.append(command)
        return try await receipt(command.id)
    }
    func setReply() { replied = true }
    func receipt(_ id: String) async throws -> DotReceipt {
        let command = commands.first { $0.id == id }!
        return .init(id: id, state: replied ? "replied" : "delivered", thread: commands.first!.id, timestamp: nil, error: nil,
                     text: command.text, createdAt: Double(command.createdAt), reply: replied ? "共享回复🙂" : nil, repliedAt: replied ? Double(command.createdAt) + 1000 : nil)
    }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage { throw DotsError("must_use_shared_timeline") }
    func timeline(cursor: String?) async throws -> DotMessagePage {
        syncOperationOrder.append("timeline")
        if hideLatest { return .init(messages: [], nextCursor: "30", capturedAt: 1) }
        let rows = commands.flatMap { command -> [DotMessage] in
            var result = [DotMessage(id: command.id + ".user", role: "user", text: command.text, sentAt: Double(command.createdAt), deliveryState: replied ? "replied" : "delivered")]
            if replied { result.append(DotMessage(id: command.id + ".reply", role: "assistant", text: "共享回复🙂", sentAt: Double(command.createdAt) + 1000)) }
            return result
        }
        let official = syncCompleted ? [DotMessage(id: "official.qa-user", role: "user", text: "官方原文：海狸-428🍁", sentAt: 1), DotMessage(id: "official.qa-reply", role: "assistant", text: "官方回复：海狸-428🍁", sentAt: 2)] : []
        return .init(messages: official + rows, nextCursor: nil, capturedAt: 1)
    }
}
@Test @MainActor func dotHistorySyncRunsOnOpenNotEveryForegroundPollAndMergesExactlyOnce() async {
    let name = "DotHistorySync.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SharedDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.prepareConversation()
    #expect(await transport.syncCalls == 1)
    #expect(await transport.syncOperationOrder.prefix(2).elementsEqual(["timeline", "request"]))
    #expect(store.historySync?.state == "pending")
    #expect(store.foregroundRefreshInterval(active: true) == 3)
    #expect(store.foregroundRefreshInterval(active: false) == nil)
    let syncWakeKey = store.foregroundRefreshMessageID
    #expect(syncWakeKey?.hasPrefix("history.") == true)
    for _ in 0..<5 { await store.refreshMessages() }
    #expect(await transport.syncCalls == 1)
    await transport.finishSync()
    for _ in 0..<3 { await store.refreshMessages() }
    #expect(store.messages.map(\.text) == ["官方原文：海狸-428🍁", "官方回复：海狸-428🍁"])
    #expect(store.messages.count == 2)
    #expect(!store.waitingForReply)
    #expect(store.historySync?.truncated == true)
    #expect(store.foregroundRefreshMessageID == syncWakeKey)
    #expect(store.foregroundRefreshInterval(active: true) == 12)
    await store.refreshConversation()
    #expect(await transport.syncCalls == 1)
    await store.send("接续：刚才是什么短语？")
    #expect(await transport.commands.count == 1)
    #expect(await transport.syncCalls == 1)
    #expect(store.messages.first?.id == "official.qa-user")
}
@Test @MainActor func dotDelayedHistorySyncCanCompleteWithoutResendingOrLosingTimeline() async {
    let name = "DotDelayedSync.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SharedDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.prepareConversation()
    await transport.delaySync()
    await store.refreshMessages()
    #expect(store.historySync?.state == "delayed")
    #expect(store.historySyncError == nil)
    #expect(store.foregroundRefreshInterval(active: false) == nil)
    #expect(store.foregroundRefreshInterval(active: true) == 12)
    await transport.finishSync()
    for _ in 0..<3 { await store.refreshMessages() }
    #expect(store.historySync?.state == "completed")
    #expect(store.messages.count == 2)
    #expect(await transport.syncCalls == 1)
    #expect(await transport.commands.isEmpty)
}

private actor SlowHistoryDotFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    private var commands: [DotCommand] = []
    private var syncGate: CheckedContinuation<Void, Never>?
    private var syncStartedWaiter: CheckedContinuation<Void, Never>?
    private var syncStarted = false
    private(set) var syncCalls = 0
    private(set) var inboxCalls = 0
    func connection() async throws -> DotConnection {
        inboxCalls += 1
        return .init(connected: true, dotName: "dot", verifiedAt: 1)
    }
    func threads(cursor: String?) async throws -> DotThreadPage {
        inboxCalls += 1
        return .init(threads: [], nextCursor: nil)
    }
    func send(_ command: DotCommand) async throws -> DotReceipt {
        commands.append(command)
        return try await receipt(command.id)
    }
    func receipt(_ id: String) async throws -> DotReceipt {
        guard let command = commands.first(where: { $0.id == id }) else { throw DotsError("receipt_not_found") }
        return .init(id: id, state: "delivered", thread: commands[0].id,
                     timestamp: id + ".user", error: nil, text: command.text, createdAt: Double(command.createdAt))
    }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage {
        throw DotsError("must_use_shared_timeline")
    }
    func timeline(cursor: String?) async throws -> DotMessagePage {
        .init(messages: commands.map { .init(id: $0.id + ".user", role: "user", text: $0.text,
                sentAt: Double($0.createdAt), deliveryState: "delivered") }, nextCursor: nil, capturedAt: 1)
    }
    func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt {
        syncCalls += 1
        await withCheckedContinuation { continuation in
            syncGate = continuation
            syncStarted = true
            syncStartedWaiter?.resume(); syncStartedWaiter = nil
        }
        return .init(id: request.id, state: "pending", expiresAt: Date().timeIntervalSince1970 * 1000 + 300_000, truncated: false)
    }
    func waitForSyncStart() async {
        if syncStarted { return }
        await withCheckedContinuation { syncStartedWaiter = $0 }
    }
    func finishSlowSyncRequest() { syncGate?.resume(); syncGate = nil }
}

@Test @MainActor func dotSlowHistorySyncDoesNotBlockAcknowledgedFollowUp() async {
    let name = "DotSlowSync.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SlowHistoryDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    let open = Task { await store.prepareConversation() }
    await transport.waitForSyncStart()
    await store.send("第一条中文🙂")
    #expect(!store.isSending)
    #expect(store.pending == nil)
    #expect(store.messages.map(\.text) == ["第一条中文🙂"])
    // Both sends complete while the explicit open's history POST is held.
    await store.send("跟进：第二条🦉")
    #expect(!store.isSending)
    #expect(Set(store.messages.map(\.text)) == ["第一条中文🙂", "跟进：第二条🦉"])
    #expect(Set(store.messages.map(\.id)).count == 2)
    #expect(await transport.syncCalls == 1)
    await transport.finishSlowSyncRequest()
    await open.value
    #expect(!store.isSending)
}

@Test @MainActor func dotSendDoesNotEnqueueRedundantHistoryControlEvents() async {
    let name = "DotNoSendSync.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SlowHistoryDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.send("只发送消息，不追加控制事件🙂")
    #expect(await transport.syncCalls == 0)
    #expect(store.pending == nil)
    #expect(!store.isSending)
    #expect(store.messages.first?.text == "只发送消息，不追加控制事件🙂")
}

@Test @MainActor func dotUnifiedOpenDoesNotWaitForUnusedInboxRequests() async {
    let name = "DotFastOpen.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SlowHistoryDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    let open = Task { await store.prepareConversation() }
    await transport.waitForSyncStart()
    #expect(await transport.inboxCalls == 0)
    await transport.finishSlowSyncRequest()
    await open.value
}
@Test @MainActor func dotLateReplyOutsideLatestTimelinePageStillArrives() async {
    let name = "DotLateShared.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SharedDotFixture()
    let store = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    await store.send("早前的消息🙂")
    await transport.hideTimelinePage(); await transport.setReply()
    await store.refreshMessages()
    #expect(!store.waitingForReply)
    #expect(store.messages.last?.text == "共享回复🙂")
    #expect(await transport.commands.count == 1)
}
@Test @MainActor func unifiedDotMigratesUncertainOldSendWithoutReposting() async throws {
    let name = "DotMigration.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SharedDotFixture()
    let command = DotCommand(text: "旧版本已发送🙂", thread: nil)
    _ = try await transport.send(command)
    defaults.set(try JSONEncoder().encode(command), forKey: "dots.pending.events.v2.new")
    defaults.set("未发送的草稿🙂", forKey: "dots.pending.events.v2.new.draft")
    let store = DotsStore(resumeLastConversation: true, unifiedConversation: true, configuration: nil, defaults: defaults, transport: transport)
    #expect(store.pending?.id == command.id)
    #expect(store.foregroundRefreshMessageID == command.id)
    #expect(store.recoverableDraft == "未发送的草稿🙂")
    #expect(defaults.data(forKey: "dots.pending.events.v2.new") == nil)
    await store.prepareConversation()
    #expect(store.pending == nil)
    #expect(store.foregroundRefreshMessageID == command.id)
    #expect(await transport.commands.count == 1)
    #expect(store.messages.first?.text == command.text)
}
@Test @MainActor func independentDevicesSeeSameDotConversationAndActualReplies() async {
    let names = ["SharedDotPhone.\(UUID())", "SharedDotWatch.\(UUID())"]
    let defaults = names.map { UserDefaults(suiteName: $0)! }
    defer { for (name, value) in zip(names, defaults) { value.removePersistentDomain(forName: name) } }
    let transport = SharedDotFixture()
    let phone = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults[0], transport: transport)
    let watch = DotsStore(unifiedConversation: true, configuration: nil, defaults: defaults[1], transport: transport)
    await phone.send("手机原文🙂"); await watch.prepareConversation()
    #expect(watch.messages.map(\.text) == ["手机原文🙂"])
    await watch.send("手表跟进🙂"); await phone.refreshMessages()
    #expect(phone.messages == watch.messages)
    #expect(phone.waitingForReply)
    #expect(phone.messages.allSatisfy { $0.readAt == nil })
    #expect(await transport.commands.allSatisfy { $0.shared == true && $0.thread == nil })
    await transport.setReply(); await phone.refreshMessages(); await watch.refreshMessages()
    #expect(phone.messages == watch.messages)
    #expect(phone.messages.filter { $0.role == "assistant" }.count == 2)
    #expect(!phone.waitingForReply && !watch.waitingForReply)
}

@Test @MainActor func dotEventQueuedReceiptDoesNotBecomeUnknownOrGetResent() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("你好，你是什么模型？🙂")
    #expect(store.pending == nil)
    #expect(store.threadID == (await transport.commands.first?.id))
    #expect(store.messages.count == 1)
    #expect(store.waitingForReply)
    #expect(store.deliveryState == "queued")
    await store.retryPending()
    #expect(await transport.commands.count == 1)
    await transport.setReply(); await store.refreshMessages()
    #expect(!store.waitingForReply)
    #expect(store.messages.map(\.text) == ["你好，你是什么模型？🙂", "收到中文🙂"])
}
@Test @MainActor func dotInboxIsNotEmptyUntilItsFirstSuccessfulLoad() async {
    let name = "DotsInbox.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    #expect(!store.hasLoadedInbox)
    await store.refreshInbox()
    #expect(store.hasLoadedInbox)
    #expect(store.threads.isEmpty)
    await transport.failConnection()
    await store.refreshInbox()
    #expect(store.hasLoadedInbox) // A later failure does not erase previous knowledge.
    #expect(store.errorCode == "network_unavailable")
}
@Test @MainActor func dotInboxInitialFailureIsNotReportedAsAnEmptyConversationList() async {
    let name = "DotsInbox.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    await transport.failConnection()
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.refreshInbox()
    #expect(!store.hasLoadedInbox)
    #expect(!store.isLoading)
    #expect(store.errorCode == "network_unavailable")
}
@Test @MainActor func dotEventLostAcknowledgementRecoversQueuedReceiptWithoutDuplicateSend() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.lostAcknowledgement)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    #expect(await transport.commands.count == 1)
    #expect(store.pending == nil)
    #expect(store.messages.map(\.text) == ["中文🙂"])
    #expect(store.waitingForReply)
}

@Test @MainActor func dotRecoveryCannotAcceptAReceiptWithChangedPayload() async {
    let name = "DotReceiptMismatch.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.lostAcknowledgement)
    await transport.changeReceiptText()
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("原文 cafe\u{0301} 🦦")
    #expect(store.pending?.text.utf8.elementsEqual("原文 cafe\u{0301} 🦦".utf8) == true)
    #expect(store.errorCode == "delivery_uncertain")
    #expect(await transport.commands.count == 1)
}
@Test @MainActor func dotEventPollingLoadsLatestRepliesWhileOlderPagesRemainAvailable() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued), root = UUID().uuidString.lowercased()
    let store = DotsStore(thread: root, configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    #expect(store.nextCursor == "30")
    await transport.setReply(); await store.refreshMessages()
    #expect(await transport.cursors.last! == nil)
    #expect(store.messages.last?.text == "收到中文🙂")
    await store.refreshMessages(more: true)
    #expect(await transport.cursors.last! == "30")
    #expect(store.nextCursor == nil)
    await store.refreshMessages()
    #expect(store.nextCursor == nil)
    #expect(store.messages.count == 2)
}
@Test @MainActor func dotEventTerminalFailuresDoNotWaitForeverOrRetryAutomatically() async {
    for mode in [EventStoreFixture.Mode.failed, .expired, .unsubscribed] {
        let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = EventStoreFixture(mode), store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
        await store.send("中文🙂")
        #expect(!store.waitingForReply)
        #expect(store.pending == nil)
        #expect(store.errorCode == (mode == .failed ? "delivery_failed" : (mode == .expired ? "expired" : "dot_not_subscribed")))
        #expect(await transport.commands.count == 1)
        #expect(store.recoverableDraft == "中文🙂")
        let restored = DotsStore(configuration: nil, defaults: defaults, transport: transport)
        #expect(restored.recoverableDraft == "中文🙂")
        #expect(restored.pending == nil)
        await transport.setMode(.queued)
        await restored.send("修改后的中文🙂")
        #expect(restored.recoverableDraft == nil)
        #expect(restored.waitingForReply)
        #expect(defaults.string(forKey: "dots.pending.events.v2.new.draft") == nil)
    }
}
@Test @MainActor func dotEventConnectionDoesNotRemainOnlineAfterNetworkFailure() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued), store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.refreshInbox(); #expect(store.connection?.connected == true)
    await transport.failConnection(); await store.refreshInbox()
    #expect(store.connection == nil)
    #expect(store.errorCode == "network_unavailable")
}

@Test @MainActor func dotContinuousChatResumesThreadAndPreservesFailedFollowup() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventStoreFixture(.queued)
    let first = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await first.send("第一轮🙂")
    let root = first.threadID
    await transport.setMode(.unsubscribed)
    await first.send("跟进原对话🙂")
    let resumed = DotsStore(resumeLastConversation: true, configuration: nil, defaults: defaults, transport: transport)
    #expect(resumed.threadID == root)
    #expect(resumed.recoverableDraft == "跟进原对话🙂")
    await transport.setMode(.queued)
    await resumed.send("修改后的跟进🙂")
    #expect(await transport.commands.last?.thread == root)
    #expect(resumed.recoverableDraft == nil)
}

@Test @MainActor func dotFailedNewMessageNeverResumesAnUnrelatedOldConversation() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old-conversation", forKey: "dots.active.\(DotsChannel.mcpEvents.rawValue)")
    let transport = EventStoreFixture(.unsubscribed)
    let fresh = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await fresh.send("新消息🙂")
    let resumed = DotsStore(resumeLastConversation: true, configuration: nil, defaults: defaults, transport: transport)
    #expect(resumed.threadID == nil)
    #expect(resumed.recoverableDraft == "新消息🙂")
    await resumed.prepareConversation()
    #expect(resumed.threadID == nil)
}

private actor EventHistoryFixture: DotsTransport {
    nonisolated let channel = DotsChannel.mcpEvents
    var history: [DotMessage] = []
    func setHistory(_ messages: [DotMessage]) { history = messages }
    func connection() async throws -> DotConnection { DotConnection(connected: true, dotName: "dot", verifiedAt: 1) }
    func threads(cursor: String?) async throws -> DotThreadPage { DotThreadPage(threads: [], nextCursor: nil) }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage {
        DotMessagePage(messages: history, nextCursor: nil, capturedAt: Date().timeIntervalSince1970 * 1000)
    }
    func send(_ command: DotCommand) async throws -> DotReceipt { throw DotsError("fixture_read_only") }
    func receipt(_ id: String) async throws -> DotReceipt { throw DotsError("receipt_not_found") }
}

@Test @MainActor func dotEventOutOfOrderReplyDoesNotHideAnotherPendingReply() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventHistoryFixture()
    let store = DotsStore(thread: UUID().uuidString.lowercased(), configuration: nil, defaults: defaults, transport: transport)
    let now = Date().timeIntervalSince1970 * 1000
    let first = DotMessage(id: "first.user", role: "user", text: "第一条", sentAt: now - 60_000, deliveryState: "replied")
    let second = DotMessage(id: "second.user", role: "user", text: "第二条", sentAt: now - 40_000, deliveryState: "delivered")
    let firstReply = DotMessage(id: "first.reply", role: "assistant", text: "第一条回复", sentAt: now - 1000)
    await transport.setHistory([first, second, firstReply])
    await store.refreshMessages()
    #expect(store.messages.last?.role == "assistant")
    #expect(store.waitingForReply)
    #expect(store.replyIsDelayed)
    let completedSecond = DotMessage(id: second.id, role: "user", text: second.text, sentAt: second.sentAt, deliveryState: "replied")
    await transport.setHistory([first, completedSecond, firstReply, DotMessage(id: "second.reply", role: "assistant", text: "第二条回复", sentAt: now)])
    await store.refreshMessages()
    #expect(!store.waitingForReply)
    #expect(!store.replyIsDelayed)
}

@Test @MainActor func dotEventFailedHistoryRestoresDraftDespiteAnOlderLateReply() async {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = EventHistoryFixture(), thread = UUID().uuidString.lowercased()
    let store = DotsStore(thread: thread, configuration: nil, defaults: defaults, transport: transport)
    await transport.setHistory([
        DotMessage(id: "old.user", role: "user", text: "旧消息", sentAt: 1, deliveryState: "replied"),
        DotMessage(id: "failed.user", role: "user", text: "需要恢复的中文🙂", sentAt: 2, deliveryState: "delivery_failed"),
        DotMessage(id: "old.reply", role: "assistant", text: "迟到的旧回复", sentAt: 3),
    ])
    await store.refreshMessages()
    #expect(store.errorCode == "delivery_failed")
    #expect(!store.waitingForReply)
    #expect(store.recoverableDraft == "需要恢复的中文🙂")
    let restored = DotsStore(thread: thread, configuration: nil, defaults: defaults, transport: transport)
    #expect(restored.recoverableDraft == store.recoverableDraft)
}

@Test @MainActor func dotEventRejectedExplicitRetryRestoresPersistedPendingText() async throws {
    let name = "DotsEvents.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let command = DotCommand(text: "待确认原文🙂", thread: nil)
    defaults.set(try JSONEncoder().encode(command), forKey: "dots.pending.events.v2.new")
    let transport = EventStoreFixture(.unsubscribed)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    #expect(store.pending == command)
    await store.retryPending()
    #expect(store.pending == nil)
    #expect(store.recoverableDraft == command.text)
    #expect(store.errorCode == "dot_not_subscribed")
    #expect(store.deliveryState == "rejected")
    #expect(await transport.commands == [command])
}
