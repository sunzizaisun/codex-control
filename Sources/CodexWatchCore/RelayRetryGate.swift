import Foundation

/// Retry persisted user actions without concurrent uploads or radio flooding.
public struct RelayRetryGate: Sendable {
    private var attemptedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    public init() {}

    public mutating func begin(_ id: String, now: Date = Date(), interval: TimeInterval = 15) -> Bool {
        guard !inFlight.contains(id) else { return false }
        if let last = attemptedAt[id], now.timeIntervalSince(last) < interval { return false }
        attemptedAt[id] = now
        inFlight.insert(id)
        return true
    }

    public mutating func finish(_ id: String) { inFlight.remove(id) }
    public mutating func retainOnly(_ ids: Set<String>) {
        attemptedAt = attemptedAt.filter { ids.contains($0.key) }
        // Do not remove an actual upload from inFlight until it completes.
    }
}
