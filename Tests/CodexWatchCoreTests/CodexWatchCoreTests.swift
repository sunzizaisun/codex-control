import Foundation
import Testing
@testable import CodexWatchCore

@Test func installedBuildLabelUsesActualBundleValues() {
    #expect(AppBuildInfo.displayValue(version: "0.2.0", build: "5") == "0.2.0 (5)")
    #expect(AppBuildInfo.displayValue(version: nil, build: "5") == "—")
    #expect(AppBuildInfo.displayValue(version: "0.2.0", build: nil) == "0.2.0")
}

@Test func pairingQRRejectsAmbiguityExpiryAndMalformedCodes() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let valid = "codexcontrol://pair?mac=Mac&code=012345&expires=1300"
    #expect(try PairingQRCodePayload.parse(valid, now: now).code == "012345")
    #expect(try PairingQRCodePayload.parse(valid, now: now).macName == "Mac")
    for payload in [valid + "&code=654321", "codexcontrol://pair?code=123456", "codexcontrol://pair?code=123456&expires=nan", "codexcontrol://pair?code=12345x&expires=1300", "codexcontrol://pair?code=１２３４５６&expires=1300", "https://pair?code=123456&expires=1300"] {
        #expect(throws: PairingQRCodePayload.Failure.invalid) { try PairingQRCodePayload.parse(payload, now: now) }
    }
    #expect(throws: PairingQRCodePayload.Failure.expired) { try PairingQRCodePayload.parse(valid, now: Date(timeIntervalSince1970: 1300)) }
}

@Test func refreshingLatestHistoryDoesNotResetTheOldestLoadedCursor() throws {
    let rows = (0..<55).map { ChatMessage(id: "m-\($0)", role: .assistant, text: "消息 \($0)") }
    var state = TaskHistoryState()
    let latest = try TaskHistoryPaging.page(messages: rows, request: TaskHistoryRequest(taskID: "task"))
    state.apply(latest)
    let older = try TaskHistoryPaging.page(messages: rows, request: TaskHistoryRequest(taskID: "task", beforeMessageID: latest.nextBeforeMessageID))
    state.apply(older)
    state.apply(latest)
    #expect(state.nextBeforeMessageID == older.nextBeforeMessageID)
    let first = try TaskHistoryPaging.page(messages: rows, request: TaskHistoryRequest(taskID: "task", beforeMessageID: older.nextBeforeMessageID))
    state.apply(first)
    state.apply(latest)
    #expect(state.nextBeforeMessageID == nil)
    #expect(state.messages.map(\.id) == rows.map(\.id))
}

@Test func approvalReviewRejectsRemovedChangedAndExpiredRequests() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let reviewed = ApprovalRequest(id: "r", taskID: "task", kind: .permissions,
        title: "Review", summary: "Review all paths", command: "echo safe",
        requestedPaths: ["/safe"], createdAt: now, expiresAt: now.addingTimeInterval(60),
        nonce: "nonce", requestDigest: "digest")
    #expect(try ApprovalReviewValidation.current(reviewed: reviewed, pending: [reviewed], now: now) == reviewed)
    #expect(throws: ApprovalReviewValidation.Failure.changed) {
        try ApprovalReviewValidation.current(reviewed: reviewed, pending: [], now: now)
    }
    var changed = reviewed
    changed.nonce = "new-nonce"
    #expect(throws: ApprovalReviewValidation.Failure.changed) {
        try ApprovalReviewValidation.current(reviewed: reviewed, pending: [changed], now: now)
    }
    changed = reviewed
    changed.command = "different command"
    #expect(throws: ApprovalReviewValidation.Failure.changed) {
        try ApprovalReviewValidation.current(reviewed: reviewed, pending: [changed], now: now)
    }
    #expect(throws: ApprovalReviewValidation.Failure.expired) {
        try ApprovalReviewValidation.current(reviewed: reviewed, pending: [reviewed], now: now.addingTimeInterval(60))
    }
}

