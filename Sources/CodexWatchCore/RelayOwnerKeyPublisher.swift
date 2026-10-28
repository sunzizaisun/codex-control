import Foundation

struct RelayOwnerKeyPublication: Sendable {
    let request: RelayKeyDeliveryPacket
    let response: RelayKeyDeliveryPacket
    let attempted: Bool
}
protocol RelayOwnerPublicationPersistence: Sendable {
    func publication(invitation: RelaySecurePairingInvitation, owner: RelayPeerIdentity, now: Date) throws -> RelayOwnerKeyPublication?
    func response(to request: RelayKeyDeliveryPacket, invitation: RelaySecurePairingInvitation, recipient: RelayPeerIdentity,
                  owner: RelayPeerIdentity, encryptionKey: Data, now: Date) throws -> RelayKeyDeliveryPacket
    func claimPublication(_ publication: RelayOwnerKeyPublication, invitation: RelaySecurePairingInvitation,
                          owner: RelayPeerIdentity, now: Date) throws -> Bool
}
@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
extension RelayKeyDeliveryOwnerStore: RelayOwnerPublicationPersistence {}

/// A stored response is only an opaque relay receipt, not proof that the
/// mobile device saved its key or that an executable command was consumed.
public enum RelayOwnerKeyUpdate: Sendable {
    case awaitingRequest
    case responseStored(deviceID: String)
    case publicationUnconfirmed
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
public actor RelayOwnerKeyPublisher {
    private let configuration: RelayDeviceConfiguration
    private let store: any RelayOwnerPublicationPersistence
    private let http: RelayDeviceHTTPClient
    private let clock: @Sendable () -> Date
    private var advancing = false
    public init(ownerConfiguration: RelayDeviceConfiguration, store: RelayKeyDeliveryOwnerStore = .init(),
                requestTimeout: TimeInterval = 10, requestTransport: RemoteRelayClient.RequestTransport? = nil) throws {
        guard ownerConfiguration.identity.role == .mac, ownerConfiguration.identity == ownerConfiguration.owner else {
            throw RelayDeviceTransportError.invalidPeer
        }
        configuration = ownerConfiguration; self.store = store; clock = { Date() }
        http = .init(baseURL: ownerConfiguration.baseURL, roomID: ownerConfiguration.identity.roomID,
            keyID: ownerConfiguration.identity.keyID, requestTimeout: requestTimeout,
            waitsForConnectivity: false, requestTransport: requestTransport)
    }
    init(configuration: RelayDeviceConfiguration, store: any RelayOwnerPublicationPersistence,
         http: RelayDeviceHTTPClient, clock: @escaping @Sendable () -> Date) {
        self.configuration = configuration; self.store = store; self.http = http; self.clock = clock
    }
    public func advance(invitation: RelaySecurePairingInvitation) async throws -> RelayOwnerKeyUpdate {
        guard !advancing else { throw RelayKeyDeliveryError.notReady }; advancing = true; defer { advancing = false }
        let owner = configuration.identity, base = invitation.enrollment
        try owner.validate(now: clock()); try invitation.validateDelivery(now: clock())
        guard owner.role == .mac, owner == configuration.owner, invitation.enrollment.baseURL == configuration.baseURL,
              base.roomID == owner.roomID, base.keyID == owner.keyID, base.ownerID == owner.deviceID,
              base.ownerKey == owner.publicKey else { throw RelayKeyDeliveryError.identityConflict }
        let registry = RelayDeviceRegistryClient(baseURL: configuration.baseURL, identity: owner, signingKey: configuration.signingKey,
            accessToken: configuration.accessToken, http: http, clock: clock)
        _ = try await registry.ownGrant()
        let peers = try await registry.peers()
        var publication = try store.publication(invitation: invitation, owner: owner, now: clock())
        if publication == nil {
            let reply = try await send("devices/key-requests", limit: 1_000_000)
            struct Item: Decodable { let packet: String }
            struct Requests: Decodable { let requests: [Item]; let capturedAt: Int64 }
            let object = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
            guard reply.status == 200, let object, Set(object.keys) == ["requests", "capturedAt"],
                  let raw = object["requests"] as? [[String: Any]], raw.count <= 64,
                  raw.allSatisfy({ Set($0.keys) == ["packet"] }) else { throw RelayDeviceTransportError.unsafeResponse }
            let value = try JSONDecoder().decode(Requests.self, from: reply.data)
            let milliseconds = try RelayEnrollmentInvitation.milliseconds(clock())
            guard value.capturedAt >= max(0, milliseconds - 120_000), value.capturedAt <= milliseconds + 60_000 else {
                throw RelayDeviceTransportError.unsafeResponse
            }
            var matches: [RelayKeyDeliveryPacket] = []
            for item in value.requests {
                guard let bytes = RelayDeviceEncoding.decodeBase64URL(item.packet, maximumEncodedBytes: 12_000), bytes.count <= 8192 else {
                    throw RelayDeviceTransportError.unsafeResponse
                }
                let request = try RelayKeyDeliveryPacket.parse(bytes)
                guard request.phase == "request", request.roomID == owner.roomID, request.keyID == owner.keyID,
                      request.ownerID == owner.deviceID else { throw RelayKeyDeliveryError.identityConflict }
                if request.invitationID == base.invitationID { matches.append(request) }
            }
            guard matches.count <= 1 else { throw RelayKeyDeliveryError.identityConflict }
            guard let request = matches.first else { return .awaitingRequest }
            guard let recipient = peers.first(where: { $0.deviceID == request.deviceID }) else { throw RelayDeviceTransportError.invalidPeer }
            _ = try store.response(to: request, invitation: invitation, recipient: recipient, owner: owner,
                encryptionKey: configuration.encryptionKey, now: clock())
            publication = try store.publication(invitation: invitation, owner: owner, now: clock())
        }
        guard let publication, let recipient = peers.first(where: { $0.deviceID == publication.request.deviceID }) else {
            throw RelayDeviceTransportError.invalidPeer
        }
        // Re-verify current recipient against the original protected request;
        // never publish to a changed key merely because the device ID matches.
        let verified = try store.response(to: publication.request, invitation: invitation, recipient: recipient, owner: owner,
            encryptionKey: configuration.encryptionKey, now: clock())
        guard verified == publication.response else { throw RelayKeyDeliveryError.identityConflict }
        let resource = "devices/key-responses/\(publication.response.deviceID)"
        let existing = try await send(resource, limit: 8192)
        try invitation.validateDelivery(now: clock())
        if existing.status == 200 {
            guard existing.data == (try publication.response.encodedData) else { throw RelayKeyDeliveryError.identityConflict }
            return .responseStored(deviceID: recipient.deviceID)
        }
        guard existing.status == 204 else { throw RelayDeviceTransportError.unsafeResponse }
        guard !publication.attempted, try store.claimPublication(publication, invitation: invitation, owner: owner, now: clock()) else {
            return .publicationUnconfirmed
        }
        do {
            let request = try publication.response.ownerUploadRequest(baseURL: configuration.baseURL, owner: owner,
                signingKey: configuration.signingKey, accessToken: configuration.accessToken, now: clock())
            let reply = try await http.send(request, signingKey: configuration.signingKey, accessToken: configuration.accessToken,
                expiresAt: min(owner.expiresAt, Date(timeIntervalSince1970: Double(publication.response.expiresAt) / 1000)),
                maximumResponseBytes: 1024)
            struct Receipt: Decodable { let stored: Bool; let duplicate: Bool; let requestID: String; let digest: String }
            guard let object = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
                  Set(object.keys) == ["stored", "duplicate", "requestID", "digest"] else { throw RelayDeviceTransportError.unsafeResponse }
            let value = try JSONDecoder().decode(Receipt.self, from: reply.data)
            guard reply.status == 200, value.stored, value.requestID == publication.response.requestID,
                  try value.digest == publication.response.digest else { throw RelayDeviceTransportError.unsafeResponse }
            try invitation.validateDelivery(now: clock())
            return .responseStored(deviceID: recipient.deviceID)
        } catch is CancellationError { throw CancellationError() }
        catch { return .publicationUnconfirmed }
    }
    private func send(_ resource: String, limit: Int) async throws -> RelayDeviceHTTPClient.Reply {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v3/rooms/\(configuration.identity.roomID)/\(resource)"))
        request.httpMethod = "GET"
        return try await http.send(request, signingKey: configuration.signingKey, accessToken: configuration.accessToken,
            expiresAt: configuration.identity.expiresAt, maximumResponseBytes: limit)
    }
}
