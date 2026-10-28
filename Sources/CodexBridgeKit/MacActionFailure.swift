import Foundation
import CodexWatchCore

/// Persist the outcome before replying. A transport/protocol interruption
/// cannot prove the owner rejected an action, even if its caller saw an error.
enum MacActionFailure {
    static func isUnconfirmed(_ error: any Error) -> Bool {
        if let error = error as? AppServerClientError {
            switch error {
            case .executableNotFound, .notRunning: return false
            case .server(let code, _):
                // JSON-RPC admission failures are definitive; an internal or
                // application-defined error need not be atomic with effects.
                return ![-32600, -32601, -32602].contains(code ?? 0)
            case .timedOut, .processExited, .invalidResponse: return true
            }
        }
        // These checks happen before the broker writes a decision or starts
        // a turn. A missing owner-resolution acknowledgement is NOT one of
        // these definitive validation errors.
        if error is ApprovalBrokerError || error is CodexTurnOptionsError || error is CodexCompanionCommandError {
            return false
        }
        // An unfamiliar handler error has no proof of non-delivery. Prefer
        // an explicit uncertain result to a false rejected/failed assertion.
        return true
    }

    @discardableResult
    static func record(_ error: any Error, messageID: String, in deduplicator: BridgeMessageDeduplicator) -> String {
        if isUnconfirmed(error) {
            let message = AppLocalizer.text("上次操作结果未确认，请先检查原任务。")
            deduplicator.markUnconfirmed(messageID)
            return message
        }
        let message = error.localizedDescription
        deduplicator.fail(messageID, message: message)
        return message
    }
}