@Test func taskHistoryPagesPreserveLongTextAndStableMessageOrder() throws {
    let messages = (0..<55).map { ChatMessage(id: "m-\($0)", role: $0 % 2 == 0 ? .user : .assistant,
        text: String(repeating: "长回复🙂", count: 500), createdAt: Date(timeIntervalSince1970: Double($0))) }
    let latest = try TaskHistoryPaging.page(messages: messages, request: TaskHistoryRequest(taskID: "task"), maximumEncodedBytes: 1_000_000)
    #expect(latest.messages.map(\.id) == messages.suffix(20).map(\.id))
    #expect(latest.messages.first?.text == messages.first?.text)
    #expect(latest.nextBeforeMessageID == "m-35")
    let older = try TaskHistoryPaging.page(messages: messages, request: TaskHistoryRequest(taskID: "task", beforeMessageID: latest.nextBeforeMessageID), maximumEncodedBytes: 1_000_000)
    var state = TaskHistoryState()
    state.apply(latest)
    state.apply(older)
    #expect(state.messages.map(\.id) == messages.suffix(40).map(\.id))
    state.apply(older)
    #expect(state.messages.count == 40)
    var compact = messages[54]
    compact.text = String(compact.text.prefix(600)) + "…"
    state.applyLive([compact])
    #expect(state.messages.last?.text == messages[54].text)
    let first = try TaskHistoryPaging.page(messages: messages, request: TaskHistoryRequest(taskID: "task", beforeMessageID: older.nextBeforeMessageID), maximumEncodedBytes: 1_000_000)
    state.apply(first)
    #expect(state.messages.map(\.id) == messages.map(\.id))
    #expect(state.nextBeforeMessageID == nil)
}

@Test func historyPageMergesAheadOfSeededLiveTailAndFitsWatchTransport() throws {
    let rows = (0..<30).map { ChatMessage(id: "m-\($0)", role: .assistant,
        text: String(repeating: "完整回复🙂", count: 250), createdAt: Date(timeIntervalSince1970: Double($0))) }
    let page = try TaskHistoryPaging.page(messages: rows, request: TaskHistoryRequest(taskID: "task"))
    #expect(page.messages.count < 20)
    let envelope = BridgeEnvelope(kind: .snapshot, senderDeviceID: "mac", taskHistoryPage: page)
    #expect(try CodexWatchCoding.makeEncoder().encode(envelope).count < 48_000)
    var state = TaskHistoryState()
    state.applyLive(Array(rows.suffix(4)))
    state.apply(page)
    #expect(state.messages.map(\.id) == page.messages.map(\.id))
    let huge = ChatMessage(id: "huge", role: .assistant, text: String(repeating: "全文", count: 20_000))
    let hugePage = try TaskHistoryPaging.page(messages: [huge], request: TaskHistoryRequest(taskID: "task"))
    #expect(hugePage.messages.first?.text == huge.text)
}

@Test func historyEnvelopeIsBackwardsCompatibleAndRejectsUnknownCursor() throws {
    let request = TaskHistoryRequest(taskID: "task", limit: 999)
    #expect(request.limit == 30)
    let envelope = BridgeEnvelope(sentAt: Date(timeIntervalSince1970: 123), kind: .requestSnapshot, senderDeviceID: "watch", taskHistoryRequest: request)
    let data = try CodexWatchCoding.makeEncoder().encode(envelope)
    #expect(try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data) == envelope)
    let old = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self,
        from: Data("{\"version\":3,\"messageID\":\"old\",\"sentAt\":0,\"kind\":\"requestSnapshot\",\"senderDeviceID\":\"watch\"}".utf8))
    #expect(old.taskHistoryRequest == nil && old.taskHistoryPage == nil)
    #expect(throws: TaskHistoryPaging.Failure.self) {
        try TaskHistoryPaging.page(messages: [], request: TaskHistoryRequest(taskID: "task", beforeMessageID: "missing"))
    }
}

