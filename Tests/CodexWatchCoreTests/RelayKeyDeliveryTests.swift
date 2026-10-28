import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

private let keyNow = Date(timeIntervalSince1970: 1_800_000_000)
private struct KeyFixture {
    let aes = Data(repeating: 61, count: 32)
    let ownerSigning = RelayDeviceSigningKey()
    let phoneSigning = RelayDeviceSigningKey()
    let deviceExchange = Curve25519.KeyAgreement.PrivateKey()
    let offer: RelaySecurePairingOffer
    let invitation: RelaySecurePairingInvitation
    let serverResponse: Data
    let intent: RelayEnrollmentIntent
    let peer: RelayPeerIdentity
    let owner: RelayPeerIdentity
    init(role: RelayDeviceRole = .phone) throws {
        let deadline = Int64(keyNow.timeIntervalSince1970 * 1000) + 3_600_000
        let epoch = RelayKeyDeliveryDevice.keyID(aes)
        let enrollment = try RelayEnrollmentOffer(baseURL: URL(string: "https://relay.example/")!, roomID: "qa", keyID: epoch,
            role: role, grantExpiresAt: deadline, ownerID: "qa-owner", ownerKey: ownerSigning, now: keyNow)
        offer = try .init(enrollment: enrollment)
        serverResponse = try JSONSerialization.data(withJSONObject: ["authorized": true, "invitation": [
            "invitationID": enrollment.invitationID, "role": role.rawValue, "nonce": RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32)),
            "expiresAt": enrollment.expiresAt, "grantExpiresAt": deadline, "ownerID": enrollment.ownerID,
            "ownerThumbprint": ownerSigning.publicKey.thumbprint, "consumed": false]])
        invitation = try offer.invitation(from: serverResponse, now: keyNow)
        intent = try .init(invitation: invitation.enrollment, signingKey: phoneSigning,
            accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 93, count: 32)), deviceID: "qa-" + role.rawValue)
        peer = try .init(roomID: "qa", keyID: epoch, deviceID: intent.deviceID, role: role,
            publicKey: phoneSigning.publicKey, expiresAt: Date(timeIntervalSince1970: Double(deadline) / 1000))
        owner = try .init(roomID: "qa", keyID: epoch, deviceID: enrollment.ownerID, role: .mac,
            publicKey: ownerSigning.publicKey, expiresAt: keyNow.addingTimeInterval(7200))
    }
    var device: RelayKeyDeliveryDevice { get throws { try .init(invitation: invitation, intent: intent, exchangeKey: deviceExchange.rawRepresentation) } }
    var ownerContext: RelayKeyDeliveryOwner { get throws { try .init(invitation: invitation, exchangeKey: offer.exchangeKey.rawRepresentation) } }
    func grant(_ intent: RelayEnrollmentIntent) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["roomID": intent.invitation.roomID, "keyID": intent.invitation.keyID,
            "deviceID": intent.deviceID, "role": intent.invitation.role.rawValue,
            "jwk": ["kty": "OKP", "crv": "Ed25519", "x": intent.signingKey.publicKey.x], "expiresAt": intent.invitation.grantExpiresAt])
    }
}
private func changedPacket(_ packet: RelayKeyDeliveryPacket, _ field: String, _ value: Any) throws -> RelayKeyDeliveryPacket {
    var object = try JSONSerialization.jsonObject(with: packet.encodedData) as! [String: Any]
    object[field] = value
    return try RelayKeyDeliveryPacket.parse(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
}
private func keyHex(_ value: String) -> Data {
    Data(stride(from: 0, to: value.count, by: 2).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
    })
}

