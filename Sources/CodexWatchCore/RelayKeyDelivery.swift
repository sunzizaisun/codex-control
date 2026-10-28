import CryptoKit
import Foundation

public enum RelayKeyDeliveryError: Error { case invalid, expired, requiresSecurePairing, identityConflict, notReady }

public struct RelaySecurePairingPending: Sendable, CustomDebugStringConvertible {
    public let intent: RelayEnrollmentIntent
    public let keyRequest: RelayKeyDeliveryPacket
    public func keyRequestUpload(nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        guard try RelayEnrollmentInvitation.milliseconds(now) < keyRequest.expiresAt else { throw RelayKeyDeliveryError.expired }
        return try authorizedRequest("devices/me/key-request", method: "POST", body: keyRequest.encodedData, nonce: nonce, now: now)
    }
    public func keyResponseQuery(nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        try authorizedRequest("devices/me/room-key", method: "GET", body: nil, nonce: nonce, now: now)
    }
    private func authorizedRequest(_ route: String, method: String, body: Data?, nonce: String?, now: Date) throws -> URLRequest {
        guard try RelayEnrollmentInvitation.milliseconds(now) < intent.invitation.grantExpiresAt else { throw RelayKeyDeliveryError.expired }
        var request = URLRequest(url: intent.invitation.route(route)); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 15; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(intent.invitation.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.setValue("DPoP " + intent.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try intent.signingKey.proof(for: request, accessToken: intent.accessToken, nonce: nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
    public var debugDescription: String { "RelaySecurePairingPending(<redacted>)" }
}

/// The QR-only PSK is independent of the enrollment capability sent to the
/// server. The server must never receive it, a room key or a private exchange key.
public struct RelaySecurePairingOffer: Sendable, CustomDebugStringConvertible {
    public let enrollment: RelayEnrollmentOffer
    let exchangeKey: Curve25519.KeyAgreement.PrivateKey
    let pairingSecret: Data
    public init(enrollment: RelayEnrollmentOffer) throws {
        try self.init(enrollment: enrollment, exchangeKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            pairingSecret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }
    init(enrollment: RelayEnrollmentOffer, exchangeKey: Data, pairingSecret: Data) throws {
        self.enrollment = enrollment; self.exchangeKey = try .init(rawRepresentation: exchangeKey); self.pairingSecret = pairingSecret
        guard let capability = RelayDeviceEncoding.decodeBase64URL(enrollment.secret),
              pairingSecret.count == 32, pairingSecret != capability, pairingSecret != exchangeKey,
              pairingSecret != enrollment.ownerKey.storageRepresentation,
              exchangeKey != capability,
              exchangeKey != enrollment.ownerKey.storageRepresentation else { throw RelayKeyDeliveryError.invalid }
    }
    // Only the Keychain owner store exposes a new QR to app targets, after
    // durable preparation. Tests may inspect this internal pure constructor.
    func invitation(from data: Data, now: Date = Date()) throws -> RelaySecurePairingInvitation {
        try .init(enrollment: enrollment.invitation(from: data, now: now),
                  ownerExchangePublicKey: RelayDeviceEncoding.base64URL(exchangeKey.publicKey.rawRepresentation),
                  pairingSecret: RelayDeviceEncoding.base64URL(pairingSecret))
    }
    func recoveredInvitation(from data: Data, now: Date = Date()) throws -> RelaySecurePairingInvitation {
        try .init(enrollment: enrollment.recoveredInvitation(from: data, now: now),
            ownerExchangePublicKey: RelayDeviceEncoding.base64URL(exchangeKey.publicKey.rawRepresentation),
            pairingSecret: RelayDeviceEncoding.base64URL(pairingSecret))
    }
    public var debugDescription: String { "RelaySecurePairingOffer(<redacted>)" }
}

/// An explicit new QR surface; legacy auth-only QR cannot silently become a
/// room-key exchange. This is a physical/private pairing capability, not a URL
/// to log, paste into a cloud setting or transmit as an Authorization value.
public struct RelaySecurePairingInvitation: Equatable, Sendable, CustomDebugStringConvertible {
    public let enrollment: RelayEnrollmentInvitation
    public let ownerExchangePublicKey: String
    let pairingSecret: String
    private struct Wire: Codable { let version: Int; let enrollment: String; let ownerExchangePublicKey: String; let pairingSecret: String }
    init(enrollment: RelayEnrollmentInvitation, ownerExchangePublicKey: String, pairingSecret: String) throws {
        guard let exchange = RelayDeviceEncoding.decodeBase64URL(ownerExchangePublicKey), exchange.count == 32,
              let psk = RelayDeviceEncoding.decodeBase64URL(pairingSecret), psk.count == 32,
              psk != RelayDeviceEncoding.decodeBase64URL(enrollment.secret), psk != exchange,
              psk != RelayDeviceEncoding.decodeBase64URL(enrollment.nonce), psk != enrollment.ownerKey.rawRepresentation else { throw RelayKeyDeliveryError.invalid }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: exchange)
        self.enrollment = enrollment; self.ownerExchangePublicKey = ownerExchangePublicKey; self.pairingSecret = pairingSecret
    }
    var deliveryExpiresAt: Int64 { min(enrollment.grantExpiresAt, enrollment.expiresAt + 300_000) }
    func validateDelivery(now: Date) throws {
        guard try RelayEnrollmentInvitation.milliseconds(now) < deliveryExpiresAt else { throw RelayKeyDeliveryError.expired }
    }
    public var qrPayload: String {
        get throws {
            let wire = Wire(version: 1, enrollment: try enrollment.qrPayload,
                ownerExchangePublicKey: ownerExchangePublicKey, pairingSecret: pairingSecret)
            var parts = URLComponents(); parts.scheme = "codexcontrol"; parts.host = "pair-key-v3"
            parts.queryItems = [.init(name: "payload", value: RelayDeviceEncoding.base64URL(try RelayEnrollmentInvitation.encoder().encode(wire)))]
            guard let result = parts.string else { throw RelayKeyDeliveryError.invalid }; return result
        }
    }
    public static func parse(_ qr: String, expectedBaseURL: URL, expectedRole: RelayDeviceRole, now: Date = Date()) throws -> Self {
        guard qr.utf8.count <= 12_288, let parts = URLComponents(string: qr), parts.scheme == "codexcontrol",
              parts.host == "pair-key-v3", parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let query = parts.queryItems, query.count == 1,
              query[0].name == "payload", let text = query[0].value, let bytes = RelayDeviceEncoding.decodeBase64URL(text),
              bytes.count <= 8192 else { throw RelayKeyDeliveryError.invalid }
        let wire = try JSONDecoder().decode(Wire.self, from: bytes)
        guard wire.version == 1, try RelayEnrollmentInvitation.encoder().encode(wire) == bytes else { throw RelayKeyDeliveryError.invalid }
        return try .init(enrollment: RelayEnrollmentInvitation.parse(wire.enrollment,
            expectedBaseURL: expectedBaseURL, expectedRole: expectedRole, now: now),
            ownerExchangePublicKey: wire.ownerExchangePublicKey, pairingSecret: wire.pairingSecret)
    }
    var context: Data {
        Data(["codex-control/pair-key/v1", enrollment.baseURL.absoluteString, enrollment.roomID, enrollment.keyID,
            enrollment.invitationID, enrollment.ownerID, enrollment.ownerKey.thumbprint, ownerExchangePublicKey,
            enrollment.role.rawValue, enrollment.nonce, String(enrollment.expiresAt), String(enrollment.grantExpiresAt)].joined(separator: "\n").utf8)
    }
    public var debugDescription: String { "RelaySecurePairingInvitation(<redacted>)" }
}

/// Only bounded opaque HPKE messages cross the relay; authenticated metadata
/// is canonical and distinct from ordinary AES mailbox packets. One fresh HPKE
/// context per packet avoids an ordered-stream dependency after disconnection.
public struct RelayKeyDeliveryPacket: Codable, Equatable, Sendable {
    public let version: Int
    public let suite: String
    public let phase: String
    public let roomID: String
    public let keyID: String
    public let invitationID: String
    public let ownerID: String
    public let deviceID: String
    public let role: RelayDeviceRole
    public let requestID: String
    public let expiresAt: Int64
    public let requestDigest: String?
    public let enc: String
    public let sealed: String
    static let suiteName = "X25519-HKDF-SHA256-CHACHA20POLY1305"
    private struct Header: Encodable {
        let version: Int; let suite: String; let phase: String; let roomID: String; let keyID: String
        let invitationID: String; let ownerID: String; let deviceID: String; let role: RelayDeviceRole
        let requestID: String; let expiresAt: Int64; let requestDigest: String?
    }
    var headerBytes: Data {
        get throws { try RelayEnrollmentInvitation.encoder().encode(Header(version: version, suite: suite, phase: phase,
            roomID: roomID, keyID: keyID, invitationID: invitationID, ownerID: ownerID, deviceID: deviceID, role: role,
            requestID: requestID, expiresAt: expiresAt, requestDigest: requestDigest)) }
    }
    public var encodedData: Data { get throws { try RelayEnrollmentInvitation.encoder().encode(self) } }
    public static func parse(_ bytes: Data) throws -> Self {
        guard bytes.count <= 8192 else { throw RelayKeyDeliveryError.invalid }
        let packet = try JSONDecoder().decode(Self.self, from: bytes)
        guard try packet.encodedData == bytes else { throw RelayKeyDeliveryError.invalid }
        try packet.validateShape(); return packet
    }
    func validateShape() throws {
        guard version == 1, suite == Self.suiteName, ["request", "response"].contains(phase),
              [roomID, invitationID, ownerID, deviceID, requestID].allSatisfy(RelayCredentials.validIdentifier),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              role == .phone || role == .watch, ownerID != deviceID, expiresAt > 0, expiresAt <= 9_007_199_254_740_991,
              RelayDeviceEncoding.decodeBase64URL(enc)?.count == 32,
              let ciphertext = RelayDeviceEncoding.decodeBase64URL(sealed, maximumEncodedBytes: 6000), ciphertext.count >= 16,
              phase == "request" ? requestDigest == nil : requestDigest.flatMap({ RelayDeviceEncoding.decodeBase64URL($0) })?.count == 32
        else { throw RelayKeyDeliveryError.invalid }
    }
    func validate(_ invitation: RelaySecurePairingInvitation, phase: String, deviceID: String, now: Date) throws {
        try validateShape(); try invitation.validateDelivery(now: now)
        let base = invitation.enrollment
        guard self.phase == phase, roomID == base.roomID, keyID == base.keyID, invitationID == base.invitationID,
              ownerID == base.ownerID, self.deviceID == deviceID, role == base.role,
              expiresAt == invitation.deliveryExpiresAt else { throw RelayKeyDeliveryError.invalid }
    }
    func replacing(enc: Data, sealed: Data) -> Self {
        .init(version: version, suite: suite, phase: phase, roomID: roomID, keyID: keyID, invitationID: invitationID,
            ownerID: ownerID, deviceID: deviceID, role: role, requestID: requestID, expiresAt: expiresAt,
            requestDigest: requestDigest, enc: RelayDeviceEncoding.base64URL(enc), sealed: RelayDeviceEncoding.base64URL(sealed))
    }
    static func header(_ invitation: RelaySecurePairingInvitation, deviceID: String, requestID: String,
                       digest: String? = nil) -> Self {
        let base = invitation.enrollment
        return .init(version: 1, suite: suiteName, phase: digest == nil ? "request" : "response",
            roomID: base.roomID, keyID: base.keyID, invitationID: base.invitationID, ownerID: base.ownerID,
            deviceID: deviceID, role: base.role, requestID: requestID, expiresAt: invitation.deliveryExpiresAt,
            requestDigest: digest, enc: "", sealed: "")
    }
    var digest: String { get throws { RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: try encodedData))) } }
}

struct RelayKeyDeliveryDevice: Sendable {
    let invitation: RelaySecurePairingInvitation
    let intent: RelayEnrollmentIntent
    let exchangeKey: Curve25519.KeyAgreement.PrivateKey
    init(invitation: RelaySecurePairingInvitation, intent: RelayEnrollmentIntent, exchangeKey: Data) throws {
        guard invitation.enrollment == intent.invitation, exchangeKey.count == 32,
              exchangeKey != intent.signingKey.storageRepresentation,
              exchangeKey != RelayDeviceEncoding.decodeBase64URL(intent.accessToken),
              exchangeKey != RelayDeviceEncoding.decodeBase64URL(invitation.enrollment.secret),
              exchangeKey != RelayDeviceEncoding.decodeBase64URL(invitation.enrollment.nonce),
              exchangeKey != RelayDeviceEncoding.decodeBase64URL(invitation.pairingSecret) else { throw RelayKeyDeliveryError.invalid }
        self.invitation = invitation; self.intent = intent; self.exchangeKey = try .init(rawRepresentation: exchangeKey)
    }
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func makeRequest(now: Date) throws -> RelayKeyDeliveryPacket {
        try invitation.validateDelivery(now: now)
        let header = RelayKeyDeliveryPacket.header(invitation, deviceID: intent.deviceID, requestID: UUID().uuidString)
        let payload = KeyRequestPayload(version: 1, deviceKey: intent.signingKey.publicKey,
            exchangePublicKey: RelayDeviceEncoding.base64URL(exchangeKey.publicKey.rawRepresentation), grantExpiresAt: intent.invitation.grantExpiresAt)
        var sender = try HPKE.Sender(recipientKey: invitation.exchangePublicKey(), ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: invitation.info("request"), presharedKey: invitation.psk(), presharedKeyIdentifier: invitation.pskID)
        let ciphertext = try sender.seal(RelayEnrollmentInvitation.encoder().encode(payload), authenticating: header.headerBytes)
        return header.replacing(enc: sender.encapsulatedKey, sealed: ciphertext)
    }
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func openResponse(_ response: RelayKeyDeliveryPacket, request: RelayKeyDeliveryPacket, now: Date) throws -> Data {
        try request.validate(invitation, phase: "request", deviceID: intent.deviceID, now: now)
        try response.validate(invitation, phase: "response", deviceID: intent.deviceID, now: now)
        guard response.requestID == request.requestID, try response.requestDigest == request.digest else { throw RelayKeyDeliveryError.invalid }
        var receiver = try HPKE.Recipient(privateKey: exchangeKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: invitation.info("response"), encapsulatedKey: RelayDeviceEncoding.decodeBase64URL(response.enc)!,
            authenticatedBy: invitation.exchangePublicKey(), presharedKey: invitation.psk(), presharedKeyIdentifier: invitation.pskID)
        let bytes = try receiver.open(RelayDeviceEncoding.decodeBase64URL(response.sealed)!, authenticating: response.headerBytes)
        let payload = try JSONDecoder().decode(KeyResponsePayload.self, from: bytes)
        guard try RelayEnrollmentInvitation.encoder().encode(payload) == bytes, payload.version == 1,
              let key = RelayDeviceEncoding.decodeBase64URL(payload.roomKey), key.count == 32,
              Self.keyID(key) == invitation.enrollment.keyID, key != exchangeKey.rawRepresentation,
              key != intent.signingKey.storageRepresentation, key != RelayDeviceEncoding.decodeBase64URL(intent.accessToken),
              key != RelayDeviceEncoding.decodeBase64URL(invitation.pairingSecret) else { throw RelayKeyDeliveryError.invalid }
        return key
    }
    static func keyID(_ key: Data) -> String { SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined() }
}

struct KeyRequestPayload: Codable {
    let version: Int; let deviceKey: RelayDevicePublicKey; let exchangePublicKey: String; let grantExpiresAt: Int64
}
private struct KeyResponsePayload: Codable { let version: Int; let roomKey: String }

/// Constructed only from a locally saved offer whose QR was displayed after
/// server invitation validation. It never learns device private/auth keys.
struct RelayKeyDeliveryOwner: Sendable {
    let invitation: RelaySecurePairingInvitation
    let exchangeKey: Curve25519.KeyAgreement.PrivateKey
    init(invitation: RelaySecurePairingInvitation, exchangeKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: exchangeKey)
        guard RelayDeviceEncoding.base64URL(key.publicKey.rawRepresentation) == invitation.ownerExchangePublicKey,
              exchangeKey != RelayDeviceEncoding.decodeBase64URL(invitation.pairingSecret) else { throw RelayKeyDeliveryError.invalid }
        self.invitation = invitation; self.exchangeKey = key
    }
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    func makeResponse(_ request: RelayKeyDeliveryPacket, peer: RelayPeerIdentity, encryptionKey: Data, now: Date) throws -> RelayKeyDeliveryPacket {
        try request.validate(invitation, phase: "request", deviceID: peer.deviceID, now: now); try peer.validate(now: now)
        guard peer.roomID == invitation.enrollment.roomID, peer.keyID == invitation.enrollment.keyID,
              peer.role == invitation.enrollment.role, peer.publicKey != invitation.enrollment.ownerKey,
              encryptionKey.count == 32, RelayKeyDeliveryDevice.keyID(encryptionKey) == peer.keyID,
              encryptionKey != exchangeKey.rawRepresentation, encryptionKey != RelayDeviceEncoding.decodeBase64URL(invitation.pairingSecret)
        else { throw RelayKeyDeliveryError.invalid }
        var receiver = try HPKE.Recipient(privateKey: exchangeKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: invitation.info("request"), encapsulatedKey: RelayDeviceEncoding.decodeBase64URL(request.enc)!,
            presharedKey: invitation.psk(), presharedKeyIdentifier: invitation.pskID)
        let bytes = try receiver.open(RelayDeviceEncoding.decodeBase64URL(request.sealed)!, authenticating: request.headerBytes)
        let payload = try JSONDecoder().decode(KeyRequestPayload.self, from: bytes)
        guard try RelayEnrollmentInvitation.encoder().encode(payload) == bytes, payload.version == 1,
              payload.deviceKey == peer.publicKey, payload.grantExpiresAt == invitation.enrollment.grantExpiresAt,
              Int64((peer.expiresAt.timeIntervalSince1970 * 1000).rounded()) == payload.grantExpiresAt,
              let publicBytes = RelayDeviceEncoding.decodeBase64URL(payload.exchangePublicKey), publicBytes.count == 32 else {
            throw RelayKeyDeliveryError.identityConflict
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        let header = try RelayKeyDeliveryPacket.header(invitation, deviceID: peer.deviceID, requestID: request.requestID, digest: request.digest)
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: invitation.info("response"), authenticatedBy: exchangeKey,
            presharedKey: invitation.psk(), presharedKeyIdentifier: invitation.pskID)
        let ciphertext = try sender.seal(RelayEnrollmentInvitation.encoder().encode(KeyResponsePayload(version: 1,
            roomKey: RelayDeviceEncoding.base64URL(encryptionKey))), authenticating: header.headerBytes)
        return header.replacing(enc: sender.encapsulatedKey, sealed: ciphertext)
    }
}

extension RelaySecurePairingInvitation {
    func exchangePublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try .init(rawRepresentation: RelayDeviceEncoding.decodeBase64URL(ownerExchangePublicKey)!)
    }
    func psk() -> SymmetricKey { .init(data: RelayDeviceEncoding.decodeBase64URL(pairingSecret)!) }
    var pskID: Data { Data(SHA256.hash(data: context)) }
    func info(_ direction: String) -> Data { Data(("codex-control/pair-key/v1/" + direction + "\n").utf8) + pskID }
}
