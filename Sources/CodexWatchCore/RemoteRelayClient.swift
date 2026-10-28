import CryptoKit
import Foundation

public struct RemoteRelayConfiguration: Sendable {
    public let baseURL: URL
    public let roomID: String
    public let credentials: RelayCredentials
    /// Separate key for the cloud Chat browser route. Work/Codex tasks and
    /// approvals continue to use `secret`.
    public let chatSecret: String?
    public let browserGatewayEnabled: Bool

    public init(
        baseURL: URL,
        roomID: String,
        secret: String,
        chatSecret: String? = nil,
        browserGatewayEnabled: Bool = false
    ) throws {
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(baseURL.host ?? "")) else {
            throw RemoteRelayError.invalidPacket
        }
        self.baseURL = baseURL
        self.roomID = roomID
        self.credentials = try RelayCredentials.migrating(secret: secret, roomID: roomID)
        self.chatSecret = chatSecret?.isEmpty == false ? chatSecret : nil
        // The normal Chat surface has been retired. Keep the legacy fields
        // decodable for older relay configurations, but never activate the
        // browser mailbox or embed Chat traffic in a new build.
        self.browserGatewayEnabled = false
    }

    public init(baseURL: URL, roomID: String, credentials: RelayCredentials) throws {
        guard RelayCredentials.validIdentifier(roomID),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(baseURL.host ?? "")) else {
            throw RemoteRelayError.invalidPacket
        }
        self.baseURL = baseURL; self.roomID = roomID
        self.credentials = try RelayCredentials(authToken: credentials.authToken, encryptionKey: credentials.encryptionKey)
        self.chatSecret = nil; self.browserGatewayEnabled = false
    }

    public static func fromMainBundle() -> RemoteRelayConfiguration? {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "CodexRelayURL") as? String,
              let url = URL(string: urlString),
              url.scheme == "https",
              let room = Bundle.main.object(forInfoDictionaryKey: "CodexRelayRoom") as? String,
              !room.isEmpty else { return nil }
        do {
            let credentials: RelayCredentials
            if let saved = try RelayCredentialStore.load(roomID: room) { credentials = saved }
            else {
                guard let secret = Bundle.main.object(forInfoDictionaryKey: "CodexRelaySecret") as? String,
                      secret.count >= 32 else { return nil }
                credentials = try RelayCredentials.migrating(secret: secret, roomID: room)
                try RelayCredentialStore.save(credentials, roomID: room)
            }
            return try RemoteRelayConfiguration(baseURL: url, roomID: room, credentials: credentials)
        } catch { return nil } // No legacy-key fallback after Keychain failure.
    }
}

public enum RemoteRelayMailbox: String, Sendable {
    case mac
    case phone
    case watch
    case browser
}

public enum RemoteRelayError: LocalizedError, Sendable {
    case invalidResponse
    case server(Int)
    case authenticationFailed
    case invalidPacket

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            AppLocalizer.text("远程中继返回了无效响应")
        case .server(let status):
            AppLocalizer.format("远程中继错误（%@）", String(status))
        case .authenticationFailed:
            AppLocalizer.text("远程中继身份验证失败")
        case .invalidPacket:
            AppLocalizer.text("远程数据校验失败")
        }
    }
}

private struct RemoteRelayMailboxWaitTimedOut: Error {}

// Per-task delegate preserves URLSession.shared VPN behavior without allowing
// the custom authentication header to be forwarded by an HTTP redirect.
final class RelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RelayNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor RemoteRelayClient {
    public typealias RequestTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private enum Transport: Sendable { case legacy(RelayLegacyTransport), device(RelayDeviceTransport) }
    private let transport: Transport