@Test func messageDraftOnlyClearsAfterAcceptanceAndRetainsFailures() {
    var draft = MessageDraft()
    draft.text = "你好，你是什么模型？"
    draft.submitted("request-1")
    #expect(!draft.text.isEmpty)
    draft.apply(nil)
    #expect(draft.submissionID == "request-1")
    draft.apply(.failed("offline"))
    #expect(draft.text == "你好，你是什么模型？" && draft.errorMessage == "offline")
    draft.submitted("request-2")
    draft.text = "新的草稿"
    draft.apply(.accepted)
    #expect(draft.text == "新的草稿")
    draft.submitted("request-3")
    draft.apply(.accepted)
    #expect(draft.text.isEmpty)
    var receipts = CommandReceipts()
    for index in 0..<100 { receipts.record(.accepted, for: "r-\(index)") }
    #expect(receipts.result(for: "r-0") == nil)
    #expect(receipts.result(for: "r-99") == .accepted)
}

@Test func newHistoryAndWidgetTextCoverEverySupportedLanguage() {
    let keys = ["加载较早的消息", "正在加载…", "无法加载聊天记录，请重试", "重试", "上次确认的状态", "中继不可用", "系统允许实时活动", "活动显示与后台刷新由系统管理，信息可能暂时滞后。", "佩戴并解锁手表，启用腕部检测后批准", "请佩戴并解锁手表，开启腕部检测后重试"]
    for language in AppLanguage.allCases where language != .system && language != .simplifiedChinese {
        for key in keys { #expect(AppLocalizer.text(key, language: language) != key) }
    }
}

@Test func compactDashboardNeverShortensAnApprovalBeingReviewed() throws {
    var snapshot = DashboardSnapshot.uiPreview()
    var request = try #require(snapshot.pendingApprovals.first)
    request.command = String(repeating: "echo 安全检查; ", count: 200)
    request.requestedPaths = (0..<20).map { "/a/long/path/\($0)/" + String(repeating: "目录", count: 100) }
    snapshot.pendingApprovals = [request]
    let compact = snapshot.compactForWatch(maximumTasks: 1, messagesPerTask: 0, maximumTextLength: 20, maximumApprovals: 1)
    #expect(compact.pendingApprovals == [request])
}

@Test func idleRelayHeartbeatDoesNotBecomePrematurelyOffline() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(RelayTimingPolicy.isFresh(now.addingTimeInterval(-60), now: now))
    #expect(RelayTimingPolicy.isFresh(now.addingTimeInterval(-125), now: now))
    #expect(!RelayTimingPolicy.isFresh(now.addingTimeInterval(-151), now: now))
    #expect(!RelayTimingPolicy.isFresh(now.addingTimeInterval(1), now: now))
    #expect(RelayTimingPolicy.snapshotFreshness > RelayTimingPolicy.idleInterval * 2)
}

@Test func forwardedCacheAndReceiptsDoNotRenewMacPresence() {
    let now = Date(timeIntervalSince1970: 2_000)
    let old = DashboardSnapshot(bridgeConnected: true, capturedAt: now.addingTimeInterval(-180))
    let forwarded = BridgeEnvelope(sentAt: now, kind: .snapshot, senderDeviceID: "phone", snapshot: old)
    #expect(RelayTimingPolicy.isFresh(forwarded.sentAt, now: now))
    #expect(!old.isMacOnline(now: now))
    #expect(!old.reconcilingMacPresence(now: now).bridgeConnected)
    #expect(BridgeEnvelope.acknowledgement(for: "queued", sender: "phone").snapshot == nil)
    let live = DashboardSnapshot(bridgeConnected: true, capturedAt: now.addingTimeInterval(-60))
    #expect(live.isMacOnline(now: now))
    #expect(!live.isMacOnline(now: now.addingTimeInterval(91)))
    #expect(!DashboardSnapshot(bridgeConnected: false, capturedAt: now).isMacOnline(now: now))
    #expect(!DashboardSnapshot(bridgeConnected: true, capturedAt: now.addingTimeInterval(1)).isMacOnline(now: now))
}