// Public CFRG/RFC 9180 Appendix A.2 vectors, never user credentials.
// Pinned source: cfrg/draft-irtf-cfrg-hpke commit
// 5f503c564da00b0687b3de75f1dfbdfc4079ad31/test-vectors.json.
@available(macOS 14.0, *)
@Test func securePairingCryptoKitPSKMatchesIndependentCFRGVector() throws {
    var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
        keyHex("77d114e0212be51cb1d76fa99dd41cfd4d0166b08caa09074430a6c59ef17879")), ciphersuite: .Curve25519_SHA256_ChachaPoly,
        info: keyHex("4f6465206f6e2061204772656369616e2055726e"),
        encapsulatedKey: keyHex("2261299c3f40a9afc133b969a97f05e95be2c514e54f3de26cbe5644ac735b04"),
        presharedKey: SymmetricKey(data: keyHex("0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82")),
        presharedKeyIdentifier: keyHex("456e6e796e20447572696e206172616e204d6f726961"))
    let actual = try recipient.open(keyHex("4a177f9c0d6f15cfdf533fb65bf84aecdc6ab16b8b85b4cf65a370e07fc1d78d28fb073214525276f4a89608ff"),
        authenticating: keyHex("436f756e742d30"))
    #expect(actual == keyHex("4265617574792069732074727574682c20747275746820626561757479"))
}

@available(macOS 14.0, *)
@Test func securePairingCryptoKitAuthenticatedPSKMatchesIndependentCFRGVector() throws {
    var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
        keyHex("7b36a42822e75bf3362dfabbe474b3016236408becb83b859a6909e22803cb0c")), ciphersuite: .Curve25519_SHA256_ChachaPoly,
        info: keyHex("4f6465206f6e2061204772656369616e2055726e"),
        encapsulatedKey: keyHex("656a2e00dc9990fd189e6e473459392df556e9a2758754a09db3f51179a3fc02"),
        authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyHex("3ac5bd4dd66ff9f2740bef0d6ccb66daa77bff7849d7895182b07fb74d087c45")),
        presharedKey: SymmetricKey(data: keyHex("0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82")),
        presharedKeyIdentifier: keyHex("456e6e796e20447572696e206172616e204d6f726961"))
    let actual = try recipient.open(keyHex("9aa52e29274fc6172e38a4461361d2342585d3aeec67fb3b721ecd63f059577c7fe886be0ede01456ebc67d597"),
        authenticating: keyHex("436f756e742d30"))
    #expect(actual == keyHex("4265617574792069732074727574682c20747275746820626561757479"))
}

@Test func securePairingQRIsExplicitCanonicalAndScopedToKnownOriginRole() throws {
    let fixture = try KeyFixture(), qr = try fixture.invitation.qrPayload
    #expect(qr.hasPrefix("codexcontrol://pair-key-v3?payload="))
    #expect(try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: fixture.invitation.enrollment.baseURL, expectedRole: .phone, now: keyNow) == fixture.invitation)
    for candidate in [qr + "&payload=x", qr + "#fragment", try fixture.invitation.enrollment.qrPayload] {
        #expect(throws: (any Error).self) { try RelaySecurePairingInvitation.parse(candidate, expectedBaseURL: fixture.invitation.enrollment.baseURL, expectedRole: .phone, now: keyNow) }
    }
    #expect(throws: (any Error).self) { try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: URL(string: "https://evil.example")!, expectedRole: .phone, now: keyNow) }
    #expect(throws: (any Error).self) { try RelaySecurePairingInvitation.parse(qr, expectedBaseURL: fixture.invitation.enrollment.baseURL, expectedRole: .watch, now: keyNow) }
}

@Test func securePairingRejectsPublicPSKsAndReusedPrivateExchangeMaterial() throws {
    let fixture = try KeyFixture(), invitation = fixture.invitation
    for secret in [invitation.enrollment.secret, invitation.enrollment.nonce,
        RelayDeviceEncoding.base64URL(invitation.enrollment.ownerKey.rawRepresentation), invitation.ownerExchangePublicKey] {
        #expect(throws: (any Error).self) { try RelaySecurePairingInvitation(enrollment: invitation.enrollment,
            ownerExchangePublicKey: invitation.ownerExchangePublicKey, pairingSecret: secret) }
    }
    for bytes in [fixture.intent.signingKey.storageRepresentation, RelayDeviceEncoding.decodeBase64URL(fixture.intent.accessToken)!,
        RelayDeviceEncoding.decodeBase64URL(invitation.enrollment.secret)!, RelayDeviceEncoding.decodeBase64URL(invitation.enrollment.nonce)!,
        RelayDeviceEncoding.decodeBase64URL(invitation.pairingSecret)!] {
        #expect(throws: (any Error).self) { try RelayKeyDeliveryDevice(invitation: invitation, intent: fixture.intent, exchangeKey: bytes) }
    }
}

