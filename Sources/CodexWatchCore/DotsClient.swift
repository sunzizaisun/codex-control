import CryptoKit
import Foundation

public enum DotsChannel: String, Sendable { case slack, mcpEvents = "mcp-events" }

/// Independent of the Mac relay. Provider credentials remain on the server.
public struct DotsConfiguration: Sendable {
    public let baseURL: URL
    public let authKey: String
    public let channel: DotsChannel
    public init?(baseURL: URL, relaySecret: String, channel: DotsChannel = .slack) {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              relaySecret.count >= 32 else { return nil }
        self.baseURL = baseURL
        self.channel = channel
        self.authKey = Self.derivedKey(relaySecret: relaySecret, channel: channel)
    }
    public static func derivedKey(relaySecret: String, channel: DotsChannel = .slack) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data((channel == .slack ? "codex-control/dots/auth/v1" : "codex-control/dot-inbox/device/v1").utf8),
            using: SymmetricKey(data: Data(relaySecret.utf8)))
        return Data(mac).base64EncodedString()
    }
    public static func fromMainBundle() -> Self? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexDotsURL") as? String,
              let url = URL(string: raw),
              let secret = Bundle.main.object(forInfoDictionaryKey: "CodexRelaySecret") as? String else { return nil }
        let channel = Bundle.main.object(forInfoDictionaryKey: "CodexDotsTransport") as? String ?? "slack"
        guard let parsed = DotsChannel(rawValue: channel) else { return nil }
        return Self(baseURL: url, relaySecret: secret, channel: parsed)
    }
}

public struct DotThread: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: Double
}
public struct DotMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let sentAt: Double
    public let controlsInSlack: Bool
    public let deliveryState: String?
    public let readAt: Double?
    public init(id: String, role: String, text: String, sentAt: Double, controlsInSlack: Bool = false, deliveryState: String? = nil, readAt: Double? = nil) {
        self.id = id; self.role = role; self.text = text; self.sentAt = sentAt; self.controlsInSlack = controlsInSlack
        self.deliveryState = deliveryState
        self.readAt = readAt
    }
    public static func merging(_ existing: [Self], _ incoming: [Self]) -> [Self] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming { byID[message.id] = message }
        return byID.values.sorted { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
    }
}
public struct DotMessagePage: Codable, Sendable {
    public let messages: [DotMessage]
    public let nextCursor: String?
    public let capturedAt: Double
}
public struct DotThreadPage: Codable, Sendable {
    public let threads: [DotThread]
    public let nextCursor: String?
}
public struct DotHistorySyncRequest: Codable, Sendable {
    public let id: String
    public let createdAt: Int64
    public init(now: Date = Date(), id: UUID = UUID()) {
        self.id = id.uuidString.lowercased(); self.createdAt = Int64(now.timeIntervalSince1970 * 1000)
    }
}
public struct DotHistorySyncReceipt: Codable, Sendable {
    public let id: String
    public let state: String
    public let expiresAt: Double
    public let truncated: Bool
    public let recoverableUntil: Double?
    public let messages: [DotMessage]?
    public let hiddenMessageIDs: [String]?
    public init(id: String, state: String, expiresAt: Double, truncated: Bool, recoverableUntil: Double? = nil, messages: [DotMessage]? = nil, hiddenMessageIDs: [String]? = nil) {
        self.id = id; self.state = state; self.expiresAt = expiresAt
        self.truncated = truncated; self.recoverableUntil = recoverableUntil
        self.messages = messages; self.hiddenMessageIDs = hiddenMessageIDs
    }
}
public struct DotConnection: Codable, Sendable {
    public let connected: Bool
    public let dotName: String
    public let verifiedAt: Double
    public let expiresAt: Double?
    public init(connected: Bool, dotName: String, verifiedAt: Double, expiresAt: Double? = nil) {
        self.connected = connected; self.dotName = dotName; self.verifiedAt = verifiedAt; self.expiresAt = expiresAt
    }
}
public struct DotCommand: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let createdAt: Int64
    public let thread: String?
    public let shared: Bool?
    public init(text: String, thread: String?, now: Date = Date(), id: UUID = UUID(), shared: Bool? = nil) {
        self.id = id.uuidString.lowercased(); self.text = text
        self.createdAt = Int64(now.timeIntervalSince1970 * 1000); self.thread = thread
        self.shared = shared
    }
}
public struct DotReceipt: Codable, Sendable {
    public let id: String
    public let state: String
    public let thread: String?
    public let timestamp: String?
    public let error: String?
    public let text: String?
    public let createdAt: Double?
    public let reply: String?
    public let repliedAt: Double?
    public let readAt: Double?
    public init(id: String, state: String, thread: String?, timestamp: String?, error: String?, text: String? = nil, createdAt: Double? = nil, reply: String? = nil, repliedAt: Double? = nil, readAt: Double? = nil) {
        self.id = id; self.state = state; self.thread = thread; self.timestamp = timestamp; self.error = error
        self.text = text; self.createdAt = createdAt; self.reply = reply; self.repliedAt = repliedAt
        self.readAt = readAt
    }
}
public struct DotsError: Error, Sendable {
    public let code: String
    public let retryAfter: Int?
    public init(_ code: String, retryAfter: Int? = nil) { self.code = code; self.retryAfter = retryAfter }
}

