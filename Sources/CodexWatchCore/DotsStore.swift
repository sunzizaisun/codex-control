import Combine
import CryptoKit
import Foundation

@MainActor
public final class DotsStore: ObservableObject {
    @Published public private(set) var threads: [DotThread] = []
    @Published public private(set) var messages: [DotMessage] = []
    @Published public private(set) var connection: DotConnection?
    @Published public private(set) var threadID: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoadedInbox = false
    /// Restored import rows are not proof that the latest timeline GET finished.
    @Published public private(set) var hasLoadedTimeline = false
    @Published public private(set) var isSending = false
    @Published public private(set) var pending: DotCommand?
    @Published public private(set) var deliveryState: String?
    @Published public private(set) var errorCode: String?
    @Published public private(set) var nextCursor: String?
    @Published public private(set) var recoverableDraft: String?
    @Published public private(set) var historySync: DotHistorySyncReceipt?
    @Published public private(set) var historySyncError: String?
    private var requestingHistory = false
    private var lastHistoryRequest = Date.distantPast
    private var restoredCompletedHistory = false
    private var hiddenHistoryMessageIDs: Set<String> = []
    private struct SavedHistorySync: Codable {
        let receipt: DotHistorySyncReceipt
        let requestedAt: Date
    }
    private let historyPersistenceKey: String
    private let client: (any DotsTransport)?
    private let defaults: UserDefaults
    private var persistenceKey: String
    private let persistenceScope: String
    private var retryAt = Date.distantPast
    private var consecutiveRefreshFailures = 0
    private var historyLoaded = false
    private var eventPagination = DotTimelinePagination()
    private var nextThreadCursor: String?
    private var loadedMoreThreads = false
    private var lastOlderReceiptCheck = Date.distantPast
    private var olderReceiptOffset = 0
    private static let definitiveRejections: Set<String> = ["invalid_text", "invalid_id", "unexpected_field", "invalid_date", "stale_command", "invalid_thread", "invalid_params", "thread_not_found", "dot_not_subscribed", "inbox_full", "unauthorized", "rate_limited"]
    public let channel: DotsChannel
    private let resumeLastConversation: Bool
    private let unifiedConversation: Bool
    private var activeThreadKey: String { "dots.active.\(channel.rawValue)" + persistenceScope }
    public var configured: Bool { client != nil }
    /// A stable wake key makes a new send interrupt an idle 12-second sleep.
    /// Pending -> accepted uses the same key, so it doesn't restart twice.
    public var foregroundRefreshMessageID: String? {
        if let pending { return pending.id }
        guard let id = unansweredMessages.max(by: { $0.sentAt < $1.sentAt })?.id else {
            // Wake a visible idle conversation when an explicit history sync
            // starts. Keep this key after completion to avoid canceling the
            // in-flight timeline read that is applying its result.
            return historySync.map { "history." + $0.id }
        }
        return id.hasSuffix(".user") ? String(id.dropLast(5)) : id
    }
    public func foregroundRefreshInterval(active: Bool, now: Date = Date()) -> TimeInterval? {
        guard configured else { return nil }
        let newest = pending.map { Date(timeIntervalSince1970: Double($0.createdAt) / 1000) }
            ?? unansweredMessages.map { Date(timeIntervalSince1970: $0.sentAt / 1000) }.max()
        let interval = DotForegroundRefreshPolicy.interval(active: active, latestPendingAt: newest,
            failures: consecutiveRefreshFailures, retryAt: retryAt, now: now,
            latestActivityAt: messages.map { Date(timeIntervalSince1970: $0.sentAt / 1000) }.max())
        if historySync?.state == "pending", consecutiveRefreshFailures == 0, now >= retryAt, let interval {
            return min(interval, 3)
        }
        return interval
    }
    public var waitingForReply: Bool {
        pending == nil && !unansweredMessages.isEmpty
    }
    private var unansweredMessages: [DotMessage] {
        if channel == .mcpEvents {
            // A late reply to an earlier input can be the last visible row
            // while another input is still waiting. Use each durable receipt.
            return messages.filter { $0.role == "user" && ["queued", "delivered"].contains($0.deliveryState ?? "") }
        }
        guard let last = messages.last, last.role == "user" else { return [] }
        return ["delivery_failed", "expired"].contains(last.deliveryState ?? "") ? [] : [last]
    }
    public var replyIsDelayed: Bool {
        waitingForReply && unansweredMessages.contains { Date().timeIntervalSince1970 * 1000 - $0.sentAt > 30_000 }
    }
    public init(thread: String? = nil, resumeLastConversation: Bool = false, unifiedConversation: Bool = false, configuration: DotsConfiguration? = .fromMainBundle(), defaults: UserDefaults = .standard, transport: (any DotsTransport)? = nil) {
        self.defaults = defaults
        self.channel = transport?.channel ?? configuration?.channel ?? .slack
        self.resumeLastConversation = resumeLastConversation
        self.unifiedConversation = unifiedConversation && self.channel == .mcpEvents
        // Keep only control metadata across relaunch, not message bodies or
        // credentials. Changing gateway/account credentials isolates the ID.
        let historyScope = configuration.map {
            SHA256.hash(data: Data(($0.baseURL.absoluteString + "|" + $0.authKey).utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "fixture"
        self.historyPersistenceKey = "dots.history.events.shared." + historyScope
        // Do not adopt legacy unscoped drafts under new credentials: their
        // owner cannot be proven. Leave those records intact for recovery.
        self.persistenceScope = configuration == nil ? "" : "." + historyScope
        let newKey = "dots.pending.\(channel == .mcpEvents ? "events.v2" : "v1").new" + persistenceScope
        let hasUnfinishedNewMessage = defaults.data(forKey: newKey) != nil || defaults.string(forKey: newKey + ".draft") != nil
        let resolvedThread = thread ?? (resumeLastConversation && !hasUnfinishedNewMessage ? defaults.string(forKey: "dots.active.\(channel.rawValue)" + persistenceScope) : nil)
        self.threadID = resolvedThread
        self.persistenceKey = (self.unifiedConversation ? "dots.pending.events.shared" : "dots.pending.\(channel == .mcpEvents ? "events.v2" : "v1").\(resolvedThread ?? "new")") + persistenceScope
        self.recoverableDraft = defaults.string(forKey: persistenceKey + ".draft")
        if let transport { self.client = transport }
        else if let configuration {
            self.client = configuration.channel == .mcpEvents ? DotsEventsClient(configuration: configuration) : DotsClient(configuration: configuration)
        } else { self.client = nil }
        if self.unifiedConversation, defaults.data(forKey: persistenceKey) == nil {
            let oldKey = "dots.pending.events.v2.\(resolvedThread ?? "new")" + persistenceScope
            if let data = defaults.data(forKey: oldKey), (try? JSONDecoder().decode(DotCommand.self, from: data)) != nil {
                defaults.set(data, forKey: persistenceKey)
                defaults.removeObject(forKey: oldKey)
            }
            if self.recoverableDraft == nil, let draft = defaults.string(forKey: oldKey + ".draft") {
                defaults.set(draft, forKey: persistenceKey + ".draft")
                defaults.removeObject(forKey: oldKey + ".draft")
                self.recoverableDraft = draft
            }
        }
        if let data = defaults.data(forKey: persistenceKey) {
            self.pending = try? JSONDecoder().decode(DotCommand.self, from: data)
            if self.pending != nil { self.deliveryState = "uncertain" }
        }
        if self.unifiedConversation, let data = defaults.data(forKey: historyPersistenceKey) {
            if let saved = try? JSONDecoder().decode(SavedHistorySync.self, from: data),
               UUID(uuidString: saved.receipt.id) != nil,
               saved.receipt.expiresAt.isFinite,
               saved.receipt.recoverableUntil?.isFinite != false,
               saved.receipt.state == "completed" || (["pending", "delayed"].contains(saved.receipt.state)
                && (saved.receipt.recoverableUntil ?? saved.receipt.expiresAt) > Date().timeIntervalSince1970 * 1000) {
                self.historySync = saved.receipt
                self.restoredCompletedHistory = saved.receipt.state == "completed"
                self.lastHistoryRequest = min(saved.requestedAt, Date())
            } else { defaults.removeObject(forKey: historyPersistenceKey) }
        }
    }
    public func prepareConversation() async {
        // The unified chat never renders a thread picker. Do not delay its
        // first timeline behind unrelated status and thread-list requests.
        if !unifiedConversation { await refreshInbox() }
        if !unifiedConversation, resumeLastConversation, threadID == nil, pending == nil, recoverableDraft == nil, let latest = threads.first {
            threadID = latest.id
            persistenceKey = key(for: latest.id)
        }
        await refreshConversation()
    }
    /// Explicit open/refresh only. Sending already persists its own message
    /// and reply; another control event would compete for the same dot queue.
    public func refreshConversation() async {
        // Show already-stored history before waiting for a control-request
        // round trip. The visible foreground loop picks up the later import.
        await refreshMessages()
        await requestHistorySync()
    }
    private func requestHistorySync() async {
        guard unifiedConversation, !Task.isCancelled, !requestingHistory, !restoredCompletedHistory, Date() >= retryAt,
              Date().timeIntervalSince(lastHistoryRequest) >= 60, let client else { return }
        if let current = historySync, ["pending", "delayed"].contains(current.state),
           (current.recoverableUntil ?? current.expiresAt) > Date().timeIntervalSince1970 * 1000 { return }
        requestingHistory = true; lastHistoryRequest = Date()
        defer { requestingHistory = false }
        let request = DotHistorySyncRequest()
        // Preserve the lookup ID before POST. If the acknowledgement is lost
        // or the app exits, the next launch checks this durable receipt first.
        // Only control metadata is persisted, never imported message bodies.
        historySync = .init(id: request.id, state: "pending",
            expiresAt: lastHistoryRequest.timeIntervalSince1970 * 1000 + 300_000,
            truncated: false, recoverableUntil: lastHistoryRequest.timeIntervalSince1970 * 1000 + 86_400_000)
        saveHistorySync()
        do {
            applyHistorySync(try await client.requestHistorySync(request))
            historySyncError = nil
        } catch is CancellationError { }
        catch let error as DotsError where error.code == "history_sync_unavailable" {
            historySync = nil
            defaults.removeObject(forKey: historyPersistenceKey)
        }
        catch let error as DotsError {
            historySyncError = error.code
            if Self.definitiveRejections.contains(error.code) {
                historySync = nil
                defaults.removeObject(forKey: historyPersistenceKey)
            }
        }
        catch { historySyncError = "network_unavailable" }
    }
    private func checkHistorySync(_ client: any DotsTransport) async {
        guard let current = historySync, ["pending", "delayed"].contains(current.state) || restoredCompletedHistory else { return }
        do {
            let receipt = try await client.historySyncStatus(current.id)
            applyHistorySync(receipt)
            restoredCompletedHistory = false
            // Recovering an already-completed old batch is not a new sync.
            // Only a real transition into completed starts a fresh cooldown.
            if receipt.state == "completed", current.state != "completed" { lastHistoryRequest = Date() }
            saveHistorySync()
            historySyncError = ["completed", "pending", "delayed"].contains(receipt.state) ? nil : "history_sync_failed"
        } catch is CancellationError { }
        catch let error as DotsError {
            historySyncError = error.code
            if error.code == "sync_not_found" {
                historySync = nil
                restoredCompletedHistory = false
                defaults.removeObject(forKey: historyPersistenceKey)
            }
        }
        catch { historySyncError = "network_unavailable" }
    }
    private func saveHistorySync() {
        guard unifiedConversation, let historySync else { return }
        // Persist metadata only; a restored completed receipt is fetched once
        // from the authenticated cloud to recover its bounded batch payload.
        let metadata = DotHistorySyncReceipt(id: historySync.id, state: historySync.state,
            expiresAt: historySync.expiresAt, truncated: historySync.truncated, recoverableUntil: historySync.recoverableUntil)
        defaults.set(try? JSONEncoder().encode(SavedHistorySync(receipt: metadata, requestedAt: lastHistoryRequest)), forKey: historyPersistenceKey)
    }
    private func applyHistorySync(_ receipt: DotHistorySyncReceipt) {
        historySync = receipt
        if receipt.state == "completed" {
            hiddenHistoryMessageIDs.formUnion(receipt.hiddenMessageIDs ?? [])
            mergeMessages(receipt.messages ?? [])
        }
        saveHistorySync()
    }
    public func refreshInbox(more: Bool = false, reset: Bool = false) async {
        guard !Task.isCancelled, !isLoading, Date() >= retryAt, let client, !more || nextThreadCursor != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            connection = try await client.connection()
            let page = try await client.threads(cursor: more ? nextThreadCursor : nil)
            // Foreground polling must not remove already expanded pages or
            // replace their pagination cursor. An explicit pull refresh does
            // a full reset so deleted conversations can be reconciled.
            if reset && !more { loadedMoreThreads = false }
            var byID = Dictionary((reset && !more ? [] : threads).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for thread in page.threads { byID[thread.id] = thread }
            let merged = byID.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt }
            if merged != threads { threads = merged }
            if more || !loadedMoreThreads { nextThreadCursor = page.nextCursor }
            if more { loadedMoreThreads = true }
            hasLoadedInbox = true
            consecutiveRefreshFailures = 0
            errorCode = nil
        } catch { record(error) }
    }
    public var hasMoreThreads: Bool { nextThreadCursor != nil }
    public func refreshMessages(more: Bool = false) async {
        guard !Task.isCancelled, !isLoading, Date() >= retryAt, let client, !more || nextCursor != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if unifiedConversation && !more { await checkHistorySync(client) }
            if pending != nil { try await recoverReceipt(client) }
            guard unifiedConversation || threadID != nil else { return }
            // Event history returns latest records plus a separate older-page
            // cursor. Poll the latest page, not old pages that hide new replies.
            let cursor = channel == .mcpEvents ? (more ? nextCursor : nil) : ((more || historyLoaded) ? nextCursor : nil)
            // Include the latest message to pick up Slack message edits while
            // dot is composing, then merge by immutable timestamp IDs.
            let after = !more && historyLoaded && cursor == nil ? messages.last?.id : nil
            let page: DotMessagePage
            if unifiedConversation { page = try await client.timeline(cursor: cursor) }
            else { page = try await client.messages(thread: threadID!, cursor: cursor, after: after) }
            mergeMessages(page.messages)
            if channel == .mcpEvents, !more {
                try await refreshOlderReceipts(client, latestIDs: Set(page.messages.map(\.id)))
            }
            if channel == .mcpEvents {
                if let cursor, more { try eventPagination.applyOlder(page, requestedCursor: cursor) }
                else { eventPagination.applyLatest(page) }
                nextCursor = eventPagination.nextCursor
                // Catch up bounded missing pages without refetching all prior
                // history. No official-room read or control POST is made here.
                if !more {
                    var visited: Set<String> = []
                    for _ in 0..<2 {
                        guard let gap = eventPagination.gapCursor else { break }
                        try Task.checkCancellation()
                        guard visited.insert(gap).inserted else { throw DotsError("invalid_response") }
                        let missing = unifiedConversation ? try await client.timeline(cursor: gap)
                            : try await client.messages(thread: threadID!, cursor: gap, after: nil)
                        try eventPagination.applyOlder(missing, requestedCursor: gap)
                        mergeMessages(missing.messages)
                        nextCursor = eventPagination.nextCursor
                    }
                }
            } else if after == nil || page.nextCursor != nil { nextCursor = page.nextCursor }
            historyLoaded = true
            hasLoadedTimeline = true
            consecutiveRefreshFailures = 0
            if !persistenceKey.hasSuffix(".new") || recoverableDraft == nil {
                defaults.set(threadID, forKey: activeThreadKey)
            }
            if let failed = messages.last(where: { $0.role == "user" }), ["delivery_failed", "expired"].contains(failed.deliveryState ?? "") {
                errorCode = failed.deliveryState; deliveryState = failed.deliveryState
                retainFailedDraft(failed.text)
            } else { errorCode = nil }
        } catch { record(error) }
    }
    public func send(_ text: String) async {
        guard !isSending, pending == nil, let client,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.unicodeScalars.count <= 4000 else { errorCode = "invalid_text"; return }
        let command = DotCommand(text: text, thread: unifiedConversation ? nil : threadID, shared: unifiedConversation ? true : nil)
        clearFailedDraft()
        if threadID == nil { defaults.removeObject(forKey: activeThreadKey) }
        // Persist before transmission. A lost response must not generate a
        // fresh command ID on relaunch or cause a second action by the dot.
        pending = command
        defaults.set(try? JSONEncoder().encode(command), forKey: persistenceKey)
        isSending = true; deliveryState = "sending"; errorCode = nil
        do {
            try accept(try await client.send(command))
        }
        catch {
            record(error)
            if let code = (error as? DotsError)?.code,
               Self.definitiveRejections.contains(code) {
                deliveryState = "rejected"
                retainFailedDraft(command.text)
                pending = nil; defaults.removeObject(forKey: persistenceKey)
            } else {
                deliveryState = "uncertain"
                // Check the server's durable receipt; never repost automatically.
                try? await recoverReceipt(client)
            }
        }
        // The durable receipt unlocks the composer. Do not enqueue an extra
        // history-import event after every send: it competes with the actual
        // reply while adding nothing to the already-persisted companion turn.
        isSending = false
        await refreshMessages()
    }
    /// Explicit retry retains the original ID and payload. The gateway either
    /// returns its receipt or posts only if no prior attempt was accepted.
    public func retryPending() async {
        guard !isSending, let pending, let client, Date() >= retryAt else { return }
        isSending = true
        defer { isSending = false }
        var attemptedPost = false
        do {
            // The UI says "check delivery". A successful lookup resolves it
            // without another POST; a failed lookup is not permission to send.
            do { try accept(try await client.receipt(pending.id)) }
            catch let error as DotsError where error.code == "receipt_not_found" {
                attemptedPost = true
                try accept(try await client.send(pending)) // explicit, same ID/payload
            }
        }
        catch {
            record(error)
            if attemptedPost, let code = (error as? DotsError)?.code,
               Self.definitiveRejections.contains(code) {
                retainFailedDraft(pending.text)
                deliveryState = "rejected"
                self.pending = nil; defaults.removeObject(forKey: persistenceKey)
            }
        }
        await refreshMessages()
    }
    private func recoverReceipt(_ client: any DotsTransport) async throws {
        guard let pending else { return }
        do { try accept(try await client.receipt(pending.id)) }
        catch let error as DotsError where error.code == "receipt_not_found" {
            deliveryState = "uncertain"
        }
    }
    /// The latest timeline page is bounded. Late replies to older visible
    /// messages must still arrive without requiring a manual history reload.
    /// Rotate a small batch; do not refetch the entire lifetime conversation.
    private func refreshOlderReceipts(_ client: any DotsTransport, latestIDs: Set<String>) async throws {
        let older = unansweredMessages.filter { !latestIDs.contains($0.id) && $0.id.hasSuffix(".user") }
        guard !older.isEmpty, Date().timeIntervalSince(lastOlderReceiptCheck) >= 15 else { return }
        lastOlderReceiptCheck = Date()
        let start = olderReceiptOffset % older.count
        for offset in 0..<min(3, older.count) {
            let message = older[(start + offset) % older.count]
            let id = String(message.id.dropLast(5))
            do {
                let receipt = try await client.receipt(id)
                guard receipt.id == id else { throw DotsError("invalid_response") }
                mergeEventReceipt(receipt)
            } catch let error as DotsError where error.code == "receipt_not_found" { continue }
        }
        olderReceiptOffset = start + min(3, older.count)
    }
    private func mergeEventReceipt(_ receipt: DotReceipt) {
        guard let text = receipt.text, let createdAt = receipt.createdAt else { return }
        var additions = [DotMessage(id: receipt.id + ".user", role: "user", text: text, sentAt: createdAt, deliveryState: receipt.state, readAt: receipt.readAt)]
        if let reply = receipt.reply, let repliedAt = receipt.repliedAt {
            additions.append(DotMessage(id: receipt.id + ".reply", role: "assistant", text: reply, sentAt: repliedAt))
        }
        mergeMessages(additions)
    }
    private func mergeMessages(_ additions: [DotMessage]) {
        let merged = channel == .mcpEvents ? DotMessage.mergingEvents(messages, additions).filter { !hiddenHistoryMessageIDs.contains($0.id) } : DotMessage.merging(messages, additions)
        if merged != messages { messages = merged }
    }
    private func accept(_ receipt: DotReceipt) throws {
        guard pending == nil || receipt.id == pending?.id else { throw DotsError("invalid_response") }
        if channel == .mcpEvents, let command = pending {
            guard let text = receipt.text, text.utf8.elementsEqual(command.text.utf8),
                  receipt.createdAt == Double(command.createdAt),
                  command.shared == true ? UUID(uuidString: receipt.thread ?? "") != nil : receipt.thread == (command.thread ?? command.id)
            else { throw DotsError("delivery_uncertain") }
        }
        deliveryState = receipt.state
        if ["sent", "queued", "delivered", "replied"].contains(receipt.state), let thread = receipt.thread {
            threadID = thread
            defaults.set(thread, forKey: activeThreadKey)
            if let pending, let timestamp = receipt.timestamp {
                mergeMessages([DotMessage(id: timestamp, role: "user", text: pending.text, sentAt: Double(pending.createdAt))])
            }
            if channel == .mcpEvents { mergeEventReceipt(receipt) }
            pending = nil; defaults.removeObject(forKey: persistenceKey)
            clearFailedDraft()
            // Subsequent drafts and uncertain sends belong to the newly
            // established conversation, not the shared new-message slot.
            persistenceKey = key(for: thread)
            errorCode = nil
        } else if ["rejected", "delivery_failed", "expired"].contains(receipt.state) {
            retainFailedDraft(pending?.text ?? receipt.text)
            errorCode = receipt.error ?? "send_rejected"
            if receipt.state != "rejected" { errorCode = receipt.state; threadID = receipt.thread }
            pending = nil; defaults.removeObject(forKey: persistenceKey)
        } else if receipt.state == "uncertain" { errorCode = "delivery_uncertain" }
    }
    private func retainFailedDraft(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        if recoverableDraft != text { recoverableDraft = text }
        defaults.set(text, forKey: persistenceKey + ".draft")
    }
    private func key(for thread: String) -> String {
        (unifiedConversation ? "dots.pending.events.shared" : "dots.pending.\(channel == .mcpEvents ? "events.v2" : "v1").\(thread)") + persistenceScope
    }
    private func clearFailedDraft() {
        if recoverableDraft != nil { recoverableDraft = nil }
        defaults.removeObject(forKey: persistenceKey + ".draft")
    }
    private func record(_ error: Error) {
        if Task.isCancelled { return }
        consecutiveRefreshFailures = min(5, consecutiveRefreshFailures + 1)
        let known = error as? DotsError
        errorCode = known?.code ?? "network_unavailable"
        if let delay = known?.retryAfter {
            retryAt = Date().addingTimeInterval(DotForegroundRefreshPolicy.retryDelay(code: known?.code, seconds: delay))
        }
        // A stale subscription check must never stay visibly online on errors.
        connection = nil
    }
}
