import CryptoKit
import Foundation
import Security

/// Ephemeral owner pairing state, not another device/root credential store.
/// QR is returned only after saving its private HPKE/PSK material. A single
/// leased owner-app process is still required; the lock serializes its tasks,
/// not a claim of cross-process Keychain compare-and-swap.
public struct RelayKeyDeliveryOwnerStore: Sendable {
    public let service: String
    public init(service: String = "com.sunzizai.codexwatch.key-delivery-owner.v3") { self.service = service }
    private static let lock = NSLock()
    private struct Stored: Codable {
        let version: Int; var qr: String?; let acceptedAt: Int64; let exchangeKey: Data
        var requestDigest: String?; var response: Data?
        var responseDigest: String? = nil
        var request: Data? = nil
        var publicationAttempted: Bool? = nil
        var creation: RelayOwnerOfferMaterial? = nil
        var creationAttempted: Bool? = nil
    }
    public func prepare(_ offer: RelaySecurePairingOffer, serverResponse: Data, now: Date = Date()) throws -> RelaySecurePairingInvitation {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let invitation = try offer.invitation(from: serverResponse, now: now)
        let base = invitation.enrollment
        // A legacy after-ACK call cannot bypass a pending v2 creation slot.
        if try read(roleQuery(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role,
            ownerID: base.ownerID, ownerKey: base.ownerKey)) != nil { throw RelayKeyDeliveryError.identityConflict }
        let record = Stored(version: 1, qr: try invitation.qrPayload, acceptedAt: try RelayEnrollmentInvitation.milliseconds(now),
            exchangeKey: offer.exchangeKey.rawRepresentation)
        var insertion = try query(invitation)
        insertion[kSecValueData as String] = try encoded(record)
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let previous = try load(invitation)
            guard previous.qr == record.qr, previous.exchangeKey == record.exchangeKey else { throw RelayKeyDeliveryError.identityConflict }
            return invitation
        }
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return invitation
    }

    /// Recovery never generates or adds a missing authoritative item.
    func loadCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64,
                      now: Date) throws -> RelayOwnerCreationDraft? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let owner = configuration.identity; try owner.validate(now: now)
        guard owner.role == .mac, owner == configuration.owner else { throw RelayKeyDeliveryError.identityConflict }
        let key = try roleQuery(baseURL: configuration.baseURL, roomID: owner.roomID, keyID: owner.keyID,
            role: role, ownerID: owner.deviceID, ownerKey: owner.publicKey)
        guard let record = try read(key) else { return nil }
        return try creationDraft(record, configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
    }
    /// One atomic role-scoped item exists before ANY creation traffic. It
    /// holds the original capability/body/PSK/exchange key, not root credentials.
    func stageCreation(configuration: RelayDeviceConfiguration, role: RelayDeviceRole, grantExpiresAt: Int64,
                       now: Date) throws -> RelayOwnerCreationDraft {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let owner = configuration.identity
        try owner.validate(now: now)
        guard owner.role == .mac, owner == configuration.owner, role == .phone || role == .watch else {
            throw RelayKeyDeliveryError.identityConflict
        }
        let key = try roleQuery(baseURL: configuration.baseURL, roomID: owner.roomID, keyID: owner.keyID,
            role: role, ownerID: owner.deviceID, ownerKey: owner.publicKey)
        if let saved = try read(key) { return try creationDraft(saved, configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now) }
        let enrollment = try RelayEnrollmentOffer(baseURL: configuration.baseURL, roomID: owner.roomID, keyID: owner.keyID,
            role: role, grantExpiresAt: grantExpiresAt, ownerID: owner.deviceID, ownerKey: configuration.signingKey, now: now)
        let offer = try RelaySecurePairingOffer(enrollment: enrollment), draft = RelayOwnerCreationDraft(offer: offer, attempted: false)
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
        var stored = Stored(version: 2, qr: nil, acceptedAt: try RelayEnrollmentInvitation.milliseconds(now), exchangeKey: offer.exchangeKey.rawRepresentation)
        stored.creation = RelayOwnerOfferMaterial(offer: offer); stored.creationAttempted = false
        var insertion = key; insertion[kSecValueData as String] = try encoded(stored)
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem, let saved = try read(key) {
            return try creationDraft(saved, configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
        }
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return draft
    }
    func claimCreation(_ draft: RelayOwnerCreationDraft, configuration: RelayDeviceConfiguration, now: Date) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let base = draft.offer.enrollment
        try draft.validate(configuration: configuration, role: base.role, grantExpiresAt: base.grantExpiresAt, now: now)
        let key = try roleQuery(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role,
            ownerID: base.ownerID, ownerKey: base.ownerKey.publicKey)
        guard var stored = try read(key) else { throw RelayKeyDeliveryError.notReady }
        try matchesCreation(stored, draft: draft)
        guard stored.creationAttempted == false, stored.qr == nil else { return false }
        stored.creationAttempted = true
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: try encoded(stored)] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return true
    }
    func confirmCreation(_ draft: RelayOwnerCreationDraft, serverResponse: Data, configuration: RelayDeviceConfiguration,
                         now: Date) throws -> RelaySecurePairingInvitation {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let base = draft.offer.enrollment
        try draft.validate(configuration: configuration, role: base.role, grantExpiresAt: base.grantExpiresAt, now: now)
        // This must be the digest-bound read receipt, not merely a POST ACK.
        let invitation = try draft.offer.recoveredInvitation(from: serverResponse, now: now)
        let key = try roleQuery(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role,
            ownerID: base.ownerID, ownerKey: base.ownerKey.publicKey)
        guard var stored = try read(key) else { throw RelayKeyDeliveryError.notReady }
        try matchesCreation(stored, draft: draft)
        let qr = try invitation.qrPayload
        if let previous = stored.qr {
            guard previous == qr else { throw RelayKeyDeliveryError.identityConflict }
            _ = try load(invitation)
            if stored.creationAttempted == true { return invitation }
        }
        stored.qr = qr; stored.creationAttempted = true
        // Update the SAME item; no second QR/material authority or add fallback.
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: try encoded(stored)] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return invitation
    }
    private func matchesCreation(_ stored: Stored, draft: RelayOwnerCreationDraft) throws {
        guard stored.version == 2, stored.creation == RelayOwnerOfferMaterial(offer: draft.offer),
              stored.exchangeKey == draft.offer.exchangeKey.rawRepresentation else { throw RelayKeyDeliveryError.identityConflict }
    }
    private func creationDraft(_ stored: Stored, configuration: RelayDeviceConfiguration, role: RelayDeviceRole,
                               grantExpiresAt: Int64, now: Date) throws -> RelayOwnerCreationDraft {
        guard stored.version == 2, let material = stored.creation else { throw RelayKeyDeliveryError.invalid }
        let offer = try material.restore(signingKey: configuration.signingKey, exchangeKey: stored.exchangeKey)
        let draft = RelayOwnerCreationDraft(offer: offer, attempted: stored.creationAttempted ?? true)
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: now)
        if let qr = stored.qr {
            let invitation = try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: configuration.baseURL, expectedRole: role,
                now: Date(timeIntervalSince1970: Double(stored.acceptedAt) / 1000))
            _ = try load(invitation)
        }
        return draft
    }
    /// Reconstruct from a QR only to locate already saved private state. It
    /// never creates a new private key or treats the QR as owner authentication.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
    public func response(to request: RelayKeyDeliveryPacket, invitation: RelaySecurePairingInvitation,
                         recipient: RelayPeerIdentity, owner: RelayPeerIdentity, encryptionKey: Data, now: Date = Date()) throws -> RelayKeyDeliveryPacket {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try owner.validate(now: now); try recipient.validate(now: now)
        guard owner.role == .mac, owner.deviceID == invitation.enrollment.ownerID,
              owner.publicKey == invitation.enrollment.ownerKey, owner.roomID == invitation.enrollment.roomID,
              owner.keyID == invitation.enrollment.keyID else { throw RelayKeyDeliveryError.identityConflict }
        var record = try load(invitation)
        let context = try RelayKeyDeliveryOwner(invitation: invitation, exchangeKey: record.exchangeKey)
        // Re-verify the exact request/active recipient on repeats too. Never
        // send a stored response for an expired or changed peer/request.
        let candidate = try context.makeResponse(request, peer: recipient, encryptionKey: encryptionKey, now: now)
        let digest = try request.digest
        if let bytes = record.response {
            guard record.requestDigest == digest else { throw RelayKeyDeliveryError.identityConflict }
            let previous = try RelayKeyDeliveryPacket.parse(bytes)
            guard previous.requestDigest == digest, previous.requestID == request.requestID,
                  previous.deviceID == recipient.deviceID else { throw RelayKeyDeliveryError.identityConflict }
            return previous
        }
        record.requestDigest = digest; record.response = try candidate.encodedData
        record.responseDigest = try candidate.digest
        record.request = try request.encodedData; record.publicationAttempted = false
        let status = SecItemUpdate(try query(invitation) as CFDictionary,
            [kSecValueData as String: try encoded(record)] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return candidate
    }
    /// Locate one known saved invitation without enumerating Keychain items.
    /// This is recovery of existing private pairing state, never a new offer.
    public func savedInvitation(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole,
                                ownerID: String, ownerKey: RelayDevicePublicKey, invitationID: String) throws -> RelaySecurePairingInvitation? {
        let selection = try selection(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role,
            ownerID: ownerID, ownerKey: ownerKey, invitationID: invitationID)
        guard let record = try read(selection) else { return nil }
        guard let qr = record.qr else { return nil }
        let invitation = try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: baseURL, expectedRole: role,
            now: Date(timeIntervalSince1970: Double(record.acceptedAt) / 1000))
        guard invitation.enrollment.roomID == roomID, invitation.enrollment.keyID == keyID,
              invitation.enrollment.ownerID == ownerID, invitation.enrollment.ownerKey == ownerKey,
              invitation.enrollment.invitationID == invitationID else { throw RelayKeyDeliveryError.identityConflict }
        _ = try load(invitation)
        return invitation
    }
    func publication(invitation: RelaySecurePairingInvitation, owner: RelayPeerIdentity, now: Date) throws -> RelayOwnerKeyPublication? {
        try validateOwner(owner, invitation: invitation, now: now)
        let record = try load(invitation)
        guard let response = record.response else { return nil }
        // Old cache entries might already have been uploaded by a former
        // caller. Without the frozen request/pin, do not authorize a new POST.
        guard let request = record.request else { throw RelayKeyDeliveryError.notReady }
        return .init(request: try RelayKeyDeliveryPacket.parse(request), response: try RelayKeyDeliveryPacket.parse(response),
            attempted: record.publicationAttempted ?? true)
    }
    func claimPublication(_ publication: RelayOwnerKeyPublication, invitation: RelaySecurePairingInvitation,
                          owner: RelayPeerIdentity, now: Date) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try validateOwner(owner, invitation: invitation, now: now)
        var record = try load(invitation)
        guard record.request == (try publication.request.encodedData), record.response == (try publication.response.encodedData),
              try record.requestDigest == publication.request.digest, try record.responseDigest == publication.response.digest else {
            throw RelayKeyDeliveryError.identityConflict
        }
        guard record.publicationAttempted == false else { return false }
        record.publicationAttempted = true
        let status = SecItemUpdate(try query(invitation) as CFDictionary,
            [kSecValueData as String: try encoded(record)] as CFDictionary)
        guard status == errSecSuccess else { throw RelayEnrollmentError.storage(status) }
        return true
    }
    private func validateOwner(_ owner: RelayPeerIdentity, invitation: RelaySecurePairingInvitation, now: Date) throws {
        try owner.validate(now: now); try invitation.validateDelivery(now: now)
        guard owner.role == .mac, owner.deviceID == invitation.enrollment.ownerID, owner.publicKey == invitation.enrollment.ownerKey,
              owner.roomID == invitation.enrollment.roomID, owner.keyID == invitation.enrollment.keyID else {
            throw RelayKeyDeliveryError.identityConflict
        }
    }
    public func remove(_ invitation: RelaySecurePairingInvitation) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let status = SecItemDelete(try query(invitation) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayEnrollmentError.storage(status) }
    }
    private func load(_ invitation: RelaySecurePairingInvitation) throws -> Stored {
        guard let record = try read(query(invitation)) else { throw RelayEnrollmentError.storage(errSecItemNotFound) }
        guard record.version == 1 || record.version == 2, let qr = record.qr, record.acceptedAt >= 0, record.acceptedAt <= 9_007_199_254_740_991,
              (record.requestDigest == nil) == (record.response == nil), (record.responseDigest == nil) == (record.response == nil),
              record.qr == (try invitation.qrPayload), record.request == nil || record.response != nil,
              record.publicationAttempted == nil || record.request != nil else { throw RelayKeyDeliveryError.invalid }
        let parsed = try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: invitation.enrollment.baseURL,
            expectedRole: invitation.enrollment.role, now: Date(timeIntervalSince1970: Double(record.acceptedAt) / 1000))
        guard parsed == invitation else { throw RelayKeyDeliveryError.identityConflict }
        _ = try RelayKeyDeliveryOwner(invitation: invitation, exchangeKey: record.exchangeKey)
        if let response = record.response {
            let packet = try RelayKeyDeliveryPacket.parse(response)
            try packet.validate(invitation, phase: "response", deviceID: packet.deviceID,
                now: Date(timeIntervalSince1970: Double(record.acceptedAt) / 1000))
            guard packet.requestDigest == record.requestDigest, try packet.digest == record.responseDigest else { throw RelayKeyDeliveryError.invalid }
            if let bytes = record.request {
                let original = try RelayKeyDeliveryPacket.parse(bytes)
                try original.validate(invitation, phase: "request", deviceID: packet.deviceID,
                    now: Date(timeIntervalSince1970: Double(record.acceptedAt) / 1000))
                guard try original.digest == record.requestDigest, original.requestID == packet.requestID else { throw RelayKeyDeliveryError.invalid }
            }
        }
        return record
    }
    private func read(_ key: [String: Any]) throws -> Stored? {
        var selection = key
        selection[kSecReturnData as String] = true; selection[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(selection as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw RelayEnrollmentError.storage(status) }
        guard bytes.count <= 32_768 else { throw RelayKeyDeliveryError.invalid }
        let record = try JSONDecoder().decode(Stored.self, from: bytes)
        guard record.version == 1 || record.version == 2, record.acceptedAt >= 0,
              record.acceptedAt <= 9_007_199_254_740_991 else { throw RelayKeyDeliveryError.invalid }
        if record.version == 1 {
            guard record.qr != nil, record.creation == nil, record.creationAttempted == nil else { throw RelayKeyDeliveryError.invalid }
        } else {
            guard let material = record.creation, material.createdAt == record.acceptedAt,
                  try encoded(record) == bytes else { throw RelayKeyDeliveryError.invalid }
            try material.validate()
            let exchange = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: record.exchangeKey)
            guard record.exchangeKey != material.pairingSecret,
                  record.exchangeKey != RelayDeviceEncoding.decodeBase64URL(material.secret),
                  material.ownerExchangePublicKey == RelayDeviceEncoding.base64URL(exchange.publicKey.rawRepresentation) else { throw RelayKeyDeliveryError.invalid }
            if let qr = record.qr {
                let invitation = try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: URL(string: material.baseURL)!, expectedRole: material.role,
                    now: Date(timeIntervalSince1970: Double(record.acceptedAt) / 1000))
                guard material.matches(invitation), record.creationAttempted != false,
                      invitation.ownerExchangePublicKey == RelayDeviceEncoding.base64URL(exchange.publicKey.rawRepresentation) else {
                    throw RelayKeyDeliveryError.invalid
                }
            } else {
                guard record.requestDigest == nil, record.response == nil, record.responseDigest == nil,
                      record.request == nil, record.publicationAttempted == nil else { throw RelayKeyDeliveryError.invalid }
            }
        }
        return record
    }
    private func encoded(_ value: Stored) throws -> Data {
        let bytes = try RelayEnrollmentInvitation.encoder().encode(value)
        guard bytes.count <= 32_768 else { throw RelayKeyDeliveryError.invalid }; return bytes
    }
    private func query(_ invitation: RelaySecurePairingInvitation) throws -> [String: Any] {
        let base = invitation.enrollment
        return try selection(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role,
            ownerID: base.ownerID, ownerKey: base.ownerKey, invitationID: base.invitationID)
    }
    private func selection(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole, ownerID: String,
                           ownerKey: RelayDevicePublicKey, invitationID: String) throws -> [String: Any] {
        let roleKey = try roleQuery(baseURL: baseURL, roomID: roomID, keyID: keyID, role: role, ownerID: ownerID, ownerKey: ownerKey)
        if let stored = try read(roleKey) {
            guard stored.version == 2, let material = stored.creation, material.baseURL == (try RelayEnrollmentInvitation.origin(baseURL)).absoluteString,
                  material.roomID == roomID, material.keyID == keyID, material.ownerID == ownerID,
                  material.ownerKey == ownerKey, material.role == role else { throw RelayKeyDeliveryError.identityConflict }
            if material.invitationID == invitationID { return roleKey }
        }
        return try legacyQuery(baseURL: baseURL, roomID: roomID, keyID: keyID, ownerID: ownerID, ownerKey: ownerKey, invitationID: invitationID)
    }
    func roleQuery(baseURL: URL, roomID: String, keyID: String, role: RelayDeviceRole,
                           ownerID: String, ownerKey: RelayDevicePublicKey) throws -> [String: Any] {
        guard role == .phone || role == .watch else { throw RelayKeyDeliveryError.invalid }
        // Validate the common scope using the original known-ID selector, but
        // use a disjoint versioned 7-field account for ONE authoritative draft.
        _ = try legacyQuery(baseURL: baseURL, roomID: roomID, keyID: keyID, ownerID: ownerID, ownerKey: ownerKey, invitationID: "scope-check")
        let scope = ["owner-offer-v2", try RelayEnrollmentInvitation.origin(baseURL).absoluteString, roomID, keyID,
            ownerID, ownerKey.thumbprint, role.rawValue].joined(separator: "\n")
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8)))),
            kSecAttrSynchronizable as String: false]
        #if os(macOS)
        // Explicitly restrict the new slot to Data Protection Keychain. The
        // macOS compatibility bridge can otherwise target both databases;
        // omission alone does not prove where an old item was stored. Keep
        // legacy v1 selectors unchanged and never broaden this one on error.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
    private func legacyQuery(baseURL: URL, roomID: String, keyID: String, ownerID: String,
                       ownerKey: RelayDevicePublicKey, invitationID: String) throws -> [String: Any] {
        guard !service.isEmpty, service.utf8.count <= 160, [roomID, ownerID, invitationID].allSatisfy(RelayCredentials.validIdentifier),
              keyID.utf8.count == 32, keyID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RelayKeyDeliveryError.invalid
        }
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        let scope = [origin.absoluteString, roomID, keyID, ownerID, ownerKey.thumbprint, invitationID].joined(separator: "\n")
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8)))),
            kSecAttrSynchronizable as String: false]
    }
}

public extension RelayKeyDeliveryPacket {
    func ownerUploadRequest(baseURL: URL, owner: RelayPeerIdentity, signingKey: RelayDeviceSigningKey,
                            accessToken: String, nonce: String? = nil, now: Date = Date()) throws -> URLRequest {
        try validateShape(); try owner.validate(now: now)
        guard phase == "response", owner.role == .mac, owner.deviceID == ownerID, owner.roomID == roomID,
              owner.keyID == keyID, owner.publicKey == signingKey.publicKey,
              try RelayEnrollmentInvitation.milliseconds(now) < expiresAt else { throw RelayKeyDeliveryError.invalid }
        let origin = try RelayEnrollmentInvitation.origin(baseURL)
        var request = URLRequest(url: origin.appendingPathComponent("v3/rooms/\(roomID)/devices/key-responses/\(deviceID)"))
        request.httpMethod = "POST"; request.httpBody = try encodedData; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        request.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try signingKey.proof(for: request, accessToken: accessToken, nonce: nonce, now: now), forHTTPHeaderField: "DPoP")
        return request
    }
}
