import Foundation

/// Read-only history travels separately from the small, frequent dashboard.
/// The cursor is a stable message ID, never a mutable list offset.
public struct TaskHistoryRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let beforeMessageID: String?
    public let limit: Int
    /// Opaque upstream continuation; optional for legacy compatibility.
    public let continuation: String?

    public init(taskID: String, beforeMessageID: String? = nil, limit: Int = 20, continuation: String? = nil) {
        self.taskID = taskID
        self.beforeMessageID = beforeMessageID
        self.limit = min(30, max(1, limit))
        self.continuation = continuation
    }
}

public struct TaskHistoryPage: Codable, Equatable, Sendable {
    public let taskID: String
    public let messages: [ChatMessage]
    public let beforeMessageID: String?
    public let nextBeforeMessageID: String?
    public let continuation: String?
    public let requestContinuation: String?

    public init(taskID: String, messages: [ChatMessage], beforeMessageID: String? = nil, nextBeforeMessageID: String? = nil,
        continuation: String? = nil, requestContinuation: String? = nil) {
        self.taskID = taskID
        self.messages = messages
        self.beforeMessageID = beforeMessageID
        self.nextBeforeMessageID = nextBeforeMessageID
        self.continuation = continuation
        self.requestContinuation = requestContinuation
    }

    public var isOlderPage: Bool { beforeMessageID != nil || requestContinuation != nil }

    public func isValid(for request: TaskHistoryRequest) -> Bool {
        func validCursor(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= 4_096
        }
        return taskID == request.taskID && beforeMessageID == request.beforeMessageID
            && requestContinuation == request.continuation
            && messages.count <= min(30, max(1, request.limit))
            && Set(messages.map(\.id)).count == messages.count
            && messages.allSatisfy { !$0.id.isEmpty && $0.id.utf8.count <= 160
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ($0.clientMessageID == nil || ($0.role == .user && !$0.clientMessageID!.isEmpty && $0.clientMessageID!.utf8.count <= 160)) }
            && validCursor(continuation) && validCursor(requestContinuation)
            && (continuation == nil || continuation != requestContinuation)
    }
}

public enum TaskHistoryPaging {
    public enum Failure: Error { case cursorNotFound }

    public static func page(messages: [ChatMessage], request: TaskHistoryRequest, maximumEncodedBytes: Int = 36_000) throws -> TaskHistoryPage {
        let end: Int
        if let cursor = request.beforeMessageID {
            guard let index = messages.firstIndex(where: { $0.id == cursor }) else { throw Failure.cursorNotFound }
            end = index
        } else {
            end = messages.count
        }
        var start = max(0, end - min(30, max(1, request.limit)))
        // Fit ordinary history pages through WatchConnectivity too. Keep at
        // least one complete message; exceptionally large single replies use
        // the independent encrypted internet path, never text truncation.
        while start < end - 1,
              try CodexWatchCoding.makeEncoder().encode(Array(messages[start..<end])).count > maximumEncodedBytes {
            start += 1
        }
        let rows = Array(messages[start..<end])
        return TaskHistoryPage(
            taskID: request.taskID,
            messages: rows,
            beforeMessageID: request.beforeMessageID,
            nextBeforeMessageID: start > 0 ? rows.first?.id : nil
        )
    }
}

/// Preserve authoritative history order and full text when a compact live
/// snapshot arrives. Loading older rows must not erase newer/streaming rows.
public struct TaskHistoryState: Equatable, Sendable {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var nextBeforeMessageID: String?
    public private(set) var nextContinuation: String?
    public var hasMore: Bool { nextContinuation != nil || nextBeforeMessageID != nil }
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    private var hasLoadedOlderPages = false

    public init() {}

    public mutating func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    public mutating func fail(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    public mutating func apply(_ page: TaskHistoryPage) {
        merge(page.messages, prepend: page.isOlderPage, authoritativeLatest: !page.isOlderPage, protectStreaming: true)
        if page.isOlderPage {
            hasLoadedOlderPages = true
            nextBeforeMessageID = page.nextBeforeMessageID
            nextContinuation = page.continuation
        } else if !hasLoadedOlderPages {
            nextBeforeMessageID = page.nextBeforeMessageID
            nextContinuation = page.continuation
        }
        hasLoaded = true
        isLoading = false
        errorMessage = nil
    }

    public mutating func applyLive(_ incoming: [ChatMessage]) {
        merge(incoming, prepend: false)
    }

    private mutating func merge(_ incoming: [ChatMessage], prepend: Bool, authoritativeLatest: Bool = false, protectStreaming: Bool = false) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var incomingIDs: [String] = []
        for message in incoming {
            if !incomingIDs.contains(message.id) { incomingIDs.append(message.id) }
            var updated = message
            if updated.clientMessageID == nil, updated.role == .user {
                updated.clientMessageID = byID[message.id]?.clientMessageID
            }
            // A read began before a live delta but returned afterwards. Do
            // not shrink that in-flight reply to the older persisted prefix;
            // the fresh owner completion can still replace it via applyLive.
            if protectStreaming, let live = byID[message.id], live.isStreaming,
               live.text.utf8.count > message.text.utf8.count,
               live.text.utf8.starts(with: message.text.utf8) {
                updated = live
            }
            if let full = byID[message.id], message.text.hasSuffix("…"),
               full.text.count > message.text.count,
               full.text.hasPrefix(String(message.text.dropLast())) {
                updated.text = full.text
            }
            byID[message.id] = updated
        }
        let existingIDs = messages.map(\.id)
        let order: [String]
        if prepend {
            order = incomingIDs + existingIDs.filter { !incomingIDs.contains($0) }
        } else if authoritativeLatest,
                  let first = existingIDs.firstIndex(where: { incomingIDs.contains($0) }),
                  let last = existingIDs.lastIndex(where: { incomingIDs.contains($0) }) {
            // A dashboard may seed only the LAST four messages. Placing all
            // missing history after those four reverses conversation order.
            order = existingIDs[..<first].filter { !incomingIDs.contains($0) }
                + incomingIDs
                + existingIDs[(last + 1)...].filter { !incomingIDs.contains($0) }
        } else {
            order = existingIDs + incomingIDs.filter { !existingIDs.contains($0) }
        }
        messages = order.compactMap { byID[$0] }
    }
}
