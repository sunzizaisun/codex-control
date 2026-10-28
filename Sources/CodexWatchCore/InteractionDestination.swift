import Foundation

/// A failed attempt must not hide a question that is still pending. This
/// routing is shared by the phone and Watch notification entry points.
public enum InteractionDestination: Equatable, Sendable {
    case request(ApprovalRequest)
    case receipt(CommandReceipt)
    case unavailable

    public static func resolve(requestID: String?, pending: [ApprovalRequest],
                               receipt: CommandReceipt?, now: Date = Date()) -> Self {
        if receipt == .accepted { return .receipt(.accepted) }
        if let requestID, let request = pending.first(where: { $0.id == requestID && $0.expiresAt > now }) {
            return .request(request)
        }
        if let receipt { return .receipt(receipt) }
        return .unavailable
    }
}
