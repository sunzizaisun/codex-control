import CodexWatchCore

/// The Watch is the approval surface. watchOS verifies that it is being worn
/// before it creates a decision; the Mac then verifies the request identity
/// and relays that decision to the desktop session.  Asking macOS to perform
/// a second companion authentication here is both redundant and wrong for a
/// remote relay: it only works when the Mac and Watch are nearby, and a retry
/// of an already-sent decision can repeatedly summon the system prompt.
@MainActor
final class WatchApprovalGate {
    func confirmIfNeeded(_ decision: ApprovalDecision) async throws {
        // ApprovalBroker validates the request ID, digest, nonce and expiry;
        // the Watch has already performed LocalAuthentication.  Keep this
        // async hook for the transport API without presenting a Mac prompt.
        _ = decision
    }
}