@available(macOS 14.0, *)
@Test func securePairingHPKEPSKAndAuthenticatedResponseDeliverOnlyExpectedRoomKey() throws {
    for role in [RelayDeviceRole.phone, .watch] {
        let fixture = try KeyFixture(role: role), device = try fixture.device, owner = try fixture.ownerContext
        let request = try device.makeRequest(now: keyNow)
        let response = try owner.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: keyNow)
        #expect(try device.openResponse(response, request: request, now: keyNow) == fixture.aes)
        #expect(request.phase == "request"); #expect(response.phase == "response")
        #expect(try response.requestDigest == request.digest)
        let wire = String(decoding: try response.encodedData, as: UTF8.self)
        #expect(!wire.contains(RelayDeviceEncoding.base64URL(fixture.aes)))
        #expect(!wire.contains(fixture.invitation.pairingSecret))
        #expect(!wire.contains(fixture.intent.accessToken))
    }
}

@available(macOS 14.0, *)
@Test func securePairingWrongPSKAndWrongOwnerKeyFailBeforeAnyPlaintextKey() throws {
    let fixture = try KeyFixture(), request = try fixture.device.makeRequest(now: keyNow)
    let wrong = try RelaySecurePairingInvitation(enrollment: fixture.invitation.enrollment,
        ownerExchangePublicKey: fixture.invitation.ownerExchangePublicKey,
        pairingSecret: RelayDeviceEncoding.base64URL(Data(repeating: 65, count: 32)))
    let owner = try RelayKeyDeliveryOwner(invitation: wrong, exchangeKey: fixture.offer.exchangeKey.rawRepresentation)
    #expect(throws: (any Error).self) { try owner.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: keyNow) }
    #expect(throws: (any Error).self) { try RelayKeyDeliveryOwner(invitation: fixture.invitation, exchangeKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation) }
}

@available(macOS 14.0, *)
@Test func securePairingChangedRequestScopeIdentityAndDeadlineCannotBeAccepted() throws {
    let fixture = try KeyFixture(), request = try fixture.device.makeRequest(now: keyNow), owner = try fixture.ownerContext
    for (field, value) in [("roomID", "other" as Any), ("keyID", String(repeating: "a", count: 32)), ("ownerID", "another-owner"),
        ("deviceID", "another-phone"), ("invitationID", "another-invitation"), ("role", "watch"), ("requestID", "new-request"),
        ("expiresAt", request.expiresAt + 1), ("sealed", RelayDeviceEncoding.base64URL(Data(repeating: 7, count: 48)))] {
        let changed = try changedPacket(request, field, value)
        #expect(throws: (any Error).self) { try owner.makeResponse(changed, peer: fixture.peer, encryptionKey: fixture.aes, now: keyNow) }
    }
}

@available(macOS 14.0, *)
@Test func securePairingResponseIsBoundToExactFrozenRequestAndContext() throws {
    let fixture = try KeyFixture(), device = try fixture.device
    let request = try device.makeRequest(now: keyNow)
    let response = try fixture.ownerContext.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: keyNow)
    let other = try device.makeRequest(now: keyNow)
    #expect(throws: (any Error).self) { try device.openResponse(response, request: other, now: keyNow) }
    for (field, value) in [("deviceID", "other" as Any), ("ownerID", "other"), ("role", "watch"), ("requestID", "other"),
        ("expiresAt", response.expiresAt + 1), ("requestDigest", RelayDeviceEncoding.base64URL(Data(repeating: 7, count: 32))),
        ("sealed", RelayDeviceEncoding.base64URL(Data(repeating: 7, count: 48)))] {
        let changed = try changedPacket(response, field, value)
        #expect(throws: (any Error).self) { try device.openResponse(changed, request: request, now: keyNow) }
    }
}

