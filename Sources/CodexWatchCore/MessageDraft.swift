import Foundation

public enum CommandReceipt: Equatable, Sendable {
    case accepted
    case failed(String)
    case unconfirmed(String)
}

public struct CommandReceipts: Equatable, Sendable {
    private var values: [String: CommandReceipt] = [:]
    private var order: [String] = []
    public init() {}

    public func result(for id: String?) -> CommandReceipt? { id.flatMap { values[$0] } }
    public mutating func record(_ receipt: CommandReceipt, for id: String) {
        // Input acceptance is terminal for this message ID. A delayed error
        // from another transport cannot revoke a verified owner's receipt.
        if values[id] == .accepted, receipt != .accepted { return }
        if values[id] == nil { order.append(id) }
        values[id] = receipt
        while order.count > 64 { values.removeValue(forKey: order.removeFirst()) }
    }
}

/// Receipt and generation are different states. Retain the exact draft until
/// the Mac accepts it; a transport failure must not erase user input.
public struct MessageDraft: Equatable, Sendable {
    public var text = ""
    public private(set) var submissionID: String?
    public private(set) var errorMessage: String?
    public private(set) var isUnconfirmed = false
    private var submittedText = ""
    public init() {}

    public func displayedError(language: AppLanguage? = nil) -> String? {
        errorMessage.map { CommandRecoveryTranslations.relocalizedNotice($0, language: language) }
    }

    public func needsSeparateReview(_ original: RecoverableCommandDraft) -> Bool {
        guard submissionID == original.messageID, let prompt = original.verifiedPrompt else { return true }
        return !text.utf8.elementsEqual(prompt.utf8)
    }

    public mutating func submitted(_ id: String?) {
        guard let id else { return }
        submissionID = id
        submittedText = text
        errorMessage = nil
        isUnconfirmed = false
    }

    public mutating func apply(_ receipt: CommandReceipt?) {
        guard submissionID != nil, let receipt else { return }
        switch receipt {
        case .accepted:
            if text.utf8.elementsEqual(submittedText.utf8) { text = "" }
            errorMessage = nil
        case .failed(let message):
            errorMessage = message
        case .unconfirmed(let message):
            errorMessage = message
            isUnconfirmed = true
            return
        }
        isUnconfirmed = false
        submissionID = nil
        submittedText = ""
    }

    @discardableResult
    public mutating func restore(_ saved: RecoverableCommandDraft) -> Bool {
        guard submissionID == nil, text.isEmpty, !saved.messageID.isEmpty else { return false }
        if let original = CommandRecovery.original(saved.originalData), original.messageID == saved.messageID,
           let command = original.taskCommand, saved.taskID == nil || saved.taskID == command.taskID {
            text = command.prompt
            submitted(original.messageID)
            apply(.unconfirmed(CommandRecovery.unconfirmedText))
        } else {
            // Corrupt records stay blocked but remain explicitly discardable;
            // never silently replace their identity or send their bytes.
            submitted(saved.messageID)
            apply(.unconfirmed(AppLocalizer.text("远程数据校验失败")))
        }
        return true
    }
    /// Explicit user-confirmed local discard. Not a cancellation at the owner.
    public mutating func discardLocalSubmission() {
        text = ""; submittedText = ""; submissionID = nil; errorMessage = nil; isUnconfirmed = false
    }

    /// A local pending-original review must not erase a newer edited draft.
    /// Clear only text that is still byte-for-byte the submitted original.
    public mutating func discardPendingOriginal() {
        guard submissionID != nil else { return }
        let edited = text.utf8.elementsEqual(submittedText.utf8) ? nil : text
        discardLocalSubmission()
        if let edited { text = edited }
    }
}