@Test func actionRetriesAreBoundedAndFailedUploadCanRecover() {
    var gate = RelayRetryGate()
    let now = Date(timeIntervalSince1970: 3_000)
    let first = gate.begin("command", now: now)
    let concurrent = gate.begin("command", now: now.addingTimeInterval(30))
    #expect(first && !concurrent)
    gate.finish("command")
    let tooSoon = gate.begin("command", now: now.addingTimeInterval(5))
    let retry = gate.begin("command", now: now.addingTimeInterval(15))
    let different = gate.begin("different-command", now: now)
    #expect(!tooSoon && retry && different)
    gate.finish("command")
    gate.retainOnly(["different-command"])
    let afterCleanup = gate.begin("command", now: now.addingTimeInterval(16))
    #expect(afterCleanup)
}

@Test func relayRetryDeadlinesMatchPacketLifetime() {
    let command = BridgeEnvelope(sentAt: Date(timeIntervalSince1970: 100), kind: .taskCommand, senderDeviceID: "watch")
    let decision = BridgeEnvelope(sentAt: Date(timeIntervalSince1970: 100), kind: .approvalDecision, senderDeviceID: "watch")
    #expect(command.deliveryExpiresAt.timeIntervalSince1970 == 86_500)
    #expect(decision.deliveryExpiresAt.timeIntervalSince1970 == 1_000)
}

@Test func watchRelayNeverUsesSimulatorOnlyWebSockets() {
    #expect(!RelayTransportPolicy.supportsMailboxWebSocket(on: .watchOS))
    #expect(RelayTransportPolicy.supportsMailboxWebSocket(on: .iOS))
    #expect(RelayTransportPolicy.supportsMailboxWebSocket(on: .macOS))
}

@Test func cancelledRefreshIsNotAConnectivityFailure() {
    #expect(RelayTransportPolicy.isCancellation(CancellationError()))
    #expect(RelayTransportPolicy.isCancellation(URLError(.cancelled)))
    #expect(RelayTransportPolicy.isCancellation(NSError(domain: NSURLErrorDomain, code: -999)))
    #expect(!RelayTransportPolicy.isCancellation(URLError(.notConnectedToInternet)))
    #expect(!RelayTransportPolicy.isCancellation(URLError(.timedOut)))
    #expect(!RelayTransportPolicy.isCancellation(RemoteRelayError.authenticationFailed))
}

@Test func watchRadioWaitIsBoundedForAppAndWidget() {
    let app = RelayTransportPolicy.watchSessionConfiguration(timeout: 10, waitsForConnectivity: true)
    #expect(app.waitsForConnectivity)
    #expect(app.timeoutIntervalForRequest == 10)
    #expect(app.timeoutIntervalForResource == 10)
    let widget = RelayTransportPolicy.watchSessionConfiguration(timeout: 8, waitsForConnectivity: false)
    #expect(!widget.waitsForConnectivity)
    #expect(widget.timeoutIntervalForResource == 8)
}

@Test func watchCompanionReplyIsSentExactlyOnce() {
    let recorder = RelayReplyRecorder()
    let reply = RelayDataReply { recorder.record($0) }
    #expect(reply.send(Data("fresh".utf8)))
    #expect(!reply.send(Data("deadline".utf8)))
    #expect(recorder.values == [Data("fresh".utf8)])
}

@Test func watchCompanionReplyDeadlineAndNetworkRaceHaveOneWinner() async {
    let recorder = RelayReplyRecorder()
    let reply = RelayDataReply { recorder.record($0) }
    let winners = await withTaskGroup(of: Int.self) { group in
        for index in 0..<100 {
            group.addTask { reply.send(Data("result-\(index)".utf8)) ? 1 : 0 }
        }
        var total = 0
        for await count in group { total += count }
        return total
    }
    #expect(winners == 1)
    #expect(recorder.values.count == 1)
}

private final class RelayReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    func record(_ data: Data) {
        lock.lock()
        stored.append(data)
        lock.unlock()
    }
    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Test func unavailableUsageIsNotPresentedAsAnExhaustedBalance() {
    #expect(UsagePresentation.remainingText(nil) == "—")
    #expect(UsagePresentation.remainingText(UsageWindow(usedPercent: 100)) == "0%")
    #expect(UsagePresentation.remainingText(UsageWindow(usedPercent: 36)) == "64%")
    #expect(UsagePresentation.remainingFraction(nil) == 0)
    #expect(UsagePresentation.remainingFraction(UsageWindow(usedPercent: 36)) == 0.64)
}