@available(macOS 14.0, *)
@Test func securePairingStaleRevokedOrDifferentRecipientGrantCannotReceiveAKey() throws {
    let fixture = try KeyFixture(), request = try fixture.device.makeRequest(now: keyNow)
    for peer in [
        try RelayPeerIdentity(roomID: "qa", keyID: fixture.peer.keyID, deviceID: fixture.peer.deviceID, role: .phone,
            publicKey: RelayDeviceSigningKey().publicKey, expiresAt: fixture.peer.expiresAt),
        try RelayPeerIdentity(roomID: "qa", keyID: fixture.peer.keyID, deviceID: fixture.peer.deviceID, role: .phone,
            publicKey: fixture.peer.publicKey, expiresAt: fixture.peer.expiresAt, revokedAt: keyNow),
        try RelayPeerIdentity(roomID: "qa", keyID: fixture.peer.keyID, deviceID: fixture.peer.deviceID, role: .phone,
            publicKey: fixture.peer.publicKey, expiresAt: fixture.peer.expiresAt.addingTimeInterval(0.001))] {
        #expect(throws: (any Error).self) { try fixture.ownerContext.makeResponse(request, peer: peer, encryptionKey: fixture.aes, now: keyNow) }
    }
}

@available(macOS 14.0, *)
@Test func securePairingDeliveryRecoveryDoesNotExtendEnrollmentOrDeliveryDeadlines() throws {
    let fixture = try KeyFixture(), device = try fixture.device, request = try device.makeRequest(now: keyNow)
    let later = keyNow.addingTimeInterval(121)
    #expect(throws: (any Error).self) { try fixture.intent.enrollmentRequest(now: later) }
    let response = try fixture.ownerContext.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: later)
    #expect(try device.openResponse(response, request: request, now: later) == fixture.aes)
    let expiry = Date(timeIntervalSince1970: Double(fixture.invitation.deliveryExpiresAt) / 1000)
    #expect(throws: (any Error).self) { try device.openResponse(response, request: request, now: expiry) }
    #expect(throws: (any Error).self) { try fixture.ownerContext.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: expiry) }
}

@available(macOS 14.0, *)
@Test func securePairingOwnerCannotSubstituteDifferentRoomEncryptionKey() throws {
    let fixture = try KeyFixture(), request = try fixture.device.makeRequest(now: keyNow)
    #expect(throws: (any Error).self) { try fixture.ownerContext.makeResponse(request, peer: fixture.peer,
        encryptionKey: Data(repeating: 88, count: 32), now: keyNow) }
}

@available(macOS 14.0, *)
@Test func securePairingPacketCanonicalProfileRejectsUnknownDuplicateAndOversizedFields() throws {
    let fixture = try KeyFixture(), packet = try fixture.device.makeRequest(now: keyNow), data = try packet.encodedData
    var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    value["pairingSecret"] = fixture.invitation.pairingSecret
    #expect(throws: (any Error).self) { try RelayKeyDeliveryPacket.parse(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) }
    let duplicate = Data(("{\"version\":1," + String(decoding: data, as: UTF8.self).dropFirst()).utf8)
    #expect(throws: (any Error).self) { try RelayKeyDeliveryPacket.parse(duplicate) }
    #expect(throws: (any Error).self) { try RelayKeyDeliveryPacket.parse(Data(repeating: 0, count: 8193)) }
}

@available(macOS 14.0, *)
@Test func securePairingQRSecretNeverAppearsInHTTPAndNonceRetryKeepsFrozenBody() throws {
    let fixture = try KeyFixture(), packet = try fixture.device.makeRequest(now: keyNow)
    let pending = RelaySecurePairingPending(intent: fixture.intent, keyRequest: packet)
    let nonce = RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32))
    let first = try pending.keyRequestUpload(now: keyNow), second = try pending.keyRequestUpload(nonce: nonce, now: keyNow)
    #expect(first.httpBody == second.httpBody)
    #expect(first.value(forHTTPHeaderField: "DPoP") != second.value(forHTTPHeaderField: "DPoP"))
    #expect(first.value(forHTTPHeaderField: "Authorization") == "DPoP " + fixture.intent.accessToken)
    for request in [first, second, try pending.keyResponseQuery(now: keyNow), try fixture.intent.enrollmentRequest(now: keyNow)] {
        #expect(!(request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(fixture.invitation.pairingSecret) })
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(fixture.invitation.pairingSecret))
    }
    #expect(String(reflecting: fixture.offer).contains("<redacted>"))
    #expect(String(reflecting: fixture.invitation).contains("<redacted>"))
    #expect(String(reflecting: pending).contains("<redacted>"))
    #expect(String(reflecting: fixture.intent).contains("<redacted>"))
}

