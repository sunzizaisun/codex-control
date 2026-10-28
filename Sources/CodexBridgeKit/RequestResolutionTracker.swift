import Foundation
import CodexWatchCore

/// A successful IPC write is not proof that the owning Codex task consumed
/// a decision. Only the owner's request-removed event confirms resolution.
public actor RequestResolutionTracker {
    public enum Failure: LocalizedError, Sendable { case unconfirmed
        public var errorDescription: String? { AppLocalizer.text("电脑尚未确认决定，请检查原任务") }
    }
    private var outcomes: [String: Bool] = [:]
    private var order: [String] = []
    private var waiters: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    public init() {}
    public func registered(_ key: String) {
        // A changed request reusing its wire ID must not confirm an older
        // decision when the replacement is later removed.
        for c in waiters.removeValue(forKey: key)?.values ?? [:].values { c.resume(throwing: Failure.unconfirmed) }
        outcomes.removeValue(forKey: key); order.removeAll { $0 == key }
    }
    public func resolved(_ key: String, confirmed: Bool) {
        if outcomes[key] == nil { order.append(key) }
        outcomes[key] = confirmed
        while order.count > 512 { outcomes.removeValue(forKey: order.removeFirst()) }
        for continuation in waiters.removeValue(forKey: key)?.values ?? [:].values {
            if confirmed { continuation.resume() } else { continuation.resume(throwing: Failure.unconfirmed) }
        }
    }
    public func wait(_ key: String, timeout: Duration = .seconds(10)) async throws {
        if let confirmed = outcomes[key] {
            guard confirmed else { throw Failure.unconfirmed }; return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                waiters[key, default: [:]][id] = c
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(key, id: id)
                }
            }
        } onCancel: { Task { await self.expire(key, id: id) } }
    }
    private func expire(_ key: String, id: UUID) {
        guard let c = waiters[key]?.removeValue(forKey: id) else { return }
        if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
        c.resume(throwing: Failure.unconfirmed)
    }
}
