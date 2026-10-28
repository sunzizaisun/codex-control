import Foundation
import CodexWatchCore

/// Small, version-gated projection of the desktop's real runtime state. It
/// deliberately contains no settings, credentials, tools or transcript text.
public struct DesktopRuntimeProjection: Sendable, Equatable {
    public let threadID: String
    public let title: String?
    public let workspace: String?
    public let status: JSONValue?
    public let activeTurnID: String?
    public let latestTurnStatus: String?
    public let updatedAt: Date?

    public init(threadID: String, state: JSONValue) {
        self.threadID = threadID
        title = state["title"]?.stringValue
        workspace = state["cwd"]?.stringValue
        status = state["threadRuntimeStatus"]
        let legacy = state["turns"]?.arrayValue ?? []
        let modern = state["turnHistory"]?["history"]?["entitiesByKey"]?.objectValue?.values.map { $0 } ?? []
        let turns = legacy + modern
        let active = turns.first { $0["status"]?.stringValue == "inProgress" }
        activeTurnID = active?["turnId"]?.stringValue ?? active?["id"]?.stringValue
        let latest = turns.max {
            ($0["turnStartedAtMs"]?.doubleValue ?? 0) < ($1["turnStartedAtMs"]?.doubleValue ?? 0)
        }
        latestTurnStatus = active?["status"]?.stringValue ?? latest?["status"]?.stringValue
        updatedAt = state["updatedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    /// Retain only fields used by approvals and status. Large item arrays are
    /// mirrored separately only while a companion is viewing/sending a task.
    public static func compactState(_ state: JSONValue) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for key in ["requests", "threadRuntimeStatus", "title", "cwd", "updatedAt"] {
            result[key] = state[key]
        }
        func compactTurn(_ turn: JSONValue) -> JSONValue {
            var fields: [String: JSONValue] = [:]
            for key in ["turnId", "id", "status", "turnStartedAtMs"] { fields[key] = turn[key] }
            return .object(fields)
        }
        if let turns = state["turns"]?.arrayValue { result["turns"] = .array(turns.map(compactTurn)) }
        if let entities = state["turnHistory"]?["history"]?["entitiesByKey"]?.objectValue {
            result["turnHistory"] = .object(["history": .object(["entitiesByKey": .object(entities.mapValues(compactTurn))])])
        }
        return .object(result)
    }

    public static func messages(from state: JSONValue) -> [ChatMessage] {
        let legacy = state["turns"]?.arrayValue ?? []
        let modern = state["turnHistory"]?["history"]?["entitiesByKey"]?.objectValue?.values.map { $0 } ?? []
        let turns = legacy.isEmpty ? modern.sorted {
            let lhs = $0["turnStartedAtMs"]?.doubleValue ?? 0, rhs = $1["turnStartedAtMs"]?.doubleValue ?? 0
            if lhs != rhs { return lhs < rhs }
            // Old cached turns can omit timestamps. UUIDv7 turn IDs give a
            // deterministic fallback instead of dictionary iteration order.
            return ($0["turnId"]?.stringValue ?? $0["id"]?.stringValue ?? "")
                < ($1["turnId"]?.stringValue ?? $1["id"]?.stringValue ?? "")
        } : legacy
        let normalized = turns.map { turn -> JSONValue in
            let streaming = turn["status"]?.stringValue == "inProgress"
            let items = (turn["items"]?.arrayValue ?? []).map { item -> JSONValue in
                guard var object = item.objectValue else { return item }
                if object["type"]?.stringValue == "agentMessage" {
                    object["status"] = .string(streaming ? "inProgress" : "completed")
                }
                return .object(object)
            }
            return .object(["items": .array(items)])
        }
        return Array(ThreadHistoryParser.messages(from: .object(["thread": .object(["turns": .array(normalized)])])).suffix(30))
    }
}
