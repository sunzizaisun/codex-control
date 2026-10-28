import CryptoKit
import Foundation

public enum RelaySignedMessageError: Error { case invalidIdentity, invalidMessage, invalidSignature, expired, tooLarge }
public enum RelaySignedDestination: String, Codable, Sendable { case mac, phone, watch, snapshot }

/// A trusted peer pin supplied by enrollment, NOT by the incoming message.
/// This value alone does not implement enrollment, revocation refresh or user
/// presence. Never construct a trusted pin from an unverified received JWK.
public struct RelayPeerIdentity: Equatable, Sendable {
    public let roomID: String
    public let keyID: String
    public let deviceID: String
    public let role: RelayDeviceRole
    public let publicKey: RelayDevicePublicKey
    public let expiresAt: Date
    public let revokedAt: Date?

    public init(roomID: String, keyID: String, deviceID: String, role: RelayDeviceRole,
                publicKey: RelayDevicePublicKey, expiresAt: Date, revokedAt: Date? = nil) throws {
        guard RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(deviceID),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expiresAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970 > 0,
              revokedAt == nil || revokedAt!.timeIntervalSince1970.isFinite else { throw RelaySignedMessageError.invalidIdentity }
        self.roomID = roomID; self.keyID = keyID; self.deviceID = deviceID; self.role = role
        self.publicKey = publicKey; self.expiresAt = expiresAt; self.revokedAt = revokedAt
    }
    func validate(now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              expiresAt > now, revokedAt == nil || revokedAt! > now else { throw RelaySignedMessageError.expired }
    }
}

/// Returned only after both the enrolled-key signature and exact scope/time
/// checks succeed. It is NOT an execution receipt or an approval decision.
public struct VerifiedRelayEnvelope: Sendable {
    public let envelope: BridgeEnvelope
    public let originalBytes: Data
    public let originalSHA256: String
    public let sender: RelayPeerIdentity
    public let destination: RelaySignedDestination
    fileprivate init(envelope: BridgeEnvelope, bytes: Data, sender: RelayPeerIdentity, destination: RelaySignedDestination) {
        self.envelope = envelope; self.originalBytes = bytes
        self.originalSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        self.sender = sender; self.destination = destination
    }
}

/// RFC 7515 Compact JWS, with an explicitly typed, restricted flat-JSON
/// profile. The original BridgeEnvelope bytes are opaque base64url inside the
/// signed payload. No normalization or reserialization changes their content.
public struct RelaySignedEnvelope: Equatable, Sendable {
    public static let type = "codex-relay-envelope+jws"
    public static let maximumEnvelopeBytes = 750_000
    public static let maximumCompactBytes = 1_420_000
    public let compactJWS: String

    private struct Header: Codable, Equatable { let alg: String; let typ: String; let kid: String }
    private struct Payload: Codable {
        let version: Int
        let roomID: String
        let keyID: String
        let destination: RelaySignedDestination
        let senderDeviceID: String
        let senderRole: RelayDeviceRole
        let messageID: String
        let sentAt: Int64
        let expiresAt: Int64
        let envelope: String
    }

