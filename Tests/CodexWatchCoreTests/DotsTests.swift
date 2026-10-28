import Foundation
import Testing
@testable import CodexWatchCore

@Test func dotAuthUsesASeparateKeyWithCrossPlatformDerivation() {
    let root = String(repeating: "a", count: 64)
    #expect(DotsConfiguration.derivedKey(relaySecret: root) == "N5VF3t3UPVLbVH9PDejo1xFaATWGYBfEcwKefA0Bb9k=")
    #expect(DotsConfiguration.derivedKey(relaySecret: root) != root)
    #expect(DotsConfiguration(baseURL: URL(string: "http://example.com")!, relaySecret: root) == nil)
    #expect(DotsConfiguration(baseURL: URL(string: "https://user:password@example.com")!, relaySecret: root) == nil)
    #expect(DotsConfiguration(baseURL: URL(string: "https://example.com/?secret=key")!, relaySecret: root) == nil)
}
@Test func dotUnicodePayloadAndFixedIDSurvivePersistence() throws {
    let command = DotCommand(text: "你好，你是什么模型？🙂", thread: "1791343731.898569", now: Date(timeIntervalSince1970: 1_791_343_731))
    let data = try JSONEncoder().encode(command)
    let roundtrip = try JSONDecoder().decode(DotCommand.self, from: data)
    #expect(roundtrip == command)
    #expect(roundtrip.id == command.id)
    #expect(roundtrip.text == "你好，你是什么模型？🙂")
    #expect(roundtrip.createdAt == 1_791_343_731_000)
}
@Test func dotRefreshMergesEditsWithoutDuplicatingOrRemovingRows() {
    let user = DotMessage(id: "1791343731.898569", role: "user", text: "你好", sentAt: 1)
    let partial = DotMessage(id: "1791343958.737019", role: "assistant", text: "回答…", sentAt: 2)
    let final = DotMessage(id: partial.id, role: "assistant", text: "回答完整🙂", sentAt: 2)
    #expect(DotMessage.merging([user, partial], [final]) == [user, final])
    #expect(DotMessage.merging([user, final], []) == [user, final])
    #expect(DotMessage.merging([user, final], [final, user]) == [user, final])
}
@Test func dotNewUIHasAllSupportedLanguages() {
    for language in AppLanguage.allCases where language != .system {
        for key in ["dot 新消息", "dot 尚未配置", "dot 对话", "dot 暂无对话", "dot 更多对话", "dot 渠道说明", "dot 你", "dot 在 Slack 处理审批", "dot 更多消息", "dot 等待回复", "dot 送达状态未确认", "dot 检查送达", "dot 输入消息", "dot 正在发送", "dot 发送", "dot 需要重新授权", "dot 请稍后重试", "dot 暂时无法连接", "dot 消息太长"] {
            let translation = DotsTranslations.text(key, language: language)
            #expect(translation != nil)
            #expect(translation?.isEmpty == false)
            #expect(AppLocalizer.text(key, language: language) == translation)
        }
    }
    #expect(AppLocalizer.text("dot 新消息", language: .english) == "New message")
    #expect(AppLocalizer.text("dot 发送", language: .simplifiedChinese) == "发送")
}

private actor DotsTestTransport: DotsTransport {
    enum Mode: Sendable { case lostAcknowledgement, unknownDelivery, pagination, inboxPagination }
    let mode: Mode
    var commands: [DotCommand] = []
    var queries: [(cursor: String?, after: String?)] = []
    var inboxQueries: [String?] = []
    var recovered = false
    var receiptUnavailable = false
    var receiptError: String?
    func recover() { recovered = true }
    func failReceipt() { receiptUnavailable = true }
    func denyReceipt() { receiptError = "unauthorized" }
    let root = "1791343731.898569"
    let reply = "1791343740.000001"
    init(_ mode: Mode) { self.mode = mode }
    func connection() async throws -> DotConnection { DotConnection(connected: true, dotName: "dot", verifiedAt: 1) }
    func threads(cursor: String?) async throws -> DotThreadPage {
        inboxQueries.append(cursor)
        guard mode == .inboxPagination else { return DotThreadPage(threads: [], nextCursor: nil) }
        let first = DotThread(id: "1791343740.000001", title: inboxQueries.count > 2 ? "标题已更新" : "最新对话", updatedAt: 2)
        let second = DotThread(id: root, title: "较早对话", updatedAt: 1)
        return cursor == nil
            ? DotThreadPage(threads: [first], nextCursor: "page-2")
            : DotThreadPage(threads: [second], nextCursor: nil)
    }
    func send(_ command: DotCommand) async throws -> DotReceipt {
        commands.append(command)
        if mode == .lostAcknowledgement { throw DotsError("delivery_uncertain") }
        return DotReceipt(id: command.id, state: "uncertain", thread: command.thread, timestamp: nil, error: "delivery_uncertain")
    }
    func receipt(_ id: String) async throws -> DotReceipt {
        if let receiptError { throw DotsError(receiptError) }
        if receiptUnavailable { throw DotsError("network_unavailable") }
        if mode == .unknownDelivery && !recovered { throw DotsError("receipt_not_found") }
        return DotReceipt(id: id, state: "sent", thread: root, timestamp: root, error: nil)
    }
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage {
        queries.append((cursor, after))
        let user = DotMessage(id: root, role: "user", text: "中文🙂", sentAt: 1)
        let assistant = DotMessage(id: reply, role: "assistant", text: after == nil ? "回复" : "回复已更新", sentAt: 2)
        if mode == .pagination {
            if after != nil { return DotMessagePage(messages: [assistant], nextCursor: nil, capturedAt: 1) }
            if cursor != nil { return DotMessagePage(messages: [assistant], nextCursor: nil, capturedAt: 1) }
            return DotMessagePage(messages: [user], nextCursor: "page-2", capturedAt: 1)
        }
        return DotMessagePage(messages: [user, assistant], nextCursor: nil, capturedAt: 1)
    }
}