@available(macOS 14.0, *)
@Test func securePairingExportsOnlySyntheticPublicHTTPFixtureWhenExplicitlyRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["CODEX_KEY_DELIVERY_QA_OUTPUT"] else { return }
    guard output.hasPrefix("/private/tmp/key-delivery-qa."), URL(fileURLWithPath: output).lastPathComponent == "swift-key-delivery.json",
          !output.contains("/../") else { throw RelayKeyDeliveryError.invalid }
    let fixture = try KeyFixture(), request = try fixture.device.makeRequest(now: keyNow)
    let reply = try fixture.ownerContext.makeResponse(request, peer: fixture.peer, encryptionKey: fixture.aes, now: keyNow)
    let pending = RelaySecurePairingPending(intent: fixture.intent, keyRequest: request)
    let ownerToken = RelayDeviceEncoding.base64URL(Data(repeating: 94, count: 32))
    let nonce = RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32))
    func wire(_ request: URLRequest) -> [String: Any] {
        var value: [String: Any] = ["url": request.url!.absoluteString, "method": request.httpMethod!, "headers": request.allHTTPHeaderFields ?? [:]]
        if let bytes = request.httpBody { value["body"] = String(decoding: bytes, as: UTF8.self) }; return value
    }
    func get(_ resource: String, owner: Bool) throws -> URLRequest {
        var request = URLRequest(url: fixture.invitation.enrollment.baseURL.appendingPathComponent("v3/rooms/qa/" + resource))
        request.httpMethod = "GET"; request.setValue(fixture.peer.keyID, forHTTPHeaderField: "X-Codex-Relay-Key-ID")
        let token = owner ? ownerToken : fixture.intent.accessToken, key = owner ? fixture.ownerSigning : fixture.phoneSigning
        request.setValue("DPoP " + token, forHTTPHeaderField: "Authorization")
        request.setValue(try key.proof(for: request, accessToken: token, nonce: nonce, now: keyNow), forHTTPHeaderField: "DPoP")
        return request
    }
    func record(_ peer: RelayPeerIdentity, token: String) -> [String: Any] {
        ["roomID": peer.roomID, "keyID": peer.keyID, "deviceID": peer.deviceID, "role": peer.role.rawValue,
         "jwk": ["kty": "OKP", "crv": "Ed25519", "x": peer.publicKey.x], "expiresAt": Int64(peer.expiresAt.timeIntervalSince1970 * 1000),
         "tokenHash": RelayDeviceSigningKey.accessTokenHash(token)]
    }
    let value: [String: Any] = ["synthetic": true, "now": Int64(keyNow.timeIntervalSince1970 * 1000),
        "roots": [record(fixture.owner, token: ownerToken), record(fixture.peer, token: fixture.intent.accessToken)],
        "requestPacket": try JSONSerialization.jsonObject(with: request.encodedData),
        "responsePacket": try JSONSerialization.jsonObject(with: reply.encodedData),
        "upload": wire(try pending.keyRequestUpload(nonce: nonce, now: keyNow)),
        "uploadAgain": wire(try pending.keyRequestUpload(nonce: nonce, now: keyNow)),
        "queryRequest": wire(try get("devices/me/key-request", owner: false)),
        "ownerList": wire(try get("devices/key-requests", owner: true)),
        "ownerReply": wire(try reply.ownerUploadRequest(baseURL: fixture.invitation.enrollment.baseURL, owner: fixture.owner,
            signingKey: fixture.ownerSigning, accessToken: ownerToken, nonce: nonce, now: keyNow)),
        "ownerReplyAgain": wire(try reply.ownerUploadRequest(baseURL: fixture.invitation.enrollment.baseURL, owner: fixture.owner,
            signingKey: fixture.ownerSigning, accessToken: ownerToken, nonce: nonce, now: keyNow)),
        "queryResponse": wire(try pending.keyResponseQuery(nonce: nonce, now: keyNow)),
        "queryResponseAfterRestart": wire(try pending.keyResponseQuery(nonce: nonce, now: keyNow)),
        "ownerQuery": wire(try get("devices/key-responses/qa-phone", owner: true))]
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    guard !String(decoding: data, as: UTF8.self).contains(fixture.invitation.pairingSecret),
          !String(decoding: data, as: UTF8.self).contains(RelayDeviceEncoding.base64URL(fixture.aes)) else { throw RelayKeyDeliveryError.invalid }
    try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
}