@Test func shortcutChatURLRoundTrip() throws {
    let requestID = "request-1"
    let chatID = "shortcut-chat:chat-1"
    let url = try #require(ShortcutChatBridge.runURL(
        prompt: "你好，你是什么模型？",
        requestID: requestID,
        chatID: chatID
    ))
    #expect(url.scheme == "shortcuts")

    var callback = URLComponents()
    callback.scheme = ShortcutChatBridge.callbackScheme
    callback.host = ShortcutChatBridge.callbackHost
    callback.path = "/success"
    callback.queryItems = [
        URLQueryItem(name: "request", value: requestID),
        URLQueryItem(name: "chat", value: chatID),
        URLQueryItem(name: "result", value: "我是 ChatGPT。"),
    ]
    let callbackURL = try #require(callback.url)
    let parsed = try #require(ShortcutChatBridge.parseCallback(callbackURL))
    #expect(parsed.outcome == .success)
    #expect(parsed.requestID == requestID)
    #expect(parsed.chatID == chatID)
    #expect(parsed.result == "我是 ChatGPT。")
}

@Test func shortcutChatContextIncludesNewestMessage() {
    let messages = [
        ChatMessage(id: "1", role: .user, text: "你好"),
        ChatMessage(id: "2", role: .assistant, text: "你好！"),
    ]
    let result = ShortcutChatBridge.contextualPrompt(
        newMessage: "你是什么模型？",
        messages: messages
    )
    #expect(result.contains("User: 你好"))
    #expect(result.contains("Assistant: 你好！"))
    #expect(result.hasSuffix("User: 你是什么模型？"))
}

@Test func usageRemainingPercentIsClamped() {
    #expect(UsageWindow(usedPercent: 11).remainingPercent == 89)
    #expect(UsageWindow(usedPercent: 120).remainingPercent == 0)
}

@Test func dynamicRelayStatusIsLocalizedAsOneMessage() {
    let defaults = UserDefaults.standard
    let key = AppPreferenceKeys.language
    let previous = defaults.object(forKey: key)
    defer {
        if let previous {
            defaults.set(previous, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    defaults.set(AppLanguage.english.rawValue, forKey: key)
    #expect(
        AppLocalizer.format("%@，远程中继在线", "Connected app-server session")
            == "Connected app-server session, remote relay online"
    )
    #expect(
        AppLocalizer.format("%@，正在验证远程中继", "Local app-server session")
            == "Local app-server session, verifying the remote relay"
    )
}

@Test func remoteApprovalPresentationFollowsTheSelectedLanguage() {
    #expect(
        AppLocalizer.localizedRemote("Codex 希望运行一条命令", language: .spanish)
            == "Codex quiere ejecutar un comando"
    )
    #expect(
        AppLocalizer.localizedRemote("运行命令", language: .spanish)
            == "Ejecutar comando"
    )
    #expect(
        AppLocalizer.localizedRemote("Codex quiere ejecutar un comando", language: .japanese)
            == "Codex はコマンドの実行を求めています"
    )
}

@Test func approvalAndSettingsCopyIsCoveredForEverySupportedLanguage() {
    let supportedLanguages = AppLanguage.allCases.filter { $0 != .system }
    let requiredKeys = [
        "审批",
        "语言",
        "外观",
        "实时活动",
        "iPhone 批准会先要求 Face ID",
        "佩戴手表并双击侧边按钮完成批准",
        "运行命令",
        "批准一次",
    ]

    for language in supportedLanguages {
        for key in requiredKeys {
            let localized = AppLocalizer.text(key, language: language)
            #expect(!localized.isEmpty)
            if language == .simplifiedChinese {
                #expect(localized == key)
            } else {
                #expect(localized != key)
            }
            if language != .english && language != .simplifiedChinese {
                #expect(localized != AppLocalizer.text(key, language: .english))
            }
        }
    }

    let historyKey = "会创建并保存到你的 ChatGPT 历史记录。"
    #expect(
        AppLocalizer.text(historyKey, language: .spanish)
            == "Esto crea un chat y lo guarda en tu historial de ChatGPT."
    )
    #expect(
        AppLocalizer.text(historyKey, language: .japanese)
            == "Chat を作成し、ChatGPT の履歴に保存します。"
    )
}