    public init(configuration: RemoteRelayConfiguration, requestTimeout: TimeInterval = 10,
                waitsForConnectivity: Bool = false, requestTransport: RequestTransport? = nil) {
        transport = .legacy(RelayLegacyTransport(configuration: configuration, requestTimeout: requestTimeout,
            waitsForConnectivity: waitsForConnectivity, requestTransport: requestTransport))
    }
    /// Explicit coordinated cutover only. Bundle/legacy failure never selects
    /// this mode or falls back from it. Fresh pairing/key delivery gates apply.
    public init(deviceConfiguration: RelayDeviceConfiguration, requestTimeout: TimeInterval = 10,
                waitsForConnectivity: Bool = false, requestTransport: RequestTransport? = nil) {
        transport = .device(RelayDeviceTransport(configuration: deviceConfiguration, requestTimeout: requestTimeout,
            waitsForConnectivity: waitsForConnectivity, requestTransport: requestTransport))
    }
    public func uploadSnapshot(_ snapshot: DashboardSnapshot, sender: String) async throws {
        switch transport {
        case .legacy(let client): try await client.uploadSnapshot(snapshot, sender: sender)
        case .device(let client): try await client.uploadSnapshot(snapshot, sender: sender)
        }
    }
    public func latestSnapshot() async throws -> BridgeEnvelope? {
        switch transport {
        case .legacy(let client): return try await client.latestSnapshot()
        case .device(let client): return try await client.latestSnapshot()
        }
    }
    public func latestChatSnapshot() async throws -> BridgeEnvelope? { throw RemoteRelayError.server(410) }
    public func enqueueBrowser(_ envelope: BridgeEnvelope) async throws { throw RemoteRelayError.server(410) }
    public func enqueue(_ envelope: BridgeEnvelope, to mailbox: RemoteRelayMailbox) async throws {
        switch transport {
        case .legacy(let client): try await client.enqueue(envelope, to: mailbox)
        case .device(let client): try await client.enqueue(originalBytes: CodexWatchCoding.makeEncoder().encode(envelope), to: mailbox)
        }
    }
    public func enqueue(originalEnvelopeData: Data, to mailbox: RemoteRelayMailbox) async throws {
        switch transport {
        case .legacy(let client):
            try await client.enqueue(CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: originalEnvelopeData), to: mailbox)
        case .device(let client): try await client.enqueue(originalBytes: originalEnvelopeData, to: mailbox)
        }
    }
    public func messages(for mailbox: RemoteRelayMailbox) async throws -> [BridgeEnvelope] {
        switch transport {
        case .legacy(let client): return try await client.messages(for: mailbox)
        case .device(let client): return try await client.messages(for: mailbox)
        }
    }
    public func acknowledge(_ messageID: String, in mailbox: RemoteRelayMailbox) async throws {
        switch transport {
        case .legacy(let client): try await client.acknowledge(messageID, in: mailbox)
        case .device(let client): try await client.acknowledge(messageID, in: mailbox)
        }
    }
    public func waitForMailboxActivity(_ mailbox: RemoteRelayMailbox, timeout: TimeInterval) async throws {
        switch transport {
        case .legacy(let client): try await client.waitForMailboxActivity(mailbox, timeout: timeout)
        case .device(let client): try await client.waitForMailboxActivity(mailbox, timeout: timeout)
        }
    }
    #if os(macOS)
    static func systemHTTPBody(_ data: Data, exitStatus: Int32) throws -> Data {
        try RelayLegacyTransport.systemHTTPBody(data, exitStatus: exitStatus)
    }
    #endif
}

