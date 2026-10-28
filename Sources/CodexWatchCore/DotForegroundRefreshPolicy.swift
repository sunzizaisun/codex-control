import Foundation

/// Only schedules visible, active conversation reads. It never sends messages
/// or keeps watchOS/iOS running in the background.
public enum DotForegroundRefreshPolicy {
    public static func retryDelay(code: String?, seconds: Int) -> TimeInterval {
        // Older gateways could report nearly 24 hours immediately after the
        // UTC reset. Recheck readiness conservatively; never replay a message.
        Double(code == "cloud_read_quota_exhausted" ? min(900, max(1, seconds)) : max(1, seconds))
    }
    public static func interval(active: Bool, latestPendingAt: Date?, failures: Int,
                                retryAt: Date, now: Date, latestActivityAt: Date? = nil) -> TimeInterval? {
        guard active else { return nil }
        let recent = latestPendingAt.map { now.timeIntervalSince($0) <= 90 } ?? false
        let chatting = latestActivityAt.map { now.timeIntervalSince($0) <= 90 } ?? false
        // An old unanswered input must not keep every device polling rapidly
        // all night. Keep the fast interactive window, then back off locally.
        let pendingAge = latestPendingAt.map { max(0, now.timeIntervalSince($0)) }
        let pendingDelay: TimeInterval = pendingAge.map { $0 <= 300 ? 3 : ($0 <= 900 ? 12 : 30) } ?? 12
        let normal: TimeInterval = recent ? 1 : (chatting ? 3 : pendingDelay)
        let failureDelay: TimeInterval = failures > 0
            ? min(30, 3 * pow(2, Double(min(4, max(0, failures - 1))))) : 0
        // Respect Retry-After. Long server backoffs can wake the local timer
        // once a minute, but the store still blocks network I/O until retryAt.
        return min(60, max(normal, failureDelay, retryAt.timeIntervalSince(now)))
    }
}