@Test func operationalDashboardCopyDoesNotFallBackToEnglish() {
    let keys = [
        "可重置 %@ 次",
        "同步时间 %@",
        "最近同步 %@",
        "Mac 拒绝了配对请求，请确认最新六码和本地网络权限",
        "Mac 没有接受配对请求，请确认最新六码和本地网络权限",
        "有效期 %@",
        "自动更新",
        "更新验证码",
        "重置 iPhone 配对",
        "配对二维码已过期，请在 Mac 上更新",
    ]

    for language in AppLanguage.allCases where language != .system && language != .simplifiedChinese && language != .english {
        for key in keys {
            let localized = AppLocalizer.text(key, language: language)
            #expect(!localized.isEmpty)
            #expect(localized != AppLocalizer.text(key, language: .english))
            #expect(localized != key)
        }
    }
}

@Test func macControlSurfaceDoesNotFallBackToEnglish() {
    let macKeys = [
        "Codex 任务", "设备", "Token 余额", "远程中继在线", "远程中继正在恢复",
        "已接通电源，本地控制可用", "电池供电，不保持唤醒", "自动可信连接",
        "iPhone 已配对", "配对二维码已移至设置的设备连接中", "启动新任务",
        "让 Codex 做什么？", "启动受控任务", "任务详情", "发送指令", "告诉 Codex 接下来做什么",
        "发送", "动态配对二维码", "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。",
        "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。",
        "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复",
    ]

    for language in AppLanguage.allCases where language != .system && language != .simplifiedChinese && language != .english {
        for key in macKeys {
            let localized = AppLocalizer.text(key, language: language)
            #expect(!localized.isEmpty)
            #expect(localized != key)
            #expect(localized != AppLocalizer.text(key, language: .english))
        }
    }
}

@Test func recentTasksRemainStableWhenRelaySnapshotOmitsThem() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let recentChat = AgentTask(
        id: "chatgpt-chat:recent",
        title: "First question",
        state: .running,
        model: "ChatGPT",
        updatedAt: now.addingTimeInterval(-8),
        messages: [ChatMessage(id: "user-1", role: .user, text: "First question", createdAt: now.addingTimeInterval(-8))],
        isNativeChat: true,
        isChat: true
    )
    let oldTask = AgentTask(
        id: "old-task",
        title: "Old task",
        state: .completed,
        updatedAt: now.addingTimeInterval(-30 * 60)
    )
    let previous = DashboardSnapshot(
        tasks: [recentChat, oldTask],
        bridgeConnected: true,
        capturedAt: now.addingTimeInterval(-8)
    )
    let incoming = DashboardSnapshot(
        tasks: [],
        bridgeConnected: true,
        capturedAt: now
    )

    let merged = incoming.mergingRecentTasks(from: previous, now: now)
    #expect(merged.tasks.map(\.id) == [recentChat.id])
    #expect(merged.tasks.first?.messages.first?.text == "First question")
}

@Test func envelopeRoundTrip() throws {
    let request = ApprovalRequest(
        id: "approval-1",
        taskID: "thread-1",
        kind: .command,
        title: "运行命令",
        summary: "测试",
        command: "swift test",
        createdAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 200),
        nonce: "nonce",
        requestDigest: "digest"
    )
    let snapshot = DashboardSnapshot(
        tasks: [],
        pendingApprovals: [request],
        bridgeConnected: true,
        capturedAt: Date(timeIntervalSince1970: 120)
    )
    let envelope = BridgeEnvelope(
        messageID: "message-1",
        sentAt: Date(timeIntervalSince1970: 120),
        kind: .snapshot,
        senderDeviceID: "mac",
        snapshot: snapshot
    )
    let data = try CodexWatchCoding.makeEncoder().encode(envelope)
    let decoded = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
    #expect(decoded == envelope)
}