#if os(iOS)
private func secureQAItem(_ service: String, scope: [String]) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.joined(separator: "\n").utf8)))),
     kSecAttrSynchronizable as String: false]
}
private func secureQABytes(_ query: [String: Any]) throws -> Data {
    var query = query; query[kSecReturnData as String] = true
    var result: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
    return try #require(result as? Data)
}
@Test func securePairingKeychainAtomicPrepareFrozenPacketAndKeyReadySurviveReconstruction() throws {
    let fixture = try KeyFixture(), base = fixture.invitation.enrollment
    let service = "com.sunzizai.codexwatch.qa.secure." + UUID().uuidString
    let store = RelayEnrollmentKeychain(service: service)
    let ownerStore = RelayKeyDeliveryOwnerStore(service: service + ".owner")
    defer { try? store.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role); try? ownerStore.remove(fixture.invitation) }
    let qr = try ownerStore.prepare(fixture.offer, serverResponse: fixture.serverResponse, now: keyNow)
    #expect(qr == fixture.invitation)
    let pending = try store.prepareSecure(qr, deviceID: "original-installation", now: keyNow)
    let peer = try pending.intent.validateGrant(fixture.grant(pending.intent), now: keyNow)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("qa-sealed-" + UUID().uuidString)
    #expect(throws: (any Error).self) { try store.secureConfiguration(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID,
        role: base.role, ownGrant: fixture.grant(pending.intent), owner: fixture.owner, preparedPacketsURL: path, now: keyNow) }
    let savedPending = try RelayEnrollmentKeychain(service: service).loadSecure(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role)
    let reconstructed = try #require(savedPending)
    #expect(try reconstructed.keyRequest.encodedData == pending.keyRequest.encodedData)
    #expect(reconstructed.intent.deviceID == "original-installation")
    let response = try ownerStore.response(to: pending.keyRequest, invitation: qr, recipient: peer, owner: fixture.owner, encryptionKey: fixture.aes, now: keyNow)
    let second = try RelayKeyDeliveryOwnerStore(service: service + ".owner").response(to: pending.keyRequest,
        invitation: qr, recipient: peer, owner: fixture.owner, encryptionKey: fixture.aes, now: keyNow)
    #expect(try response.encodedData == second.encodedData)
    try store.finishSecure(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role, response: response, now: keyNow)
    try store.finishSecure(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role, response: response, now: keyNow)
    let configuration = try RelayEnrollmentKeychain(service: service).secureConfiguration(baseURL: base.baseURL, roomID: base.roomID,
        keyID: base.keyID, role: base.role, ownGrant: fixture.grant(pending.intent), owner: fixture.owner, preparedPacketsURL: path, now: keyNow)
    #expect(configuration.encryptionKey == fixture.aes)
    #expect(configuration.identity.deviceID == pending.intent.deviceID)
    #expect(configuration.identity.publicKey == pending.intent.signingKey.publicKey)
}

