import Foundation
import CodexWatchCore

public enum CodexTurnOptionsError: Error, LocalizedError {
    case unsupported, activeTurn
    public var errorDescription: String? {
        AppLocalizer.text(self == .activeTurn ? "运行中不能切换模型，请等待当前回合结束" : "模型选项已变化，请刷新后重新选择")
    }
}

public enum CodexTurnOptions {
    public static func applying(_ options: CodexExecutionOptions?, to params: [String: JSONValue]) -> JSONValue {
        var result = params
        if let options { result["model"] = .string(options.model); result["effort"] = .string(options.effort) }
        return .object(result)
    }
}
