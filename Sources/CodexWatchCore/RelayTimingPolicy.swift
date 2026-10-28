import Foundation

/// All companion routes share the same idle cadence. Freshness allows two
/// asynchronous idle cycles (publisher + consumer) and network jitter, rather
/// than marking a healthy 60-second heartbeat stale after only 45 seconds.
public enum RelayTimingPolicy {
    public static let idleInterval: TimeInterval = 60
    public static let snapshotFreshness: TimeInterval = idleInterval * 2 + 30

    public static func isFresh(_ sentAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(sentAt)
        return age >= 0 && age <= snapshotFreshness
    }
}

public extension DashboardSnapshot {
    /// Only the Mac's original capture time is a heartbeat. An iPhone
    /// forwarding a cache or a relay accepting a command cannot renew it.
    func isMacOnline(now: Date = Date()) -> Bool {
        bridgeConnected && RelayTimingPolicy.isFresh(capturedAt, now: now)
    }

    func reconcilingMacPresence(now: Date = Date()) -> DashboardSnapshot {
        var result = self
        result.bridgeConnected = isMacOnline(now: now)
        if !result.bridgeConnected {
            for index in result.tasks.indices where result.tasks[index].isInProgress {
                result.tasks[index].state = .unknown
                result.tasks[index].activeTurnID = nil
                result.tasks[index].awaitingUserInput = nil
                result.tasks[index].progress = nil
            }
        }
        return result
    }
}
