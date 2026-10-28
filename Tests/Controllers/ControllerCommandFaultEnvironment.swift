#if !CONTROLLER_FAULT_TESTS || !targetEnvironment(simulator)
#error("Only the isolated native simulator test project may compile these tests")
#endif
import Foundation
@testable import CodexWatchCore

@MainActor
final class ControllerCommandFaultEnvironment {
    static var current: ControllerCommandFaultEnvironment?
    let deviceID = "controller-qa-" + UUID().uuidString
    let root: URL
    let store: CommandOutboxFileStore
    let fixture: ControllerHTTPFixture
    let client: RemoteRelayClient
    let snapshot = DashboardSnapshot.uiPreview()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ControllerFaultQA", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = .init(fileURL: root.appendingPathComponent("queue", isDirectory: true).appendingPathComponent("commands.plist"))
        fixture = try ControllerHTTPFixture(store: store)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ControllerURLProtocol.self]
        settings.urlCache = nil
        let requestTransport: RemoteRelayClient.RequestTransport
        #if os(watchOS)
        // The watchOS simulator's network proxy bypassed custom URLProtocol
        // classes in the preserved first run and tried DNS for .invalid.
        // Replace only the request IO boundary here; no DNS or public route.
        let isolatedFixture = fixture
        requestTransport = { request in
            let result = try isolatedFixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (result.body, response)
        }
        #else
        let isolatedSession = URLSession(configuration: settings)
        requestTransport = { request in try await isolatedSession.data(for: request) }
        #endif
        client = RemoteRelayClient(configuration: fixture.configuration, requestTimeout: 1,
            requestTransport: requestTransport)
    }
}

/// URLProtocol replaces only HTTP IO. Actual controller admission, the real
/// file store, cipher, request retry, response decoding and receipt handlers
/// remain in the tested path. All bytes are synthetic; no public networking.
final class ControllerHTTPFixture: @unchecked Sendable {
    struct Posted: Sendable { let envelope: BridgeEnvelope; let body: Data; let durableBeforeSend: Bool }
    struct Result { let status: Int; let body: Data }
    let configuration: RemoteRelayConfiguration
    private let lock = NSLock()
    private let cipher: RelayPacketCipher
    private let store: CommandOutboxFileStore
    private var posts: [Posted] = []
    private var inbox: [BridgeEnvelope] = []
    private var failuresRemaining = 0
    private var receivedPaths: [String] = []
    private var fixtureFailures: [String] = []

    init(store: CommandOutboxFileStore) throws {
        let id = UUID().uuidString
        let credentials = try RelayCredentials.generate()
        configuration = try .init(baseURL: URL(string: "https://relay-controller-fixture.invalid/\(id)")!,
            roomID: "controller-qa-" + id, credentials: credentials)
        cipher = .init(roomID: configuration.roomID, credentials: credentials)
        self.store = store
        ControllerURLProtocol.registry.insert(self, id: id)
    }

    func posted() -> [Posted] { lock.withLock { posts } }
    func errors() -> [String] { lock.withLock { fixtureFailures } }
    func paths() -> [String] { lock.withLock { receivedPaths } }
    func failNextPosts(_ count: Int) { lock.withLock { failuresRemaining = count } }
    func deliver(_ envelope: BridgeEnvelope) { lock.withLock { inbox.append(envelope) } }

    func response(_ request: URLRequest) throws -> Result {
        try lock.withLock {
            guard let url = request.url, url.host == "relay-controller-fixture.invalid",
                  request.value(forHTTPHeaderField: "X-Codex-Relay-Key") == configuration.credentials.authToken,
                  request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == configuration.credentials.keyID else {
                fixtureFailures.append("wrong_fixture_auth_or_origin")
                throw URLError(.unsupportedURL)
            }
            let path = url.path
            receivedPaths.append((request.httpMethod ?? "?") + " " + path)
            if request.httpMethod == "POST", path.hasSuffix("/mailbox/mac") {
                let bytes = try Self.body(request)
                let packet = try CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: bytes)
                let original = try cipher.open(packet, destination: "mac")
                let disk = try? PropertyListDecoder().decode([StoredCommandRecord].self, from: Data(contentsOf: store.fileURL))
                let durable = original.taskCommand == nil || disk?.contains(where: {
                    $0.messageID == original.messageID && $0.taskID == original.taskCommand?.taskID
                        && CommandRecovery.original($0.envelopeData)?.taskCommand?.prompt.utf8.elementsEqual(original.taskCommand!.prompt.utf8) == true
                }) == true
                posts.append(.init(envelope: original, body: bytes, durableBeforeSend: durable))
                if failuresRemaining > 0 { failuresRemaining -= 1; return .init(status: 503, body: Data()) }
                // HTTP queue acceptance is not a Mac ACK.
                return .init(status: 200, body: Data("{}".utf8))
            }
            if request.httpMethod == "GET", path.hasSuffix("/snapshot") { return .init(status: 204, body: Data()) }
            if request.httpMethod == "GET", let mailbox = path.split(separator: "/").last,
               mailbox == "phone" || mailbox == "watch" {
                let packets = try inbox.map { try cipher.seal($0, destination: String(mailbox)) }
                return .init(status: 200, body: try CodexWatchCoding.makeEncoder().encode(packets))
            }
            if request.httpMethod == "DELETE", let id = path.split(separator: "/").last {
                inbox.removeAll { $0.messageID == String(id) }
                return .init(status: 200, body: Data("{}".utf8))
            }
            fixtureFailures.append("unconfigured_fixture_request")
            return .init(status: 400, body: Data())
        }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open(); defer { stream.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count < 100_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return bytes
    }
}

final class ControllerFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: ControllerHTTPFixture] = [:]
    func insert(_ value: ControllerHTTPFixture, id: String) { lock.withLock { fixtures[id] = value } }
    func fixture(_ id: String) -> ControllerHTTPFixture? { lock.withLock { fixtures[id] } }
    func reset() { lock.withLock { fixtures.removeAll() } }
}

final class ControllerURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ControllerFixtureRegistry()
    // Catch every request in this private session; unregistered origins fail
    // here instead of falling through to real networking.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.host == "relay-controller-fixture.invalid",
                  let id = request.url?.path.split(separator: "/").first,
                  let fixture = Self.registry.fixture(String(id)) else { throw URLError(.unsupportedURL) }
            let result = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
