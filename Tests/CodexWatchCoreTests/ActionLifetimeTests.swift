import Foundation
import Testing
@testable import CodexWatchCore

@Test func rewrappingAnOldCommandCannotRenewItsExecutionLifetime() {
    let now = Date(timeIntervalSince1970: 100_000)
    let command = TaskCommand(taskID: "fixture", prompt: "原指令🦦", sentAt: now.addingTimeInterval(-24 * 60 * 60), deviceID: "watch")
    let envelope = BridgeEnvelope(sentAt: now, kind: .taskCommand, senderDeviceID: "watch", taskCommand: command)
    #expect(!RelayOutboxPolicy.isDeliverable(envelope, now: now))
    #expect(RelayOutboxPolicy.matchesMetadata(envelope, sentAtMilliseconds: 100_000_000,
        expiresAtMilliseconds: 186_400_000))
}

@Test func rewrappingOldApprovalAndResetCannotRenewTheirDecisionWindow() {
    let now = Date(timeIntervalSince1970: 100_000), old = now.addingTimeInterval(-15 * 60)
    let decision = ApprovalDecision(requestID: "fixture", requestDigest: "digest", choice: .allowOnce,
        decidedAt: old, deviceID: "watch", nonce: "nonce")
    let approval = BridgeEnvelope(sentAt: now, kind: .approvalDecision, senderDeviceID: "watch", decision: decision)
    let reset = BridgeEnvelope(sentAt: now, kind: .usageReset, senderDeviceID: "watch",
        usageReset: .init(creditID: "fixture", deviceID: "watch", requestedAt: old))
    #expect(!RelayOutboxPolicy.isDeliverable(approval, now: now))
    #expect(!RelayOutboxPolicy.isDeliverable(reset, now: now))
}

@Test func actionClockToleranceAndOriginalDeadlineAreInclusiveOnlyWhereSpecified() {
    let now = Date(timeIntervalSince1970: 100_000)
    for (date, expected) in [
        (now.addingTimeInterval(-24 * 60 * 60 + 0.001), true),
        (now.addingTimeInterval(-24 * 60 * 60), false),
        (now.addingTimeInterval(60), true),
        (now.addingTimeInterval(60.001), false),
        (Date(timeIntervalSince1970: .infinity), false),
        (Date(timeIntervalSince1970: .nan), false)
    ] {
        let command = TaskCommand(taskID: "fixture", prompt: "test", sentAt: date, deviceID: "watch")
        #expect(RelayOutboxPolicy.isDeliverable(.init(sentAt: now, kind: .taskCommand,
            senderDeviceID: "watch", taskCommand: command), now: now) == expected)
    }
}