    public init(compactJWS: String) throws {
        guard compactJWS.utf8.count <= Self.maximumCompactBytes else { throw RelaySignedMessageError.tooLarge }
        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && RelayDeviceEncoding.validASCII(String($0), maximum: Self.maximumCompactBytes) })
        else { throw RelaySignedMessageError.invalidMessage }
        self.compactJWS = compactJWS
    }

    public static func sign(_ envelope: BridgeEnvelope, identity: RelayPeerIdentity,
                            key: RelayDeviceSigningKey, destination: RelaySignedDestination,
                            now: Date = Date()) throws -> Self {
        try sign(originalBytes: CodexWatchCoding.makeEncoder().encode(envelope), identity: identity,
                 key: key, destination: destination, now: now)
    }

    /// Frozen outbox bytes are signed verbatim, including their original
    /// serialization. A reconnect must not rewrite an old action or identity.
    public static func sign(originalBytes original: Data, identity: RelayPeerIdentity,
                            key: RelayDeviceSigningKey, destination: RelaySignedDestination,
                            now: Date = Date()) throws -> Self {
        guard original.count <= maximumEnvelopeBytes else { throw RelaySignedMessageError.tooLarge }
        let envelope = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: original)
        try identity.validate(now: now)
        guard identity.publicKey == key.publicKey, envelope.senderDeviceID == identity.deviceID,
              RelayCredentials.validIdentifier(envelope.messageID), envelope.version == BridgeEnvelope.currentVersion,
              allows(identity.role, destination), RelayOutboxPolicy.isDeliverable(envelope, now: now)
        else { throw RelaySignedMessageError.invalidMessage }
        let header = Header(alg: "Ed25519", typ: type, kid: key.publicKey.thumbprint)
        let payload = Payload(version: 1, roomID: identity.roomID, keyID: identity.keyID, destination: destination,
            senderDeviceID: identity.deviceID, senderRole: identity.role, messageID: envelope.messageID,
            sentAt: try milliseconds(envelope.sentAt), expiresAt: try milliseconds(envelope.deliveryExpiresAt),
            envelope: RelayDeviceEncoding.base64URL(original))
        let signingInput = RelayDeviceEncoding.base64URL(try canonical(header)) + "." + RelayDeviceEncoding.base64URL(try canonical(payload))
        return try .init(compactJWS: signingInput + "." + RelayDeviceEncoding.base64URL(key.signature(for: Data(signingInput.utf8))))
    }

    public func verify(sender: RelayPeerIdentity, roomID: String, keyID: String,
                       destination: RelaySignedDestination, now: Date = Date()) throws -> VerifiedRelayEnvelope {
        try sender.validate(now: now)
        guard sender.roomID == roomID, sender.keyID == keyID else { throw RelaySignedMessageError.invalidIdentity }
        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let headerBytes = RelayDeviceEncoding.decodeBase64URL(parts[0], maximumEncodedBytes: 2048),
              let payloadBytes = RelayDeviceEncoding.decodeBase64URL(parts[1], maximumEncodedBytes: Self.maximumCompactBytes),
              let signature = RelayDeviceEncoding.decodeBase64URL(parts[2]), signature.count == 64
        else { throw RelaySignedMessageError.invalidMessage }
        let header = try JSONDecoder().decode(Header.self, from: headerBytes)
        guard header == Header(alg: "Ed25519", typ: Self.type, kid: sender.publicKey.thumbprint),
              try Self.canonical(header) == headerBytes else { throw RelaySignedMessageError.invalidMessage }
        // No key lookup or network fetch from untrusted JWS headers.
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: sender.publicKey.rawRepresentation)
        guard key.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else { throw RelaySignedMessageError.invalidSignature }
        let payload = try JSONDecoder().decode(Payload.self, from: payloadBytes)
        // This restricted profile is flat ASCII metadata + opaque bytes. Exact
        // canonical comparison rejects unknown/duplicate JSON members without
        // defining a new general-purpose JSON canonicalization protocol.
        guard try Self.canonical(payload) == payloadBytes, payload.version == 1,
              payload.roomID == roomID, payload.keyID == keyID, payload.destination == destination,
              payload.senderDeviceID == sender.deviceID, payload.senderRole == sender.role,
              Self.allows(sender.role, destination), RelayCredentials.validIdentifier(payload.messageID),
              payload.sentAt >= 0, payload.expiresAt > payload.sentAt,
              payload.expiresAt <= 9_007_199_254_740_991,
              let bytes = RelayDeviceEncoding.decodeBase64URL(payload.envelope, maximumEncodedBytes: 1_000_000),
              bytes.count <= Self.maximumEnvelopeBytes else { throw RelaySignedMessageError.invalidMessage }
        let envelope = try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: bytes)
        guard envelope.version == BridgeEnvelope.currentVersion, envelope.messageID == payload.messageID,
              envelope.senderDeviceID == sender.deviceID,
              try Self.milliseconds(envelope.sentAt) == payload.sentAt,
              try Self.milliseconds(envelope.deliveryExpiresAt) == payload.expiresAt
        else { throw RelaySignedMessageError.invalidMessage }
        guard RelayOutboxPolicy.isDeliverable(envelope, now: now) else { throw RelaySignedMessageError.expired }
        return .init(envelope: envelope, bytes: bytes, sender: sender, destination: destination)
    }

    static func allows(_ sender: RelayDeviceRole, _ destination: RelaySignedDestination) -> Bool {
        sender == .mac ? destination != .mac : destination == .mac
    }
    private static func canonical<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard date.timeIntervalSince1970 >= 0, value.isFinite, value <= 9_007_199_254_740_991,
              let result = Int64(exactly: value) else { throw RelaySignedMessageError.invalidMessage }
        return result
    }
}

/// V3 codec selected only through explicit device configuration. Signatures
/// remain inside AES-GCM encryption. V2 and unsigned plaintext are never read
/// as authenticated messages; native integration requires explicit cutover.
struct RelaySignedPacketCipher: Sendable {
    let roomID: String
    let encryptionKey: Data
    let keyID: String