@Test @MainActor func dotLostAcknowledgementRecoversWithoutResending() async {
    let name = "DotsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.lostAcknowledgement)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    #expect(await transport.commands.count == 1)
    #expect(store.pending == nil)
    #expect(store.deliveryState == "sent")
    #expect(store.threadID == "1791343731.898569")
    #expect(store.messages.map(\.text) == ["中文🙂", "回复"])
}

@Test @MainActor func dotCheckDeliveryReadsReceiptBeforeAnyExplicitRepost() async {
    let name = "DotCheckFirst.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.unknownDelivery)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    await transport.recover()
    await store.retryPending()
    #expect(await transport.commands.count == 1)
    #expect(store.pending == nil)
    #expect(store.deliveryState == "sent")
}

@Test @MainActor func dotCheckDeliveryDoesNotPostWhenReceiptReadFails() async {
    let name = "DotCheckOffline.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.unknownDelivery)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    let pending = store.pending
    await transport.failReceipt()
    await store.retryPending()
    #expect(await transport.commands.count == 1)
    #expect(store.pending == pending)
    #expect(store.errorCode == "network_unavailable")
}

@Test @MainActor func dotReceiptAuthorizationFailureCannotDiscardAnUncertainCommandID() async {
    let name = "DotReceiptDenied.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.unknownDelivery)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("可能已送达的原文🙂")
    let pending = store.pending
    await transport.denyReceipt()
    await store.retryPending()
    #expect(store.pending == pending)
    #expect(await transport.commands.count == 1)
    #expect(store.errorCode == "unauthorized")
    let restored = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    #expect(restored.pending == pending)
}

@Test @MainActor func dotPendingCommandsAreIsolatedByAccountAndGateway() async {
    let name = "DotCommandScope.\(UUID())", defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.unknownDelivery)
    func config(_ host: String, _ secret: String) -> DotsConfiguration {
        DotsConfiguration(baseURL: URL(string: "https://\(host)")!, relaySecret: String(repeating: secret, count: 64))!
    }
    let first = DotsStore(configuration: config("first.invalid", "a"), defaults: defaults, transport: transport)
    await first.send("账户一的草稿🦦")
    let restored = DotsStore(configuration: config("first.invalid", "a"), defaults: defaults, transport: transport)
    #expect(restored.pending == first.pending)
    for configuration in [config("first.invalid", "b"), config("second.invalid", "a")] {
        let other = DotsStore(configuration: configuration, defaults: defaults, transport: transport)
        #expect(other.pending == nil)
        #expect(other.recoverableDraft == nil)
    }
}
@Test @MainActor func dotUnknownDeliverySurvivesRelaunchWithTheSameID() async {
    let name = "DotsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.unknownDelivery)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.send("中文🙂")
    let original = store.pending
    let restored = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await restored.refreshMessages()
    #expect(restored.pending == original)
    #expect(await transport.commands.count == 1)
    await restored.retryPending()
    let commands = await transport.commands
    #expect(commands.count == 2)
    #expect(commands[0] == commands[1])
}
@Test @MainActor func dotPaginationDoesNotResetAfterPolling() async {
    let name = "DotsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.pagination)
    let store = DotsStore(thread: "1791343731.898569", configuration: nil, defaults: defaults, transport: transport)
    await store.refreshMessages()
    #expect(store.nextCursor == "page-2")
    await store.refreshMessages()
    #expect(store.nextCursor == nil)
    await store.refreshMessages()
    let queries = await transport.queries
    #expect(queries[1].cursor == "page-2")
    #expect(queries[2].after == "1791343740.000001")
    #expect(store.messages.map(\.text) == ["中文🙂", "回复已更新"])
    #expect(store.nextCursor == nil)
}

@Test @MainActor func dotInboxPollingKeepsExpandedPagesAndExplicitRefreshResetsThem() async {
    let name = "DotsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = DotsTestTransport(.inboxPagination)
    let store = DotsStore(configuration: nil, defaults: defaults, transport: transport)
    await store.refreshInbox()
    #expect(store.hasMoreThreads)
    await store.refreshInbox(more: true)
    #expect(store.threads.count == 2)
    #expect(!store.hasMoreThreads)
    await store.refreshInbox()
    #expect(store.threads.map(\.title) == ["标题已更新", "较早对话"])
    #expect(!store.hasMoreThreads)
    await store.refreshInbox(more: true)
    #expect(await transport.inboxQueries.count == 3)
    await store.refreshInbox(reset: true)
    #expect(store.threads.map(\.title) == ["标题已更新"])
    #expect(store.hasMoreThreads)
}