@Test func securePairingKeychainConcurrentPrepareKeepsOneKeyAndOneFrozenCiphertext() async throws {
    let fixture = try KeyFixture(), base = fixture.invitation.enrollment
    let store = RelayEnrollmentKeychain(service: "com.sunzizai.codexwatch.qa.secure." + UUID().uuidString)
    defer { try? store.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let results = try await withThrowingTaskGroup(of: RelaySecurePairingPending.self) { group in
        for _ in 0..<16 { group.addTask { try store.prepareSecure(fixture.invitation, deviceID: "existing-device", now: keyNow) } }
        var results: [RelaySecurePairingPending] = []; for try await item in group { results.append(item) }; return results
    }
    #expect(Set(results.map { $0.intent.accessToken }).count == 1)
    #expect(Set(results.map { $0.intent.signingKey.publicKey.thumbprint }).count == 1)
    let frozen = try results.map { try $0.keyRequest.encodedData }
    #expect(Set(frozen).count == 1)
}

@Test func securePairingCannotSilentlyUpgradeOrReplaceAnAuthOnlyIdentity() throws {
    let fixture = try KeyFixture(), base = fixture.invitation.enrollment
    let store = RelayEnrollmentKeychain(service: "com.sunzizai.codexwatch.qa.secure." + UUID().uuidString)
    defer { try? store.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let original = try store.prepare(base, deviceID: "legacy-candidate", now: keyNow)
    #expect(throws: (any Error).self) { try store.prepareSecure(fixture.invitation, deviceID: "legacy-candidate", now: keyNow) }
    #expect(try store.load(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role)?.signingKey.publicKey == original.signingKey.publicKey)
}

@Test func securePairingCorruptFrozenRequestIsPreservedAndCannotBeRecreated() throws {
    let fixture = try KeyFixture(), base = fixture.invitation.enrollment
    let service = "com.sunzizai.codexwatch.qa.secure." + UUID().uuidString, store = RelayEnrollmentKeychain(service: service)
    defer { try? store.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let pending = try store.prepareSecure(fixture.invitation, now: keyNow)
    let query = secureQAItem(service, scope: [base.baseURL.absoluteString, base.roomID, base.keyID, base.role.rawValue])
    var record = try JSONSerialization.jsonObject(with: secureQABytes(query)) as! [String: Any]
    record["keyRequest"] = try changedPacket(pending.keyRequest, "sealed", RelayDeviceEncoding.base64URL(Data(repeating: 11, count: 48))).encodedData.base64EncodedString()
    let corrupted = try JSONSerialization.data(withJSONObject: record)
    #expect(SecItemUpdate(query as CFDictionary, [kSecValueData as String: corrupted] as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.loadSecure(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    #expect(throws: (any Error).self) { try store.prepareSecure(fixture.invitation, now: keyNow) }
    #expect(try secureQABytes(query) == corrupted)
}

@Test func securePairingCorruptOwnerReplyIsPreservedWithoutRegeneratingCiphertext() throws {
    let fixture = try KeyFixture(), base = fixture.invitation.enrollment
    let service = "com.sunzizai.codexwatch.qa.owner." + UUID().uuidString, store = RelayKeyDeliveryOwnerStore(service: service)
    defer { try? store.remove(fixture.invitation) }
    _ = try store.prepare(fixture.offer, serverResponse: fixture.serverResponse, now: keyNow)
    let request = try fixture.device.makeRequest(now: keyNow)
    let reply = try store.response(to: request, invitation: fixture.invitation, recipient: fixture.peer, owner: fixture.owner,
        encryptionKey: fixture.aes, now: keyNow)
    let query = secureQAItem(service, scope: [base.baseURL.absoluteString, base.roomID, base.keyID, base.ownerID,
        base.ownerKey.thumbprint, base.invitationID])
    var record = try JSONSerialization.jsonObject(with: secureQABytes(query)) as! [String: Any]
    record["response"] = try changedPacket(reply, "sealed", RelayDeviceEncoding.base64URL(Data(repeating: 11, count: 48))).encodedData.base64EncodedString()
    let corrupted = try JSONSerialization.data(withJSONObject: record)
    #expect(SecItemUpdate(query as CFDictionary, [kSecValueData as String: corrupted] as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.response(to: request, invitation: fixture.invitation, recipient: fixture.peer,
        owner: fixture.owner, encryptionKey: fixture.aes, now: keyNow) }
    #expect(try secureQABytes(query) == corrupted)
}
#endif
