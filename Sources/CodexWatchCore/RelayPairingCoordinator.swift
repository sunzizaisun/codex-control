import Foundation

enum RelayPairingAttempt: Sendable { case enrollment, keyRequest }
struct RelayPairingStoredState: Sendable {
    let pending: RelaySecurePairingPending
    let enrollmentAttempted: Bool
    let keyRequestAttempted: Bool
    let keyReady: Bool
}
protocol RelayPairingPersistence: Sendable {
    func state() throws -> RelayPairingStoredState
    func claim(_ phase: RelayPairingAttempt, pending: RelaySecurePairingPending) throws -> Bool
    func finish(_ response: RelayKeyDeliveryPacket, now: Date) throws
    func configuration(ownGrant: Data, owner: RelayPeerIdentity, now: Date) throws -> RelayDeviceConfiguration
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
private struct RelayPairingKeychainPersistence: RelayPairingPersistence {
    let keychain: RelayEnrollmentKeychain
    let baseURL: URL; let roomID: String; let keyID: String; let role: RelayDeviceRole; let preparedPacketsURL: URL
    func state() throws -> RelayPairingStoredState { try keychain.securePairingState(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role) }
    func claim(_ phase: RelayPairingAttempt, pending: RelaySecurePairingPending) throws -> Bool { try keychain.claimSecureAttempt(phase, pending: pending) }
    func finish(_ response: RelayKeyDeliveryPacket, now: Date) throws {
        try keychain.finishSecure(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role, response: response, now: now)
    }
    func configuration(ownGrant: Data, owner: RelayPeerIdentity, now: Date) throws -> RelayDeviceConfiguration {
        try keychain.secureConfiguration(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role,
            ownGrant: ownGrant, owner: owner, preparedPacketsURL: preparedPacketsURL, now: now)
    }
}

public enum RelayPairingUpdate: Sendable {
    case ready(RelayDeviceConfiguration)
    case awaitingOwner
    case enrollmentUnconfirmed
    case keyRequestUnconfirmed
}

/// Explicit mobile pairing, independent of app timers/default transport. One
/// bounded advance may make an initial enrollment/key upload only after a
/// durable claim. Reconstructed/uncertain advances query the same identity and
/// exact frozen packet; absence never authorizes another POST.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
public actor RelayPairingCoordinator {
    private let store: any RelayPairingPersistence
    private let http: RelayDeviceHTTPClient
    private let clock: @Sendable () -> Date
    private var advancing = false

    public init(keychain: RelayEnrollmentKeychain, baseURL: URL, roomID: String, keyID: String,
                role: RelayDeviceRole, preparedPacketsURL: URL, requestTimeout: TimeInterval = 10,
                waitsForConnectivity: Bool = false, requestTransport: RemoteRelayClient.RequestTransport? = nil) {
        store = RelayPairingKeychainPersistence(keychain: keychain, baseURL: baseURL, roomID: roomID,
            keyID: keyID, role: role, preparedPacketsURL: preparedPacketsURL)
        http = RelayDeviceHTTPClient(baseURL: baseURL, roomID: roomID, keyID: keyID, requestTimeout: requestTimeout,
            waitsForConnectivity: waitsForConnectivity, requestTransport: requestTransport)
        clock = { Date() }
    }
    // Isolated test seam; normal app targets cannot select a memory identity
    // store in place of the authoritative device Keychain.
    init(store: any RelayPairingPersistence, http: RelayDeviceHTTPClient, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.http = http; self.clock = clock
    }
    public func advance() async throws -> RelayPairingUpdate {
        guard !advancing else { throw RelayKeyDeliveryError.notReady }
        advancing = true; defer { advancing = false }
        let initial = try store.state(), pending = initial.pending, intent = pending.intent, base = intent.invitation
        if !initial.enrollmentAttempted {
            let request = try intent.enrollmentRequest(now: clock())
            if try store.claim(.enrollment, pending: pending) {
                do {
                    let reply = try await http.send(request, signingKey: intent.signingKey, accessToken: base.secret,
                        expiresAt: Date(timeIntervalSince1970: Double(base.expiresAt) / 1000), maximumResponseBytes: 4096, fixedNonce: base.nonce)
                    struct Receipt: Decodable { let enrolled: Bool; let alreadyEnrolled: Bool; let grant: RelayDeviceGrant }
                    let receipt: Receipt = try decode(reply.data, keys: ["enrolled", "alreadyEnrolled", "grant"])
                    guard reply.status == 200, receipt.enrolled else { throw RelayEnrollmentError.invalidGrant }
                    _ = try intent.validateGrant(RelayEnrollmentInvitation.encoder().encode(receipt.grant), now: clock())
                } catch is CancellationError { throw CancellationError() }
                catch { return .enrollmentUnconfirmed }
            }
        }
        let expected = try RelayPeerIdentity(roomID: base.roomID, keyID: base.keyID, deviceID: intent.deviceID,
            role: base.role, publicKey: intent.signingKey.publicKey,
            expiresAt: Date(timeIntervalSince1970: Double(base.grantExpiresAt) / 1000))
        let registry = RelayDeviceRegistryClient(baseURL: base.baseURL, identity: expected, signingKey: intent.signingKey,
            accessToken: intent.accessToken, http: http, clock: clock)
        let own = try await registry.ownGrant(), grantData = own.data
        _ = try intent.validateGrant(grantData, now: clock())
        let owner = try await currentOwner(intent: intent, registry: registry)
        if try store.state().keyReady { return .ready(try store.configuration(ownGrant: grantData, owner: owner, now: clock())) }
        guard try RelayEnrollmentInvitation.milliseconds(clock()) < pending.keyRequest.expiresAt else { throw RelayKeyDeliveryError.expired }
        var query = URLRequest(url: base.route("devices/me/key-request")); query.httpMethod = "GET"
        let existing = try await send(query, intent: intent, limit: 8192)
        if existing.status == 204 {
            if try store.claim(.keyRequest, pending: pending) {
                do {
                    let reply = try await send(pending.keyRequestUpload(now: clock()), intent: intent, limit: 1024)
                    struct Receipt: Decodable { let stored: Bool; let duplicate: Bool; let requestID: String; let digest: String }
                    let receipt: Receipt = try decode(reply.data, keys: ["stored", "duplicate", "requestID", "digest"])
                    guard reply.status == 200, receipt.stored, receipt.requestID == pending.keyRequest.requestID,
                          try receipt.digest == pending.keyRequest.digest else { throw RelayKeyDeliveryError.invalid }
                } catch is CancellationError { throw CancellationError() }
                catch { return .keyRequestUnconfirmed }
            } else { return .keyRequestUnconfirmed }
        } else {
            guard existing.status == 200, existing.data == (try pending.keyRequest.encodedData) else { throw RelayKeyDeliveryError.identityConflict }
        }
        let response = try await send(pending.keyResponseQuery(now: clock()), intent: intent, limit: 8192)
        if response.status == 204 { return .awaitingOwner }
        guard response.status == 200 else { throw RelayKeyDeliveryError.invalid }
        try store.finish(RelayKeyDeliveryPacket.parse(response.data), now: clock())
        return .ready(try store.configuration(ownGrant: grantData, owner: owner, now: clock()))
    }
    private func send(_ request: URLRequest, intent: RelayEnrollmentIntent, limit: Int) async throws -> RelayDeviceHTTPClient.Reply {
        try await http.send(request, signingKey: intent.signingKey, accessToken: intent.accessToken,
            expiresAt: Date(timeIntervalSince1970: Double(intent.invitation.grantExpiresAt) / 1000), maximumResponseBytes: limit)
    }
    private func currentOwner(intent: RelayEnrollmentIntent, registry: RelayDeviceRegistryClient) async throws -> RelayPeerIdentity {
        let active = try await registry.peers()
        guard let owner = active.first(where: { $0.deviceID == intent.invitation.ownerID }), owner.role == .mac,
              owner.publicKey == intent.invitation.ownerKey else { throw RelayDeviceTransportError.invalidPeer }
        return owner
    }
    private func decode<T: Decodable>(_ bytes: Data, keys: Set<String>) throws -> T {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == keys else {
            throw RelayDeviceTransportError.unsafeResponse
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
}