@Test func taskCommandRoundTripPreservesConversationTarget() throws {
    let command = TaskCommand(
        id: "command-1",
        taskID: "thread-1",
        prompt: "继续并总结结果",
        activeTurnID: "turn-1",
        sentAt: Date(timeIntervalSince1970: 300),
        deviceID: "watch",
        executionTarget: .browser
    )
    let envelope = BridgeEnvelope.taskCommand(command, sender: "watch")
    let data = try CodexWatchCoding.makeEncoder().encode(envelope)
    let decoded = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: data)
    #expect(decoded.taskCommand == command)
    #expect(decoded.taskCommand?.executionTarget == .browser)
    #expect(decoded.kind == .taskCommand)
}

@Test func chatAndCodexCommandIdentifiersCannotShareARoute() {
    let legacyChat = TaskCommand(
        id: "legacy-chat",
        taskID: TaskCommand.legacyNewChatTaskID,
        prompt: "你是什么模型",
        deviceID: "watch"
    )
    let nativeChat = TaskCommand(
        id: "native-chat",
        taskID: TaskCommand.newNativeChatTaskID,
        prompt: "你是什么模型",
        deviceID: "watch"
    )
    let codex = TaskCommand(
        id: "codex",
        taskID: TaskCommand.newChatTaskID,
        prompt: "Run the tests",
        deviceID: "watch"
    )

    #expect(legacyChat.startsNativeChat)
    #expect(legacyChat.targetsBrowserChat)
    #expect(legacyChat.nativeChatProjectionID == "chatgpt-chat:legacy-chat")
    #expect(!legacyChat.startsNewCodexChat)

    #expect(nativeChat.startsNativeChat)
    #expect(nativeChat.targetsBrowserChat)
    #expect(nativeChat.nativeChatProjectionID == "chatgpt-chat:native-chat")
    #expect(!nativeChat.startsNewCodexChat)

    #expect(codex.startsNewCodexChat)
    #expect(!codex.startsNativeChat)
    #expect(!codex.targetsBrowserChat)
    #expect(codex.nativeChatProjectionID == nil)

    let followUp = TaskCommand(
        id: "follow-up",
        taskID: "chatgpt-chat:native-chat",
        prompt: "继续",
        deviceID: "watch"
    )
    #expect(followUp.targetsBrowserChat)
}

@Test func browserChatSnapshotDoesNotReplaceMacOwnedDashboardData() {
    let macTask = AgentTask(
        id: "codex-task",
        title: "Run tests",
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 100),
        isBridgeManaged: true
    )
    let oldChat = AgentTask(
        id: "chatgpt-chat:one",
        title: "Old title",
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 90),
        isNativeChat: true,
        isChat: true
    )
    let newChat = AgentTask(
        id: "chatgpt-chat:one",
        title: "ChatGPT sidebar title",
        state: .idle,
        updatedAt: Date(timeIntervalSince1970: 110),
        messages: [
            ChatMessage(
                id: "answer",
                role: .assistant,
                text: "Done",
                createdAt: Date(timeIntervalSince1970: 110)
            )
        ],
        isNativeChat: true,
        isChat: true
    )
    let mac = DashboardSnapshot(
        tasks: [macTask, oldChat],
        pendingApprovals: [],
        bridgeConnected: true,
        capturedAt: Date(timeIntervalSince1970: 100)
    )
    let browser = DashboardSnapshot(
        tasks: [newChat],
        bridgeConnected: true,
        capturedAt: Date(timeIntervalSince1970: 110)
    )

    let merged = mac.mergingChatSnapshot(browser)
    #expect(merged.bridgeConnected)
    #expect(merged.tasks.contains(where: { $0.id == macTask.id }))
    #expect(merged.tasks.first(where: { $0.id == newChat.id })?.title == "ChatGPT sidebar title")
    #expect(merged.tasks.first(where: { $0.id == newChat.id })?.messages.last?.text == "Done")
}

