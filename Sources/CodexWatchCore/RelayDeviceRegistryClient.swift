import Foundation

/// Public grant reads for transport, mobile pairing and owner publication.
/// Callers still select/pin the particular owner/recipient; a live peer list
/// never grants authority merely because another public key was listed.
struct RelayDeviceRegistryClient: Sendable {
    let baseURL: URL
    let identity: RelayPeerIdentity
    let signingKey: RelayDeviceSigningKey
    let accessToken: String
    let http: RelayDeviceHTTPClient
    var clock: @Sendable () -> Date = { Date() }

    func ownGrant() async throws -> (identity: RelayPeerIdentity, data: Data) {
        struct Own: Decodable { let authorized: Bool; let grant: RelayDeviceGrant }
        let reply = try await get("devices/me", limit: 4096)
        let value: Own = try decode(reply.data, keys: ["authorized", "grant"])
        guard reply.status == 200, value.authorized, value.grant.revokedAt == nil,
              try value.grant.peer(now: clock()) == identity else { throw RelayDeviceTransportError.invalidPeer }
        return (identity, try RelayEnrollmentInvitation.encoder().encode(value.grant))
    }
    func peers() async throws -> [RelayPeerIdentity] {
        struct Peers: Decodable { let peers: [RelayDeviceGrant]; let capturedAt: Int64 }
        let reply = try await get("devices/peers", limit: 65_536)
        let value: Peers = try decode(reply.data, keys: ["peers", "capturedAt"])
        let now = clock(), milliseconds = try RelayEnrollmentInvitation.milliseconds(now)
        guard reply.status == 200, value.capturedAt >= max(0, milliseconds - 120_000), value.capturedAt <= milliseconds + 60_000,
              value.peers.count <= 64, Set(value.peers.map(\.deviceID)).count == value.peers.count else {
            throw RelayDeviceTransportError.invalidPeer
        }
        let active = try value.peers.filter { $0.revokedAt == nil && $0.expiresAt > milliseconds }.map { try $0.peer(now: now) }
        guard active.allSatisfy({ $0.roomID == identity.roomID && $0.keyID == identity.keyID }), active.contains(identity) else {
            throw RelayDeviceTransportError.invalidPeer
        }
        return active
    }
    /// Known-ID read only, using the shared same-origin/nonce transport. This
    /// does not authorize a creation POST when a previous result is unknown.
    func ownerInvitation(for offer: RelayEnrollmentOffer) async throws -> RelayEnrollmentInvitation? {
        try await ownerInvitationReceipt(for: offer)?.invitation
    }
    func ownerInvitationReceipt(for offer: RelayEnrollmentOffer) async throws -> (invitation: RelayEnrollmentInvitation, data: Data)? {
        try offer.validateCreation(now: clock())
        guard identity.role == .mac, offer.baseURL == baseURL, offer.roomID == identity.roomID, offer.keyID == identity.keyID,
              offer.ownerID == identity.deviceID, offer.ownerKey.publicKey == identity.publicKey,
              signingKey.publicKey == identity.publicKey, offer.grantExpiresAt <= (try RelayEnrollmentInvitation.milliseconds(identity.expiresAt)) else {
            throw RelayDeviceTransportError.invalidPeer
        }
        let reply = try await get("devices/invitations/\(offer.invitationID)", limit: 4096,
            deadline: Date(timeIntervalSince1970: Double(offer.expiresAt) / 1000))
        try offer.validateCreation(now: clock())
        if reply.status == 204 && reply.data.isEmpty { return nil }
        guard reply.status == 200 else { throw RelayDeviceTransportError.unsafeResponse }
        return (try offer.recoveredInvitation(from: reply.data, now: clock()), reply.data)
    }
    private func get(_ resource: String, limit: Int, deadline: Date? = nil) async throws -> RelayDeviceHTTPClient.Reply {
        try identity.validate(now: clock())
        var request = URLRequest(url: baseURL.appendingPathComponent("v3/rooms/\(identity.roomID)/\(resource)"))
        request.httpMethod = "GET"
        return try await http.send(request, signingKey: signingKey, accessToken: accessToken,
            expiresAt: min(identity.expiresAt, deadline ?? identity.expiresAt), maximumResponseBytes: limit)
    }
    private func decode<T: Decodable>(_ bytes: Data, keys: Set<String>) throws -> T {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == keys else {
            throw RelayDeviceTransportError.invalidPeer
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
}
