import CryptoKit
import Foundation
import Security

public enum RelayEnrollmentError: Error { case invalidInvitation, expiredInvitation, identityConflict, invalidGrant, storage(OSStatus) }

/// Owner-side immutable offer. A fresh HTTP nonce/proof never recreates this
/// offer's secret, ID or absolute deadline. Root owner provisioning is separate
/// and is not enabled by presenting a self-signed key to the relay.
public struct RelayEnrollmentOffer: Sendable, CustomDebugStringConvertible {
    public var debugDescription: String { "RelayEnrollmentOffer(<redacted>)" }
    public let baseURL: URL
    public let roomID: String
    public let keyID: String
    public let role: RelayDeviceRole
    public let invitationID: String
    public let secret: String
    public let expiresAt: Int64
    public let grantExpiresAt: Int64
    public let ownerID: String
    public let ownerKey: RelayDeviceSigningKey
    // Freeze the exact creation bytes once. Fresh HTTP proofs never change
    // this body, and a recovered receipt must identify its exact digest.
    let creationBody: Data
    var creationDigest: String { RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: creationBody))) }
    private struct Body: Encodable {
        let invitationID: String; let role: RelayDeviceRole; let secretHash: String; let expiresAt: Int64; let grantExpiresAt: Int64
    }

    public init(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole, grantExpiresAt: Int64,
                ownerID: String, ownerKey: RelayDeviceSigningKey, now: Date = Date()) throws {
        let current = try RelayEnrollmentInvitation.milliseconds(now)
        guard RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(ownerID),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              role == .phone || role == .watch, grantExpiresAt > current + 120_000,
              grantExpiresAt <= 9_007_199_254_740_991 else { throw RelayEnrollmentError.invalidInvitation }
        self.baseURL = try RelayEnrollmentInvitation.origin(baseURL); self.roomID = roomID; self.keyID = keyID; self.role = role
        self.invitationID = UUID().uuidString
        self.secret = RelayDeviceEncoding.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        self.expiresAt = current + 120_000; self.grantExpiresAt = grantExpiresAt; self.ownerID = ownerID; self.ownerKey = ownerKey
        creationBody = try Self.creationBytes(invitationID: invitationID, role: role, secret: secret,
            expiresAt: expiresAt, grantExpiresAt: grantExpiresAt)
    }
    init(restoring material: RelayOwnerOfferMaterial, ownerKey: RelayDeviceSigningKey) throws {
        try material.validate()
        guard ownerKey.publicKey == material.ownerKey, let url = URL(string: material.baseURL) else {
            throw RelayKeyDeliveryError.identityConflict
        }
        baseURL = url; roomID = material.roomID; keyID = material.keyID; role = material.role
        invitationID = material.invitationID; secret = material.secret; expiresAt = material.expiresAt
        grantExpiresAt = material.grantExpiresAt; ownerID = material.ownerID; self.ownerKey = ownerKey
        creationBody = material.creationBody
    }
    static func creationBytes(invitationID: String, role: RelayDeviceRole, secret: String,
                              expiresAt: Int64, grantExpiresAt: Int64) throws -> Data {
        try RelayEnrollmentInvitation.encoder().encode(Body(invitationID: invitationID, role: role,
            secretHash: RelayDeviceSigningKey.accessTokenHash(secret), expiresAt: expiresAt, grantExpiresAt: grantExpiresAt))
    }
    public func request(accessToken: String, nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        try validateCreation(now: now)
        var request = URLRequest(url: baseURL.appendingPathComponent("v3/rooms/\(roomID)/devices/invitations"))
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue(keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = creationBody
        request.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try ownerKey.proof(for: request, accessToken: accessToken, nonce: nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
    /// Query only this original ID. It cannot create/renew/consume an offer.
    public func creationResultRequest(accessToken: String, nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        try validateCreation(now: now)
        var request = URLRequest(url: baseURL.appendingPathComponent("v3/rooms/\(roomID)/devices/invitations/\(invitationID)"))
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue(keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try ownerKey.proof(for: request, accessToken: accessToken, nonce: nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
    func validateCreation(now: Date) throws {
        guard try RelayEnrollmentInvitation.milliseconds(now) < expiresAt else { throw RelayEnrollmentError.expiredInvitation }
    }
    public func invitation(from data: Data, now: Date = Date()) throws -> RelayEnrollmentInvitation {
        try validatedInvitation(from: data, recovered: false, now: now)
    }
    /// Recovery additionally binds the response to the original frozen POST
    /// body, not merely a matching ID/role/deadline. No secret is returned by
    /// the relay and the saved capability never changes.
    public func recoveredInvitation(from data: Data, now: Date = Date()) throws -> RelayEnrollmentInvitation {
        try validatedInvitation(from: data, recovered: true, now: now)
    }
    private func validatedInvitation(from data: Data, recovered: Bool, now: Date) throws -> RelayEnrollmentInvitation {
        struct Result: Decodable { let authorized: Bool; let invitation: Invitation; let createDigest: String? }
        struct Invitation: Decodable {
            let invitationID: String; let role: RelayDeviceRole; let nonce: String; let expiresAt: Int64
            let grantExpiresAt: Int64; let ownerID: String; let ownerThumbprint: String; let consumed: Bool
        }
        let keys: Set<String> = recovered ? ["authorized", "invitation", "createDigest"] : ["authorized", "invitation"]
        guard data.count <= 4096, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys,
              let fields = object["invitation"] as? [String: Any], Set(fields.keys) == ["invitationID", "role", "nonce", "expiresAt",
                "grantExpiresAt", "ownerID", "ownerThumbprint", "consumed"],
              let result = try? JSONDecoder().decode(Result.self, from: data), result.authorized,
              !recovered || result.createDigest == creationDigest,
              !result.invitation.consumed, result.invitation.invitationID == invitationID, result.invitation.role == role,
              result.invitation.ownerID == ownerID, result.invitation.ownerThumbprint == ownerKey.publicKey.thumbprint,
              result.invitation.expiresAt == expiresAt, result.invitation.grantExpiresAt == grantExpiresAt
        else { throw RelayEnrollmentError.invalidInvitation }
        return try .init(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role, invitationID: invitationID,
            secret: secret, nonce: result.invitation.nonce, expiresAt: expiresAt, grantExpiresAt: grantExpiresAt,
            ownerID: ownerID, ownerKey: ownerKey.publicKey, now: now)
    }
}

/// Candidate v3 profile, not yet selected by the installed pairing UI. The QR
/// is a short-lived capability: never log it or treat its asserted origin as
/// trusted. Callers supply the preconfigured relay origin and intended role.
public struct RelayEnrollmentInvitation: Equatable, Sendable, CustomDebugStringConvertible {
    public var debugDescription: String { "RelayEnrollmentInvitation(<redacted>)" }
    public let baseURL: URL
    public let roomID: String
    public let keyID: String
    public let role: RelayDeviceRole
    public let invitationID: String
    public let secret: String
    public let nonce: String
    public let expiresAt: Int64
    public let grantExpiresAt: Int64
    public let ownerID: String
    public let ownerKey: RelayDevicePublicKey

    private struct Wire: Codable {
        let version: Int
        let baseURL: String
        let roomID: String
        let keyID: String
        let role: RelayDeviceRole
        let invitationID: String
        let secret: String
        let nonce: String
        let expiresAt: Int64
        let grantExpiresAt: Int64
        let ownerID: String
        let ownerKey: RelayDevicePublicKey
    }
    public init(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole, invitationID: String,
                secret: String, nonce: String, expiresAt: Int64, grantExpiresAt: Int64,
                ownerID: String, ownerKey: RelayDevicePublicKey, now: Date = Date()) throws {
        self.baseURL = try Self.origin(baseURL); self.roomID = roomID; self.keyID = keyID; self.role = role
        self.invitationID = invitationID; self.secret = secret; self.nonce = nonce
        self.expiresAt = expiresAt; self.grantExpiresAt = grantExpiresAt; self.ownerID = ownerID; self.ownerKey = ownerKey
        try validate(now: now)
    }
    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else { throw RelayEnrollmentError.invalidInvitation }
        return Int64(value)
    }
    static func origin(_ url: URL) throws -> URL {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let result = URL(string: try RelayDeviceSigningKey.targetURI(url)) else { throw RelayEnrollmentError.invalidInvitation }
        return result
    }
    func validate(now: Date) throws {
        let current = try Self.milliseconds(now)
        guard RelayCredentials.validIdentifier(roomID), RelayCredentials.validIdentifier(invitationID), RelayCredentials.validIdentifier(ownerID),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              role == .phone || role == .watch,
              RelayDeviceEncoding.decodeBase64URL(secret)?.count == 32,
              RelayDeviceEncoding.decodeBase64URL(nonce)?.count == 32,
              expiresAt <= current + 125_000, grantExpiresAt > expiresAt, grantExpiresAt <= 9_007_199_254_740_991
        else { throw RelayEnrollmentError.invalidInvitation }
        guard current < expiresAt else { throw RelayEnrollmentError.expiredInvitation }
    }
    private var wire: Wire { .init(version: 3, baseURL: baseURL.absoluteString, roomID: roomID, keyID: keyID,
        role: role, invitationID: invitationID, secret: secret, nonce: nonce, expiresAt: expiresAt,
        grantExpiresAt: grantExpiresAt, ownerID: ownerID, ownerKey: ownerKey) }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    public var qrPayload: String {
        get throws {
            let data = try Self.encoder().encode(wire)
            var parts = URLComponents(); parts.scheme = "codexcontrol"; parts.host = "pair-v3"
            parts.queryItems = [.init(name: "payload", value: RelayDeviceEncoding.base64URL(data))]
            guard let result = parts.string else { throw RelayEnrollmentError.invalidInvitation }; return result
        }
    }
    public static func parse(_ payload: String, expectedBaseURL: URL, expectedRole: RelayDeviceRole, now: Date = Date()) throws -> Self {
        guard payload.utf8.count <= 8192, let parts = URLComponents(string: payload),
              parts.scheme == "codexcontrol", parts.host == "pair-v3", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "payload", let encoded = query[0].value,
              let bytes = RelayDeviceEncoding.decodeBase64URL(encoded), bytes.count <= 4096 else { throw RelayEnrollmentError.invalidInvitation }
        let wire = try JSONDecoder().decode(Wire.self, from: bytes)
        // Canonical own-profile JSON rejects ignored/duplicate members, role
        // confusion and alternate serializations before any Keychain/network.
        guard try Self.encoder().encode(wire) == bytes, wire.version == 3, wire.role == expectedRole,
              let url = URL(string: wire.baseURL), try origin(url) == origin(expectedBaseURL) else { throw RelayEnrollmentError.invalidInvitation }
        return try Self(baseURL: url, roomID: wire.roomID, keyID: wire.keyID, role: wire.role,
            invitationID: wire.invitationID, secret: wire.secret, nonce: wire.nonce, expiresAt: wire.expiresAt,
            grantExpiresAt: wire.grantExpiresAt, ownerID: wire.ownerID, ownerKey: wire.ownerKey, now: now)
    }
    func route(_ resource: String) -> URL { baseURL.appendingPathComponent("v3/rooms/\(roomID)/\(resource)") }
}

/// Local immutable identity must be durably stored BEFORE sending enrollment.
/// A lost POST response recovers via devices/me using this same key/token; it
/// does not generate another identity, replace a grant or extend the QR expiry.
public struct RelayEnrollmentIntent: Sendable, CustomDebugStringConvertible {
    public var debugDescription: String { "RelayEnrollmentIntent(<redacted>)" }
    public let invitation: RelayEnrollmentInvitation
    public let signingKey: RelayDeviceSigningKey
    public let accessToken: String
    public let deviceID: String
    init(invitation: RelayEnrollmentInvitation, signingKey: RelayDeviceSigningKey, accessToken: String, deviceID: String) throws {
        guard RelayDeviceEncoding.decodeBase64URL(accessToken)?.count == 32, accessToken != invitation.secret,
              RelayCredentials.validIdentifier(deviceID), deviceID != invitation.ownerID,
              signingKey.publicKey != invitation.ownerKey else { throw RelayEnrollmentError.identityConflict }
        self.invitation = invitation; self.signingKey = signingKey; self.accessToken = accessToken; self.deviceID = deviceID
    }
    public func enrollmentRequest(now: Date = Date()) throws -> URLRequest {
        try invitation.validate(now: now)
        struct Body: Encodable { let invitationID: String; let deviceID: String; let jwk: RelayDevicePublicKey; let tokenHash: String }
        var request = URLRequest(url: invitation.route("devices/enroll")); request.httpMethod = "POST"
        request.setValue(invitation.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.timeoutInterval = 15; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try RelayEnrollmentInvitation.encoder().encode(Body(invitationID: invitation.invitationID,
            deviceID: deviceID, jwk: signingKey.publicKey, tokenHash: RelayDeviceSigningKey.accessTokenHash(accessToken)))
        request.setValue("DPoP " + invitation.secret, forHTTPHeaderField: "Authorization")
        request.setValue(try signingKey.proof(for: request, accessToken: invitation.secret, nonce: invitation.nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
    public func ownGrantRequest(nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        var request = URLRequest(url: invitation.route("devices/me")); request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue(invitation.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try signingKey.proof(for: request, accessToken: accessToken, nonce: nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
    public func validateGrant(_ data: Data, now: Date = Date()) throws -> RelayPeerIdentity {
        struct Grant: Codable {
            let roomID: String; let keyID: String; let deviceID: String; let role: RelayDeviceRole
            let jwk: RelayDevicePublicKey; let expiresAt: Int64
        }
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Grant.self, from: data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["roomID", "keyID", "deviceID", "role", "jwk", "expiresAt"],
              value.roomID == invitation.roomID, value.keyID == invitation.keyID, value.deviceID == deviceID,
              value.role == invitation.role, value.jwk == signingKey.publicKey, value.expiresAt == invitation.grantExpiresAt,
              value.expiresAt > (try RelayEnrollmentInvitation.milliseconds(now)) else { throw RelayEnrollmentError.invalidGrant }
        return try RelayPeerIdentity(roomID: value.roomID, keyID: value.keyID, deviceID: value.deviceID,
            role: value.role, publicKey: value.jwk, expiresAt: Date(timeIntervalSince1970: Double(value.expiresAt) / 1000))
    }
}

/// Add-only atomic bundle: key, access token, invitation/owner pin and ID live
/// in ONE non-iCloud Keychain item. No success flag can outlive a failed save.
/// It deliberately cannot overwrite a pending or enrolled identity silently.
public struct RelayEnrollmentKeychain: Sendable {
    public let service: String
    private static let secureMutationLock = NSLock()
    public init(service: String = "com.sunzizai.codexwatch.enrollment.v3") { self.service = service }
    private struct Stored: Codable {
        let version: Int; let invitation: String; let acceptedAt: Int64; let signingKey: Data
        let accessToken: String; let deviceID: String; let thumbprint: String
        var secureQR: String? = nil
        var exchangeKey: Data? = nil
        var keyRequest: Data? = nil
        var keyRequestDigest: String? = nil
        var encryptionKey: Data? = nil
        var enrollmentAttempted: Bool? = nil
        var keyRequestAttempted: Bool? = nil
    }
    public func prepare(_ invitation: RelayEnrollmentInvitation, deviceID: String? = nil, now: Date = Date()) throws -> RelayEnrollmentIntent {
        try invitation.validate(now: now)
        if let deviceID {
            guard RelayCredentials.validIdentifier(deviceID), deviceID != invitation.ownerID else { throw RelayEnrollmentError.identityConflict }
        }
        if let existing = try load(baseURL: invitation.baseURL, roomID: invitation.roomID, keyID: invitation.keyID, role: invitation.role) {
            guard existing.invitation == invitation, deviceID == nil || existing.deviceID == deviceID else { throw RelayEnrollmentError.identityConflict }; return existing
        }
        let key = RelayDeviceSigningKey(), token = RelayDeviceEncoding.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        // A migrated installation preserves its canonical device ID. Frozen
        // queued actions must never be relabeled as a newly generated UUID.
        let intent = try RelayEnrollmentIntent(invitation: invitation, signingKey: key, accessToken: token, deviceID: deviceID ?? UUID().uuidString)
        let record = Stored(version: 1, invitation: try invitation.qrPayload, acceptedAt: try RelayEnrollmentInvitation.milliseconds(now),
            signingKey: key.storageRepresentation, accessToken: token, deviceID: intent.deviceID, thumbprint: key.publicKey.thumbprint)
        var insertion = try query(invitation.baseURL, invitation.roomID, invitation.keyID, invitation.role)
        insertion[kSecValueData as String] = try RelayEnrollmentInvitation.encoder().encode(record)
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load(baseURL: invitation.baseURL, roomID: invitation.roomID, keyID: invitation.keyID, role: invitation.role),
           existing.invitation == invitation, deviceID == nil || existing.deviceID == deviceID { return existing }
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return intent
    }
    public func load(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole) throws -> RelayEnrollmentIntent? {
        try loadRecord(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role)?.1
    }
    private func loadRecord(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole) throws -> (Stored, RelayEnrollmentIntent)? {
        var selection = try query(baseURL, roomID, keyID, role)
        selection[kSecReturnData as String] = true; selection[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(selection as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw RelayEnrollmentError.storage(status) }
        guard bytes.count <= 32_768 else { throw RelayEnrollmentError.identityConflict }
        let stored = try JSONDecoder().decode(Stored.self, from: bytes)
        guard [1, 2].contains(stored.version), stored.acceptedAt >= 0, stored.acceptedAt <= 9_007_199_254_740_991 else { throw RelayEnrollmentError.identityConflict }
        let invitation = try RelayEnrollmentInvitation.parse(stored.invitation, expectedBaseURL: baseURL, expectedRole: role,
            now: Date(timeIntervalSince1970: Double(stored.acceptedAt) / 1000))
        let key = try RelayDeviceSigningKey(rawRepresentation: stored.signingKey)
        guard invitation.roomID == roomID, invitation.keyID == keyID, key.publicKey.thumbprint == stored.thumbprint else { throw RelayEnrollmentError.identityConflict }
        let intent = try RelayEnrollmentIntent(invitation: invitation, signingKey: key, accessToken: stored.accessToken, deviceID: stored.deviceID)
        if stored.version == 1 {
            guard bytes.count <= 16_384, stored.secureQR == nil, stored.exchangeKey == nil, stored.keyRequest == nil,
                  stored.keyRequestDigest == nil, stored.encryptionKey == nil,
                  stored.enrollmentAttempted == nil, stored.keyRequestAttempted == nil else {
                throw RelayEnrollmentError.identityConflict
            }
        } else {
            let (secure, device, _) = try secureRecord(stored, intent)
            if let bytes = stored.encryptionKey {
                guard bytes.count == 32, RelayKeyDeliveryDevice.keyID(bytes) == invitation.keyID,
                      bytes != device.exchangeKey.rawRepresentation, bytes != key.storageRepresentation,
                      bytes != RelayDeviceEncoding.decodeBase64URL(intent.accessToken),
                      bytes != RelayDeviceEncoding.decodeBase64URL(secure.pairingSecret) else { throw RelayKeyDeliveryError.invalid }
            }
        }
        return (stored, intent)
    }

    private func secureRecord(_ stored: Stored, _ intent: RelayEnrollmentIntent) throws -> (RelaySecurePairingInvitation, RelayKeyDeliveryDevice, RelayKeyDeliveryPacket) {
        guard stored.version == 2, let qr = stored.secureQR, let key = stored.exchangeKey, let requestBytes = stored.keyRequest else {
            throw RelayKeyDeliveryError.requiresSecurePairing
        }
        let accepted = Date(timeIntervalSince1970: Double(stored.acceptedAt) / 1000)
        let secure = try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: intent.invitation.baseURL,
            expectedRole: intent.invitation.role, now: accepted)
        let device = try RelayKeyDeliveryDevice(invitation: secure, intent: intent, exchangeKey: key)
        let packet = try RelayKeyDeliveryPacket.parse(requestBytes)
        try packet.validate(secure, phase: "request", deviceID: intent.deviceID, now: accepted)
        guard try stored.keyRequestDigest == packet.digest else { throw RelayKeyDeliveryError.invalid }
        return (secure, device, packet)
    }

    /// Key/token, independent X25519 key, private QR and frozen HPKE request
    /// commit in ONE item before enrollment or key-delivery traffic is possible.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    public func prepareSecure(_ secure: RelaySecurePairingInvitation, deviceID: String? = nil, now: Date = Date()) throws -> RelaySecurePairingPending {
        Self.secureMutationLock.lock(); defer { Self.secureMutationLock.unlock() }
        let invitation = secure.enrollment
        try invitation.validate(now: now)
        if let existing = try loadRecord(baseURL: invitation.baseURL, roomID: invitation.roomID, keyID: invitation.keyID, role: invitation.role) {
            let (saved, _, packet) = try secureRecord(existing.0, existing.1)
            guard saved == secure, deviceID == nil || existing.1.deviceID == deviceID else { throw RelayKeyDeliveryError.identityConflict }
            return .init(intent: existing.1, keyRequest: packet)
        }
        let signing = RelayDeviceSigningKey(), token = RelayDeviceEncoding.base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let intent = try RelayEnrollmentIntent(invitation: invitation, signingKey: signing, accessToken: token, deviceID: deviceID ?? UUID().uuidString)
        let exchange = Curve25519.KeyAgreement.PrivateKey()
        let device = try RelayKeyDeliveryDevice(invitation: secure, intent: intent, exchangeKey: exchange.rawRepresentation)
        let request = try device.makeRequest(now: now)
        var stored = Stored(version: 2, invitation: try invitation.qrPayload, acceptedAt: try RelayEnrollmentInvitation.milliseconds(now),
            signingKey: signing.storageRepresentation, accessToken: token, deviceID: intent.deviceID, thumbprint: signing.publicKey.thumbprint)
        stored.secureQR = try secure.qrPayload; stored.exchangeKey = exchange.rawRepresentation; stored.keyRequest = try request.encodedData
        stored.keyRequestDigest = try request.digest
        stored.enrollmentAttempted = false; stored.keyRequestAttempted = false
        var insertion = try query(invitation.baseURL, invitation.roomID, invitation.keyID, invitation.role)
        let bytes = try RelayEnrollmentInvitation.encoder().encode(stored)
        guard bytes.count <= 32_768 else { throw RelayKeyDeliveryError.invalid }
        insertion[kSecValueData as String] = bytes
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem,
           let (savedRecord, savedIntent) = try loadRecord(baseURL: invitation.baseURL, roomID: invitation.roomID, keyID: invitation.keyID, role: invitation.role) {
            let (saved, _, packet) = try secureRecord(savedRecord, savedIntent)
            guard saved == secure, deviceID == nil || savedIntent.deviceID == deviceID else { throw RelayKeyDeliveryError.identityConflict }
            return .init(intent: savedIntent, keyRequest: packet)
        }
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return .init(intent: intent, keyRequest: request)
    }
    public func loadSecure(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole) throws -> RelaySecurePairingPending? {
        guard let (stored, intent) = try loadRecord(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role) else { return nil }
        let (_, _, packet) = try secureRecord(stored, intent)
        return .init(intent: intent, keyRequest: packet)
    }
    func securePairingState(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole) throws -> RelayPairingStoredState {
        guard let (stored, intent) = try loadRecord(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role) else {
            throw RelayKeyDeliveryError.notReady
        }
        let (_, _, packet) = try secureRecord(stored, intent)
        // A bundle written before attempt journaling may already have been
        // used by its old caller. Missing flags mean uncertain, never fresh.
        return .init(pending: .init(intent: intent, keyRequest: packet),
            enrollmentAttempted: stored.enrollmentAttempted ?? true,
            keyRequestAttempted: stored.keyRequestAttempted ?? true, keyReady: stored.encryptionKey != nil)
    }
    func claimSecureAttempt(_ phase: RelayPairingAttempt, pending: RelaySecurePairingPending) throws -> Bool {
        Self.secureMutationLock.lock(); defer { Self.secureMutationLock.unlock() }
        let base = pending.intent.invitation
        guard let (saved, intent) = try loadRecord(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) else {
            throw RelayKeyDeliveryError.notReady
        }
        let (_, _, packet) = try secureRecord(saved, intent)
        guard intent.deviceID == pending.intent.deviceID, intent.signingKey.publicKey == pending.intent.signingKey.publicKey,
              intent.accessToken == pending.intent.accessToken, packet == pending.keyRequest else { throw RelayKeyDeliveryError.identityConflict }
        var stored = saved
        switch phase {
        case .enrollment:
            guard stored.enrollmentAttempted == false else { return false }; stored.enrollmentAttempted = true
        case .keyRequest:
            guard stored.keyRequestAttempted == false else { return false }; stored.keyRequestAttempted = true
        }
        let bytes = try RelayEnrollmentInvitation.encoder().encode(stored)
        guard bytes.count <= 32_768 else { throw RelayKeyDeliveryError.invalid }
        let status = SecItemUpdate(try query(base.baseURL, base.roomID, base.keyID, base.role) as CFDictionary,
            [kSecValueData as String: bytes] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return true
    }
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    public func finishSecure(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole,
                             response: RelayKeyDeliveryPacket, now: Date = Date()) throws {
        Self.secureMutationLock.lock(); defer { Self.secureMutationLock.unlock() }
        guard let saved = try loadRecord(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role) else { throw RelayKeyDeliveryError.notReady }
        var stored = saved.0
        let intent = saved.1
        let (_, device, request) = try secureRecord(stored, intent)
        let key = try device.openResponse(response, request: request, now: now)
        if let original = stored.encryptionKey {
            guard original == key else { throw RelayKeyDeliveryError.identityConflict }; return
        }
        stored.encryptionKey = key
        let bytes = try RelayEnrollmentInvitation.encoder().encode(stored)
        guard bytes.count <= 32_768 else { throw RelayKeyDeliveryError.invalid }
        // Update only, never recreate a missing identity or report ready on
        // write failure. Authentication and key-ready state remain one item.
        let status = SecItemUpdate(try query(baseURL, roomID, keyID, role) as CFDictionary,
            [kSecValueData as String: bytes] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
    }
    public func secureConfiguration(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole,
                                    ownGrant: Data, owner: RelayPeerIdentity, preparedPacketsURL: URL, now: Date = Date()) throws -> RelayDeviceConfiguration {
        guard let (stored, intent) = try loadRecord(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role),
              let encryption = stored.encryptionKey else { throw RelayKeyDeliveryError.notReady }
        _ = try secureRecord(stored, intent); try owner.validate(now: now)
        guard owner.deviceID == intent.invitation.ownerID, owner.publicKey == intent.invitation.ownerKey,
              owner.role == .mac else { throw RelayKeyDeliveryError.identityConflict }
        return try .init(baseURL: baseURL, identity: intent.validateGrant(ownGrant, now: now), owner: owner,
            signingKey: intent.signingKey, accessToken: intent.accessToken, encryptionKey: encryption, preparedPacketsURL: preparedPacketsURL)
    }
    /// Explicit user-directed forget only. Not called for errors/expiry/retry.
    public func remove(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole) throws {
        let status = SecItemDelete(try query(baseURL, roomID, keyID, role) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayEnrollmentError.storage(status) }
    }
    private func query(_ baseURL: URL, _ roomID: String, _ keyID: String, _ role: RelayDeviceRole) throws -> [String: Any] {
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        guard RelayCredentials.validIdentifier(roomID), keyID.utf8.count == 32,
              keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              role == .phone || role == .watch, !service.isEmpty, service.utf8.count <= 160 else { throw RelayEnrollmentError.identityConflict }
        let scope = [origin.absoluteString, roomID, keyID, role.rawValue].joined(separator: "\n")
        let account = RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8))))
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
