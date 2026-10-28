import Foundation
import Testing
@testable import CodexWatchCore

@Test func dotQuotaRecoveryCannotRemainBlockedForAnotherWholeDay() {
    #expect(DotForegroundRefreshPolicy.retryDelay(code: "cloud_read_quota_exhausted", seconds: 85743) == 900)
    #expect(DotForegroundRefreshPolicy.retryDelay(code: "cloud_read_quota_exhausted", seconds: 30) == 30)
    #expect(DotForegroundRefreshPolicy.retryDelay(code: "cloud_read_quota_exhausted", seconds: -1) == 1)
    // Do not shorten unrelated maintenance or rate-limit instructions.
    #expect(DotForegroundRefreshPolicy.retryDelay(code: "rate_limited", seconds: 3600) == 3600)
}

@Test func dotForegroundRefreshStopsWhenHiddenOrInactive() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(DotForegroundRefreshPolicy.interval(active: false, latestPendingAt: now,
        failures: 0, retryAt: .distantPast, now: now) == nil)
}
@Test func dotForegroundRefreshUsesBoundedFastWindowAndSlowerIdle() {
    let now = Date(timeIntervalSince1970: 1000)
    for age in [0.0, 30, 90] {
        #expect(DotForegroundRefreshPolicy.interval(active: true,
            latestPendingAt: now.addingTimeInterval(-age), failures: 0,
            retryAt: .distantPast, now: now) == 1)
    }
    #expect(DotForegroundRefreshPolicy.interval(active: true,
        latestPendingAt: now.addingTimeInterval(-91), failures: 0,
        retryAt: .distantPast, now: now) == 3)
    #expect(DotForegroundRefreshPolicy.interval(active: true,
        latestPendingAt: nil, failures: 0, retryAt: .distantPast, now: now) == 12)
    #expect(DotForegroundRefreshPolicy.interval(active: true,
        latestPendingAt: nil, failures: 0, retryAt: .distantPast, now: now,
        latestActivityAt: now.addingTimeInterval(-30)) == 3)
    #expect(DotForegroundRefreshPolicy.interval(active: true,
        latestPendingAt: nil, failures: 0, retryAt: .distantPast, now: now,
        latestActivityAt: now.addingTimeInterval(-91)) == 12)
}
@Test func dotForegroundRefreshBacksOffFailuresAndHonorsRetryAfter() {
    let now = Date(timeIntervalSince1970: 1000)
    for (failures, expected) in [(1, 3.0), (2, 6), (3, 12), (4, 24), (5, 30), (100, 30)] {
        #expect(DotForegroundRefreshPolicy.interval(active: true, latestPendingAt: now,
            failures: failures, retryAt: .distantPast, now: now) == expected)
    }
    #expect(DotForegroundRefreshPolicy.interval(active: true, latestPendingAt: now,
        failures: 0, retryAt: now.addingTimeInterval(45), now: now) == 45)
    #expect(DotForegroundRefreshPolicy.interval(active: true, latestPendingAt: now,
        failures: 0, retryAt: now.addingTimeInterval(300), now: now) == 60)
}
@Test func dotOldUnansweredInputCannotKeepFastPollingAllNight() {
    let now = Date(timeIntervalSince1970: 10_000)
    for (age, expected) in [(300.0, 3.0), (301, 12), (900, 12), (901, 30), (3600, 30)] {
        #expect(DotForegroundRefreshPolicy.interval(active: true,
            latestPendingAt: now.addingTimeInterval(-age), failures: 0,
            retryAt: .distantPast, now: now) == expected)
    }
}
