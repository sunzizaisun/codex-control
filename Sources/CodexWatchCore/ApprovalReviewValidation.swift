import Foundation

/// Check both before and after local authentication. A valid old request must
/// not be substituted for a changed, removed, or expired pending request.
public enum ApprovalReviewValidation {
    public enum RelayAction: Equatable, Sendable { case replayConfirmed, forwardToMac }
    public enum Failure: LocalizedError, Equatable {
        case expired
        case changed

        public var errorDescription: String? {
            switch self {
            case .expired: AppLocalizer.text("该审批已经过期")
            case .changed: AppLocalizer.text("审批内容已经变化，请重新检查。")
            }
        }
    }

    public static func current(
        reviewed: ApprovalRequest,
        pending: [ApprovalRequest],
        now: Date = Date()
    ) throws -> ApprovalRequest {
        guard reviewed.expiresAt > now else { throw Failure.expired }
        guard let current = pending.first(where: { $0.id == reviewed.id }),
              current.expiresAt > now,
              current == reviewed else { throw Failure.changed }
        return current
    }

    /// The phone is a relay, not the authoritative request owner. An absent
    /// cache entry must never manufacture a successful acknowledgement.
    public static func forwardingAction(decision: ApprovalDecision, cached: ApprovalRequest?, macConfirmed: Bool, now: Date = Date()) throws -> RelayAction {
        if macConfirmed { return .replayConfirmed }
        if let cached {
            guard cached.expiresAt > now else { throw Failure.expired }
            guard cached.requestDigest == decision.requestDigest, cached.nonce == decision.nonce else { throw Failure.changed }
        }
        return .forwardToMac
    }
}