public protocol DotsTransport: Sendable {
    var channel: DotsChannel { get }
    func connection() async throws -> DotConnection
    func threads(cursor: String?) async throws -> DotThreadPage
    func messages(thread: String, cursor: String?, after: String?) async throws -> DotMessagePage
    func timeline(cursor: String?) async throws -> DotMessagePage
    func send(_ command: DotCommand) async throws -> DotReceipt
    func receipt(_ id: String) async throws -> DotReceipt
    func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt
    func historySyncStatus(_ id: String) async throws -> DotHistorySyncReceipt
}
public extension DotsTransport {
    var channel: DotsChannel { .slack }
    func timeline(cursor: String?) async throws -> DotMessagePage { throw DotsError("timeline_unavailable") }
    func requestHistorySync(_ request: DotHistorySyncRequest) async throws -> DotHistorySyncReceipt { throw DotsError("history_sync_unavailable") }
    func historySyncStatus(_ id: String) async throws -> DotHistorySyncReceipt { throw DotsError("history_sync_unavailable") }
}

public actor DotsClient: DotsTransport {
    private let http: DotsHTTPClient
    public init(configuration: DotsConfiguration) {
        self.http = DotsHTTPClient(configuration: configuration)
    }
    public func connection() async throws -> DotConnection { try await http.request("v1/connection") }
    public func threads(cursor: String? = nil) async throws -> DotThreadPage {
        try await http.request("v1/threads", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }
    public func messages(thread: String, cursor: String? = nil, after: String? = nil) async throws -> DotMessagePage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        return try await http.request("v1/threads/\(thread)", query: query)
    }
    public func send(_ command: DotCommand) async throws -> DotReceipt {
        try await http.request("v1/messages", body: JSONEncoder().encode(command))
    }
    public func receipt(_ id: String) async throws -> DotReceipt { try await http.request("v1/receipts/\(id)") }
}

actor DotsHTTPClient {
    private struct Failure: Decodable { let error: String; let retryAfter: Int? }
    private let configuration: DotsConfiguration
    private let session: URLSession
    init(configuration: DotsConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session; return }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 22
        settings.timeoutIntervalForResource = 25
        settings.waitsForConnectivity = false
        settings.urlCache = nil
        self.session = URLSession(configuration: settings, delegate: DotsRedirectBlocker(), delegateQueue: nil)
    }
    func request<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        let endpoint = configuration.baseURL.appendingPathComponent(path)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(configuration.authKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw DotsError(body == nil ? "network_unavailable" : "delivery_uncertain") }
        guard let http = response as? HTTPURLResponse, data.count <= 1024 * 1024 else { throw DotsError("invalid_response") }
        if !(200..<300).contains(http.statusCode) {
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw DotsError(failure?.error ?? "gateway_unavailable", retryAfter: failure?.retryAfter ?? Int(http.value(forHTTPHeaderField: "Retry-After") ?? ""))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DotsError(body == nil ? "invalid_response" : "delivery_uncertain") }
    }
}

private final class DotsRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