/// Unchanged installed v2 wire behavior, retained until an explicit migration.
actor RelayLegacyTransport {
    typealias RequestTransport = RemoteRelayClient.RequestTransport
    private let configuration: RemoteRelayConfiguration
    private let cipher: RelayPacketCipher
    private let authorizationHash: String
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let requestTransport: RequestTransport?

    public init(
        configuration: RemoteRelayConfiguration,
        requestTimeout: TimeInterval = 10,
        waitsForConnectivity: Bool = false,
        requestTransport: RequestTransport? = nil
    ) {
        self.configuration = configuration
        self.cipher = RelayPacketCipher(roomID: configuration.roomID, credentials: configuration.credentials)
        self.authorizationHash = configuration.credentials.authToken
        self.requestTimeout = max(1, requestTimeout)
        self.requestTransport = requestTransport
        #if os(watchOS)
        self.session = URLSession(configuration: RelayTransportPolicy.watchSessionConfiguration(
            timeout: self.requestTimeout, waitsForConnectivity: waitsForConnectivity
        ))
        #else
        // Preserve the existing VPN-compatible production session.
        _ = waitsForConnectivity
        self.session = .shared
        #endif
    }

    public func uploadSnapshot(_ snapshot: DashboardSnapshot, sender: String) async throws {
        let envelope = BridgeEnvelope.snapshot(snapshot, sender: sender)
        let packet = try cipher.seal(envelope, destination: "snapshot")
        _ = try await request(path: "snapshot", method: "PUT", body: packet)
    }

    public func latestSnapshot() async throws -> BridgeEnvelope? {
        let data = try await request(path: "snapshot", method: "GET")
        guard !data.isEmpty else { return nil }
        return try cipher.open(CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: data), destination: "snapshot")
    }

    public func latestChatSnapshot() async throws -> BridgeEnvelope? {
        throw RemoteRelayError.server(410)
    }

    public func enqueue(_ envelope: BridgeEnvelope, to mailbox: RemoteRelayMailbox) async throws {
        guard mailbox != .browser else { throw RemoteRelayError.server(410) }
        let packet = try cipher.seal(envelope, destination: mailbox.rawValue)
        _ = try await request(path: "mailbox/\(mailbox.rawValue)", method: "POST", body: packet)
    }

    /// Sends only normal ChatGPT Chat commands through the Chat-specific key.
    /// The relay authentication header still uses the main relay key, but the
    /// packet contents cannot be decrypted by the Mac/Work route.
    public func enqueueBrowser(_ envelope: BridgeEnvelope) async throws {
        throw RemoteRelayError.server(410)
    }

    public func messages(for mailbox: RemoteRelayMailbox) async throws -> [BridgeEnvelope] {
        let data = try await request(path: "mailbox/\(mailbox.rawValue)", method: "GET")
        guard !data.isEmpty else { return [] }
        let packets = try CodexWatchCoding.makeDecoder().decode([RelaySealedPacket].self, from: data)
        return try packets.map { try cipher.open($0, destination: mailbox.rawValue) }
    }

    public func acknowledge(_ messageID: String, in mailbox: RemoteRelayMailbox) async throws {
        let safeID = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        _ = try await request(path: "mailbox/\(mailbox.rawValue)/\(safeID)", method: "DELETE")
    }

    /// Wait for a persisted mailbox to change without repeatedly waking the
    /// network stack. The Durable Object WebSocket hibernates at Cloudflare;
    /// the encrypted mailbox remains the source of truth after any reconnect.
    /// A bounded timeout provides a low-frequency recovery check for VPNs that
    /// silently discard long-lived connections.
    public func waitForMailboxActivity(
        _ mailbox: RemoteRelayMailbox,
        timeout: TimeInterval
    ) async throws {
        // TN3135: a normal watchOS app cannot establish a WebSocket. The
        // simulator permits it, so this must be enforced before opening one.
        // The next HTTPS reconciliation reads the persisted mailbox.
        guard RelayTransportPolicy.supportsMailboxWebSocket else {
            try await Task.sleep(for: .seconds(max(1, timeout)))
            return
        }
        var url = endpointURL(path: "stream/\(mailbox.rawValue)")
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = max(10, timeout + 5)
        request.setValue(authorizationHash, forHTTPHeaderField: "X-Codex-Relay-Key")
        request.setValue(configuration.credentials.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        let socket = session.webSocketTask(with: request)
        socket.delegate = RelayNoRedirectDelegate.shared
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        _ = try await socket.receive()
                    } onCancel: {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(1, timeout)))
                    throw RemoteRelayMailboxWaitTimedOut()
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch is RemoteRelayMailboxWaitTimedOut {
            // Normal recovery cadence, not a connectivity failure.
        }
    }

    private func request<T: Encodable>(path: String, method: String, body: T) async throws -> Data {
        let bodyData = try CodexWatchCoding.makeEncoder().encode(body)
        return try await request(path: path, method: method, bodyData: bodyData)
    }

    private func request(path: String, method: String) async throws -> Data {
        try await request(path: path, method: method, bodyData: nil)
    }

    private func request(path: String, method: String, bodyData: Data?) async throws -> Data {
        var lastError: Error?
        // Every write is keyed by the envelope ID (or overwrites the one room
        // snapshot), so retrying is safe. A brief retry hides transient radio
        // handoffs/VPN reconnects without making a foreground refresh wait
        // behind URLSession's long connectivity timeout.
        for attempt in 0..<2 {
            do {
                return try await performRequest(path: path, method: method, bodyData: bodyData)
            } catch {
                guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else {
                    throw CancellationError()
                }
                lastError = error
                guard attempt == 0, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? RemoteRelayError.invalidResponse
    }

    private func performRequest(path: String, method: String, bodyData: Data?) async throws -> Data {
        let url = endpointURL(path: path)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHash, forHTTPHeaderField: "X-Codex-Relay-Key")
        request.setValue(configuration.credentials.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")

        let data: Data
        let response: URLResponse
        do {
            if let requestTransport {
                // An isolated request-boundary substitute still exercises the
                // real cipher, retries, headers and response validation.
                (data, response) = try await requestTransport(request)
            } else {
                (data, response) = try await session.data(for: request, delegate: RelayNoRedirectDelegate.shared)
            }
        } catch {
            guard !Task.isCancelled, !RelayTransportPolicy.isCancellation(error) else {
                throw CancellationError()
            }
            #if os(macOS)
            // VPNCheap's transparent tunnel can reject URLSession traffic from
            // an ad-hoc development app while the system HTTPS client remains
            // routable.  Fall back only for a transport failure; the relay
            // packet is already AES-GCM encrypted before it reaches here.
            if requestTransport == nil, error is URLError {
                return try await Task.detached(priority: .utility) {
                    try Self.performMacOSSystemHTTPS(
                        url: url,
                        method: method,
                        bodyData: bodyData,
                        authorizationHash: self.authorizationHash,
                        keyID: self.configuration.credentials.keyID
                    )
                }.value
            }
            #endif
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteRelayError.invalidResponse
        }
        if http.statusCode == 401 { throw RemoteRelayError.authenticationFailed }
        if http.statusCode == 204 { return Data() }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteRelayError.server(http.statusCode)
        }
        return data
    }

    private func endpointURL(path: String) -> URL {
        var url = configuration.baseURL
        url.append(path: "v2")
        url.append(path: "rooms")
        url.append(path: configuration.roomID)
        for component in path.split(separator: "/") {
            url.append(path: String(component))
        }
        return url
    }

    #if os(macOS)
    private static func performMacOSSystemHTTPS(
        url: URL,
        method: String,
        bodyData: Data?,
        authorizationHash: String,
        keyID: String
    ) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRelay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let configURL = directory.appendingPathComponent("\(token).curl")
        let bodyURL = directory.appendingPathComponent("\(token).body")
        defer {
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: bodyURL)
        }

        // Keep the authentication header out of process arguments.  The body
        // file contains only the already-encrypted relay packet and is removed
        // as soon as curl exits.
        let config = "header = \"X-Codex-Relay-Key: \(authorizationHash)\"\nheader = \"X-Codex-Relay-Key-ID: \(keyID)\"\n"
        try Data(config.utf8).write(to: configURL, options: .atomic)
        if let bodyData {
            try bodyData.write(to: bodyURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        if bodyData != nil {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = [
            "--silent", "--show-error", "--fail-with-body",
            "--connect-timeout", "3", "--max-time", "8",
            "--write-out", "\n%{http_code}",
            "--request", method,
            "--header", "Content-Type: application/json",
            "--config", configURL.path,
        ]
        if bodyData != nil {
            arguments += ["--data-binary", "@\(bodyURL.path)"]
        }
        arguments.append(url.absoluteString)
        process.arguments = arguments
        process.standardOutput = output
        // curl's error text is not consumed. A second unread pipe can fill and
        // deadlock just like stdout; do not retain possibly sensitive URLs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain while curl runs: waiting before reading deadlocks once a
        // history response exceeds the OS pipe buffer.
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try Self.systemHTTPBody(responseData, exitStatus: process.terminationStatus)
    }

    static func systemHTTPBody(_ data: Data, exitStatus: Int32) throws -> Data {
        guard data.count >= 4, data[data.endIndex - 4] == 10,
              let text = String(data: data.suffix(3), encoding: .utf8),
              let status = Int(text), status >= 100 else { throw RemoteRelayError.invalidResponse }
        if status == 401 { throw RemoteRelayError.authenticationFailed }
        guard (200..<300).contains(status) else { throw RemoteRelayError.server(status) }
        guard exitStatus == 0 else { throw RemoteRelayError.invalidResponse }
        return status == 204 ? Data() : Data(data.dropLast(4))
    }
    #endif

    private static func isRetryable(_ error: Error) -> Bool {
        if let relay = error as? RemoteRelayError {
            switch relay {
            case .server(let status):
                return status >= 500
            case .invalidResponse:
                return true
            case .authenticationFailed, .invalidPacket:
                return false
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled, .userCancelledAuthentication:
                return false
            default:
                return true
            }
        }
        return true
    }

}
