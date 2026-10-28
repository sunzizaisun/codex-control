import SwiftUI

/// A separate channel to the user's real dot, not the retired Chat surface.
public struct DotsInboxView: View {
    @StateObject private var store = DotViewStore.make()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    private let select: ((String?) -> Void)?
    public init(select: ((String?) -> Void)? = nil) { self.select = select }
    public var body: some View {
        List {
            Section {
                if let select {
                    Button { select(nil) } label: { Label(t("dot 新消息"), systemImage: "square.and.pencil") }
                } else { NavigationLink { DotsConversationView() } label: {
                    Label(t("dot 新消息"), systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                }
            }
            if !store.configured { Text(t("dot 尚未配置")).foregroundStyle(.secondary) }
            if store.channel == .mcpEvents, let connection = store.connection {
                Label(t(connection.connected ? "dot 连接就绪" : "dot 尚未订阅"), systemImage: connection.connected ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.errorCode { DotsErrorRow(code: error) }
            Section(t("dot 对话")) {
                if store.threads.isEmpty {
                    if store.hasLoadedInbox {
                        Text(t(store.isLoading ? "正在加载…" : "dot 暂无对话")).foregroundStyle(.secondary)
                    } else if store.configured && store.errorCode == nil {
                        Text(t("正在加载…")).foregroundStyle(.secondary)
                    }
                }
                ForEach(store.threads) { thread in
                    if let select {
                        Button { select(thread.id) } label: {
                            Text(thread.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else { NavigationLink { DotsConversationView(thread: thread.id) } label: {
                        Text(thread.title).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    }
                }
                if store.hasMoreThreads { Button(t("dot 更多对话")) { Task { await store.refreshInbox(more: true) } } }
            }
            Section { Text(t(store.channel == .mcpEvents ? "dot 云端渠道说明" : "dot 渠道说明")).font(.caption).foregroundStyle(.secondary) }
        }
        .listStyle(.plain)
        .modifier(DotsScreenBackground())
        .navigationTitle("dot")
        .refreshable { await store.refreshInbox(reset: true) }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: scenePhase == .active && isVisible) {
            guard scenePhase == .active && isVisible else { return }
            await store.refreshInbox()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { break }
                await store.refreshInbox()
            }
        }
        .transaction { $0.animation = nil }
    }
    private func t(_ key: String) -> String {
        AppLocalizer.text(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }
}

public struct DotsConversationView: View {
    private let selectedThread: String?
    private let resumeLast: Bool
    public init(thread: String? = nil, resumeLastConversation: Bool = false) {
        selectedThread = thread
        resumeLast = resumeLastConversation
    }
    public var body: some View {
        DotsChatSessionView(thread: selectedThread, resumeLastConversation: resumeLast, unifiedConversation: selectedThread == nil)
    }
}

private struct DotsChatSessionView: View {
    @StateObject private var store: DotsStore
    @State private var draft = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var nearBottom = true
    @State private var scrollState = DotChatScrollState()
    @State private var renderedPendingID: String?
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    init(thread: String? = nil, resumeLastConversation: Bool = false, unifiedConversation: Bool = false) {
        _store = StateObject(wrappedValue: DotViewStore.make(thread: thread,
            resumeLastConversation: resumeLastConversation, unifiedConversation: unifiedConversation))
    }
    var body: some View { conversation }
    private var conversation: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
        ScrollView {
        LazyVStack(spacing: 12) {
            if !store.configured { Text(t("dot 尚未配置")).foregroundStyle(.secondary) }
            if let error = store.errorCode { DotsErrorRow(code: error) }
            if store.nextCursor != nil {
                Button(t("dot 更多消息")) { Task { await store.refreshMessages(more: true) } }.font(.caption)
            }
            if let error = store.historySyncError, error != store.errorCode { DotsErrorRow(code: error) }
            if store.historySync?.state == "pending" {
                HStack(spacing: 6) { ProgressView(); Text(t("dot 正在同步")) }.font(.caption).foregroundStyle(.secondary)
            } else if store.historySync?.state == "delayed" {
                Text(t("dot 同步延迟")).font(.caption).foregroundStyle(.secondary)
            } else if store.historySync?.truncated == true {
                Text(t("dot 近期记录")).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(store.messages) { message in
                HStack(alignment: .bottom, spacing: 0) {
                if message.role == "user" { Spacer(minLength: 14) }
                VStack(alignment: .leading, spacing: 5) {
                    #if os(watchOS)
                    Text(verbatim: message.text).font(.body)
                    #else
                    Text(verbatim: message.text).font(.body).textSelection(.enabled)
                    #endif
                    HStack(spacing: 5) {
                        Text(Date(timeIntervalSince1970: message.sentAt / 1000), style: .time)
                        if message.role == "user", let state = message.deliveryState {
                            Text(t(store.channel == .mcpEvents ? (message.eventDeliveryLabelKey ?? "dot 送达状态未确认") : (["delivery_failed", "expired"].contains(state) ? "dot 投递失败" : (state == "replied" || message.readAt != nil ? "dot 已收到" : "dot 已发送"))))
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if message.role == "user", ["queued", "delivered"].contains(message.deliveryState ?? "") {
                        // Tie delivery feedback to its actual message. An
                        // older unanswered input must not make a newer,
                        // successfully answered turn look stuck forever.
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            Text(t(context.date.timeIntervalSince1970 * 1000 - message.sentAt > 30_000 ? "dot 回复较慢" : "dot 等待回复"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if message.controlsInSlack { Text(t("dot 在 Slack 处理审批")).font(.caption).foregroundStyle(.orange) }
                }
                .padding(12)
                .background(message.role == "user" ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                if message.role != "user" { Spacer(minLength: 14) }
                }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                    .id(message.id)
            }
            if let pending = store.pending {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: pending.text).padding(12).background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
                    if store.isSending {
                        Text(t("dot 正在发送")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(t("dot 送达状态未确认")).font(.caption).foregroundStyle(.orange)
                        Button(t("dot 检查送达")) { Task { await store.retryPending() } }
                    }
                }.id("dot-pending")
            }
            Color.clear.frame(height: 1).id("dot-bottom")
                .background(GeometryReader { bottom in Color.clear.preference(key: DotBottomPreference.self, value: bottom.frame(in: .named("dot-chat-scroll")).maxY) })
        }.padding(.horizontal, 10).padding(.vertical, 12)
            .preference(key: DotRenderedContentPreference.self,
                value: DotRenderedContent(ids: store.messages.map(\.id), pendingID: store.pending?.id,
                                          initialLoadComplete: store.hasLoadedTimeline))
        }
        // A cold start restores cached/imported rows before the latest GET.
        // Give the completed first page a fresh native scroll view instead of
        // anchoring against estimated heights of an earlier lazy batch.
        .modifier(DotInitialScrollAnchor())
        .id(store.hasLoadedTimeline)
        .coordinateSpace(name: "dot-chat-scroll")
        .onPreferenceChange(DotBottomPreference.self) {
            nearBottom = DotChatScrollState.isNearBottom(bottomY: $0, viewportHeight: geometry.size.height)
        }
        // Scroll only after layout has published its rendered content. A
        // @Published willSet event can arrive before the destination exists.
        .onPreferenceChange(DotRenderedContentPreference.self) { content in
            let followMessages = scrollState.update(ids: content.ids, nearBottom: nearBottom,
                                                    initialLoadComplete: content.initialLoadComplete)
            let followPending = content.pendingID != nil && content.pendingID != renderedPendingID
            renderedPendingID = content.pendingID
            if followMessages || followPending {
                // A ForEach row is a resolvable lazy scroll target even when
                // the trailing sentinel has not been laid out yet.
                let target = content.pendingID == nil ? content.ids.last : "dot-pending"
                if let target { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .bottom) } }
            }
        }
        .refreshable { await store.refreshConversation() }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        }
        .modifier(DotsScreenBackground())
        .navigationTitle("dot")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onReceive(store.$recoverableDraft) { text in
            // Never replace a new draft the user is already editing.
            if draft.isEmpty, let text { draft = text }
        }
        .onAppear {
            isVisible = true
            if draft.isEmpty, let text = store.recoverableDraft { draft = text }
        }
        .onDisappear { isVisible = false }
        .task(id: scenePhase == .active && isVisible) {
            guard scenePhase == .active && isVisible else { return }
            await store.prepareConversation()
        }
        .task(id: DotForegroundRefreshKey(active: scenePhase == .active && isVisible,
                                          messageID: store.foregroundRefreshMessageID)) {
            while !Task.isCancelled,
                  let interval = store.foregroundRefreshInterval(active: scenePhase == .active && isVisible) {
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                guard !Task.isCancelled, scenePhase == .active && isVisible else { break }
                await store.refreshMessages()
            }
        }
        .transaction { $0.animation = nil }
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            #if os(watchOS)
            // watchOS presents its native input sheet from this control. A
            // vertical-axis field inside a safe-area inset otherwise expands
            // to the entire screen and hides the conversation above it.
            TextField(t("dot 输入消息"), text: $draft)
                .textFieldStyle(.plain).buttonStyle(.plain).font(.caption)
                .lineLimit(1).frame(maxWidth: .infinity).frame(height: 30)
                // The native Watch field already supplies its own fill. A
                // second background made a rectangle sit inside the capsule.
                .clipShape(Capsule())
                .contentShape(Capsule())
                .environment(\.locale, .autoupdatingCurrent)
                .accessibilityIdentifier("dot.messageInput")
            #else
            TextField(t("dot 输入消息"), text: $draft, axis: .vertical)
                .lineLimit(1...3).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("dot.messageInput")
            #endif
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.body.weight(.semibold))
                    .frame(width: sendButtonSize, height: sendButtonSize).background(Color.accentColor, in: Circle()).foregroundStyle(.white)
            }.buttonStyle(.plain).accessibilityLabel(t("dot 发送"))
                .accessibilityIdentifier("dot.send")
                .disabled(!store.configured || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending || store.pending != nil)
        }
        .padding(.horizontal, 10).padding(.vertical, 5).background(.ultraThinMaterial)
    }
    private var sendButtonSize: CGFloat {
        #if os(watchOS)
        30
        #else
        34
        #endif
    }
    private func t(_ key: String) -> String {
        AppLocalizer.text(key, language: AppLanguage(rawValue: languageRaw) ?? .system)
    }
    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if text.unicodeScalars.count <= 4000 {
            draft = ""
            // A fast receipt can add and clear pending before SwiftUI renders
            // it. An explicit send must still reveal the newly appended turn.
            scrollState.requestFollowNextAppend()
        }
        Task {
            await store.send(text)
            if store.deliveryState == "rejected" {
                scrollState.cancelFollowRequest()
                if draft.isEmpty { draft = text }
            }
        }
    }
}
private struct DotForegroundRefreshKey: Equatable {
    let active: Bool
    let messageID: String?
}

@MainActor
private enum DotViewStore {
    static func make(thread: String? = nil, resumeLastConversation: Bool = false,
                     unifiedConversation: Bool = false) -> DotsStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UIPreview") {
            // Offline UI fixtures must never read real drafts or send a
            // history-control event merely because their dot link is opened.
            // Real cloud acceptance uses -PreviewDotsShared without UIPreview.
            let defaults = UserDefaults(suiteName: "CodexControl.dot.offline-preview")!
            return DotsStore(thread: thread, configuration: nil, defaults: defaults)
        }
        #endif
        return DotsStore(thread: thread, resumeLastConversation: resumeLastConversation,
                         unifiedConversation: unifiedConversation)
    }
}

private struct DotBottomPreference: PreferenceKey {
    // An offscreen lazy sentinel supplies no measurement: that means the
    // user is not near the bottom, not that the bottom is at coordinate zero.
    static var defaultValue: CGFloat { .infinity }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct DotRenderedContent: Equatable {
    var ids: [String] = []
    var pendingID: String?
    var initialLoadComplete = false
}
private struct DotRenderedContentPreference: PreferenceKey {
    static var defaultValue: DotRenderedContent { .init() }
    static func reduce(value: inout DotRenderedContent, nextValue: () -> DotRenderedContent) { value = nextValue() }
}
private struct DotsErrorRow: View {
    let code: String
    var body: some View {
        Text(AppLocalizer.text(key)).font(.caption).foregroundStyle(.orange)
    }
    private var key: String {
        switch code {
        case "delivery_uncertain": "dot 送达状态未确认"
        case "invalid_auth", "token_revoked", "token_expired", "missing_scope", "unauthorized", "account_mismatch", "dot_mismatch": "dot 需要重新授权"
        case "rate_limited": "dot 请稍后重试"
        case "cloud_read_quota_exhausted": "dot 云端日额度耗尽"
        case "dot_not_subscribed": "dot 尚未订阅"
        case "expired", "delivery_failed": "dot 投递失败"
        case "invalid_text": "dot 消息太长"
        default: "dot 暂时无法连接"
        }
    }
}

private struct DotInitialScrollAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, watchOS 11, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            // Earlier systems keep the explicit ScrollViewReader fallback.
            content
        }
    }
}

private struct DotsScreenBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        ZStack {
            LinearGradient(colors: colorScheme == .light
                ? [Color(red: 0.88, green: 0.96, blue: 1), Color(red: 0.97, green: 0.98, blue: 1)]
                : [Color(red: 0.015, green: 0.025, blue: 0.09), .black],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            content.scrollContentBackground(.hidden)
        }
        .adaptiveWatchNavigationAppearance()
    }
}