    init(roomID: String, credentials: RelayCredentials) {
        self.roomID = roomID; encryptionKey = credentials.encryptionKey; keyID = credentials.keyID
    }
    init(roomID: String, encryptionKey: Data, keyID: String) throws {
        guard encryptionKey.count == 32,
              SHA256.hash(data: encryptionKey).prefix(16).map({ String(format: "%02x", $0) }).joined() == keyID,
              RelayCredentials.validIdentifier(roomID) else { throw RelaySignedMessageError.invalidIdentity }
        self.roomID = roomID; self.encryptionKey = encryptionKey; self.keyID = keyID
    }

    func seal(_ signed: RelaySignedEnvelope, sender: RelayPeerIdentity, destination: RelaySignedDestination,
              now: Date = Date()) throws -> RelaySealedPacket {
        let verified = try signed.verify(sender: sender, roomID: roomID, keyID: keyID, destination: destination, now: now)
        let original = verified.envelope
        var packet = RelaySealedPacket(version: 3, keyID: keyID, destination: destination.rawValue,
            id: original.messageID, sentAt: Int64((original.sentAt.timeIntervalSince1970 * 1000).rounded()),
            expiresAt: Int64((original.deliveryExpiresAt.timeIntervalSince1970 * 1000).rounded()), sealed: "")
        let box = try AES.GCM.seal(Data(signed.compactJWS.utf8), using: SymmetricKey(data: encryptionKey),
            authenticating: associatedData(packet, destination))
        guard let combined = box.combined else { throw RelaySignedMessageError.invalidMessage }
        packet.sealed = combined.base64EncodedString()
        guard packet.sealed.utf8.count <= 1_900_000 else { throw RelaySignedMessageError.tooLarge }
        return packet
    }

    func open(_ packet: RelaySealedPacket, sender: RelayPeerIdentity, destination: RelaySignedDestination,
              now: Date = Date()) throws -> VerifiedRelayEnvelope {
        try open(packet, peers: [sender], destination: destination, now: now)
    }

    func open(_ packet: RelaySealedPacket, peers: [RelayPeerIdentity], destination: RelaySignedDestination,
              now: Date = Date()) throws -> VerifiedRelayEnvelope {
        let aad = try associatedData(packet, destination)
        guard packet.sealed.utf8.count <= 1_900_000, let combined = Data(base64Encoded: packet.sealed),
              combined.base64EncodedString() == packet.sealed else { throw RelaySignedMessageError.invalidMessage }
        let bytes = try AES.GCM.open(.init(combined: combined), using: SymmetricKey(data: encryptionKey), authenticating: aad)
        guard bytes.count <= RelaySignedEnvelope.maximumCompactBytes, let compact = String(data: bytes, encoding: .utf8) else {
            throw RelaySignedMessageError.invalidMessage
        }
        let signed = try RelaySignedEnvelope(compactJWS: compact)
        let headerPart = compact.split(separator: ".", omittingEmptySubsequences: false)[0]
        guard let headerBytes = RelayDeviceEncoding.decodeBase64URL(String(headerPart), maximumEncodedBytes: 2048),
              let header = try JSONSerialization.jsonObject(with: headerBytes) as? [String: Any],
              let kid = header["kid"] as? String else { throw RelaySignedMessageError.invalidMessage }
        // An untrusted kid selects ONLY an already enrolled and pinned key.
        // It cannot introduce a JWK, grant, lookup URL or network operation.
        let matches = peers.filter { $0.publicKey.thumbprint == kid && $0.roomID == roomID && $0.keyID == keyID }
        guard matches.count == 1, let sender = matches.first else { throw RelaySignedMessageError.invalidIdentity }
        let verified = try signed.verify(sender: sender, roomID: roomID,
            keyID: keyID, destination: destination, now: now)
        guard verified.envelope.messageID == packet.id,
              Int64((verified.envelope.sentAt.timeIntervalSince1970 * 1000).rounded()) == packet.sentAt,
              Int64((verified.envelope.deliveryExpiresAt.timeIntervalSince1970 * 1000).rounded()) == packet.expiresAt
        else { throw RelaySignedMessageError.invalidMessage }
        return verified
    }

    private func associatedData(_ packet: RelaySealedPacket, _ destination: RelaySignedDestination) throws -> Data {
        guard packet.version == 3, packet.keyID == keyID, packet.destination == destination.rawValue,
              RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(packet.id),
              packet.sentAt >= 0, packet.expiresAt > packet.sentAt, packet.expiresAt <= 9_007_199_254_740_991
        else { throw RelaySignedMessageError.invalidMessage }
        return Data(["codex-control/relay/signed", "3", packet.keyID, roomID, packet.destination, packet.id,
                     String(packet.sentAt), String(packet.expiresAt)].joined(separator: "\n").utf8)
    }
}