@Test func retiredBrowserGatewayNeverActivatesEvenWithLegacyChatSecret() throws {
    let baseURL = URL(string: "https://relay.example")!
    let disabled = try RemoteRelayConfiguration(
        baseURL: baseURL,
        roomID: "room",
        secret: String(repeating: "r", count: 32),
        browserGatewayEnabled: true
    )
    #expect(disabled.chatSecret == nil)
    #expect(disabled.browserGatewayEnabled == false)

    let enabled = try RemoteRelayConfiguration(
        baseURL: baseURL,
        roomID: "room",
        secret: String(repeating: "r", count: 32),
        chatSecret: String(repeating: "c", count: 32),
        browserGatewayEnabled: true
    )
    #expect(enabled.chatSecret?.count == 32)
    #expect(enabled.browserGatewayEnabled == false)
}

@Test func snapshotVisualEquivalenceIgnoresTransportTimestamps() {
    let firstTask = AgentTask(
        id: "task-1",
        title: "A stable task",
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 100),
        messages: [
            ChatMessage(
                id: "message-1",
                role: .assistant,
                text: "same answer",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ]
    )
    let secondTask = AgentTask(
        id: "task-1",
        title: "A stable task",
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 200),
        messages: [
            ChatMessage(
                id: "message-1",
                role: .assistant,
                text: "same answer",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ]
    )
    let first = DashboardSnapshot(
        tasks: [firstTask],
        bridgeConnected: true,
        capturedAt: Date(timeIntervalSince1970: 100)
    )
    var second = DashboardSnapshot(
        tasks: [secondTask],
        bridgeConnected: true,
        capturedAt: Date(timeIntervalSince1970: 200)
    )

    #expect(first.isVisuallyEquivalent(to: second))
    second.tasks[0].messages[0].text = "new answer"
    #expect(!first.isVisuallyEquivalent(to: second))
}

@Test func nativeChatDraftIsVisibleBeforeTheFirstRemoteHeartbeat() throws {
    var snapshot = DashboardSnapshot.empty
    let now = Date(timeIntervalSince1970: 500)
    snapshot.upsertNativeChatDraft(
        id: "chatgpt-chat:command-1",
        prompt: "  你是什么模型？  ",
        messageID: "command-1",
        now: now
    )

    let task = try #require(snapshot.tasks.first)
    #expect(task.id == "chatgpt-chat:command-1")
    #expect(task.title == "你是什么模型？")
    #expect(task.state == .running)
    #expect(task.isNativeChat)
    #expect(task.isChat)
    #expect(task.messages.first?.text == "你是什么模型？")

    // A duplicate WatchConnectivity delivery must not add a second user row.
    snapshot.upsertNativeChatDraft(
        id: "chatgpt-chat:command-1",
        prompt: "你是什么模型？",
        messageID: "command-1",
        now: now.addingTimeInterval(1)
    )
    #expect(snapshot.tasks.count == 1)
    #expect(snapshot.tasks.first?.messages.count == 1)
}

@Test func compatibleReplyCanUseTheRequestProtocolVersion() {
    let snapshot = DashboardSnapshot.empty
    let reply = BridgeEnvelope.snapshot(snapshot, sender: "mac", version: 1)
    let acknowledgement = BridgeEnvelope.acknowledgement(
        for: "old-command",
        sender: "mac",
        version: 1
    )
    #expect(reply.version == 1)
    #expect(acknowledgement.version == 1)
}

@Test func internalRealtimeArtifactsAreNeverShownAsTasks() {
    let internalTask = AgentTask(
        id: "internal",
        title: "<realtime_delegation><input>hidden</input>",
        state: .idle,
        updatedAt: .now
    )
    let normalTask = AgentTask(
        id: "normal",
        title: "Prepare project brief",
        state: .idle,
        updatedAt: .now
    )
    #expect(!AgentTaskPresentation.isVisible(internalTask))
    #expect(AgentTaskPresentation.isVisible(normalTask))
}
