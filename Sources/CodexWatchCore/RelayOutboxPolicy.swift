import Foundation

/// A queued action has a finite delivery window even if the transport stays
/// disconnected. Expiry means its execution is unconfirmed, not cancelled.
public enum RelayOutboxPolicy {
    static func matchesMetadata(_ envelope: BridgeEnvelope, sentAtMilliseconds: Int64, expiresAtMilliseconds: Int64?) -> Bool {
        let sent = envelope.sentAt.timeIntervalSince1970 * 1_000
        let expires = envelope.deliveryExpiresAt.timeIntervalSince1970 * 1_000
        guard sent.isFinite, expires.isFinite,
              abs(sent - Double(sentAtMilliseconds)) <= 1 else { return false }
        // v1/v2 packets omitted expiry. A supplied deadline may never extend
        // the authenticated envelope's actual lifetime.
        return expiresAtMilliseconds.map { abs(expires - Double($0)) <= 1 } ?? true
    }

    public static func isDeliverable(_ envelope: BridgeEnvelope, now: Date = Date()) -> Bool {
        guard envelope.sentAt.timeIntervalSince1970.isFinite
            && envelope.sentAt <= now.addingTimeInterval(60)
            && envelope.deliveryExpiresAt > now else { return false }
        let actionDate: Date?
        switch envelope.kind {
        case .taskCommand: actionDate = envelope.taskCommand?.sentAt
        case .approvalDecision: actionDate = envelope.decision?.decidedAt
        case .usageReset: actionDate = envelope.usageReset?.requestedAt
        default: actionDate = nil
        }
        guard let actionDate else { return true }
        // Preserve the authenticated wire deadline and legacy millisecond
        // comparison. Admission also checks the ORIGINAL action timestamp;
        // a fresh transport wrapper cannot renew an old execution lifetime.
        let lifetime: TimeInterval = envelope.kind == .taskCommand ? 24 * 60 * 60 : 15 * 60
        return actionDate.timeIntervalSince1970.isFinite
            && actionDate <= now.addingTimeInterval(60)
            && actionDate.addingTimeInterval(lifetime) > now
    }
}
