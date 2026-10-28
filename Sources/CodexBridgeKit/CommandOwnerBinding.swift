import Foundation
import CryptoKit
import CodexWatchCore

/// Journal metadata only: no prompt, credentials, workspace history or tokens.
/// The digest covers the entire original command, including model/options.
struct CommandOwnerBinding: Codable, Sendable {
    let clientMessageID: String
    let sourceTaskID: String
    let commandFingerprint: String
    var ownerThreadID: String?

    static func validOwnerID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 160 && !id.hasPrefix("__codex_watch_")
            && !id.hasPrefix("chatgpt-chat:") && !id.hasPrefix("chatgpt-web:")
            && !id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func fingerprint(_ command: TaskCommand) throws -> String {
        let bytes = try CodexWatchCoding.makeEncoder().encode(command)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    init(_ command: TaskCommand) throws {
        guard !command.id.isEmpty, command.id.utf8.count <= 160,
              !command.targetsBrowserChat, command.executionTarget != .browser,
              command.startsNewCodexChat || Self.validOwnerID(command.taskID) else {
            throw CommandOwnerBindingError.invalidOwner
        }
        clientMessageID = command.id
        sourceTaskID = command.taskID
        commandFingerprint = try Self.fingerprint(command)
        ownerThreadID = command.startsNewCodexChat ? nil : command.taskID
    }

    var isValid: Bool {
        guard !clientMessageID.isEmpty, clientMessageID.utf8.count <= 160,
              commandFingerprint.utf8.count == 64,
              commandFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        if sourceTaskID == TaskCommand.newChatTaskID {
            return ownerThreadID.map(Self.validOwnerID) ?? true
        }
        return Self.validOwnerID(sourceTaskID) && ownerThreadID == sourceTaskID
    }
}

public enum CommandOwnerBindingError: LocalizedError, Sendable {
    case invalidOwner
    case ownerChanged
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidOwner: AppLocalizer.text("远程数据校验失败")
        case .ownerChanged: AppLocalizer.text("同一消息编号的内容已改变，操作未执行。")
        case .persistenceUnavailable: AppLocalizer.text("无法保存操作回执，请在 Mac 上检查后重试。")
        }
    }
}
