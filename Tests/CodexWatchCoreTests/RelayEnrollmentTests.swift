import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

private let enrollmentNow = Date(timeIntervalSince1970: 1_800_000_000)
private let enrollmentOrigin = URL(string: "https://relay.example/")!
private let enrollmentToken = RelayDeviceEncoding.base64URL(Data(repeating: 93, count: 32))
private func enrollmentKey(_ owner: Bool = false) throws -> RelayDeviceSigningKey {
    let hex = owner ? "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb" : "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    return try .init(rawRepresentation: Data(bytes))
}
private func enrollmentInvite(role: RelayDeviceRole = .phone, room: String = "qa", keyID: String = String(repeating: "a", count: 32),
                              deadline: Int64 = 1_800_000_120_000, grantDeadline: Int64 = 1_800_000_600_000) throws -> RelayEnrollmentInvitation {
    try .init(baseURL: enrollmentOrigin, roomID: room, keyID: keyID, role: role, invitationID: "synthetic-invitation",
        secret: RelayDeviceEncoding.base64URL(Data(repeating: 95, count: 32)),
        nonce: RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32)), expiresAt: deadline, grantExpiresAt: grantDeadline,
        ownerID: "qa-owner", ownerKey: enrollmentKey(true).publicKey, now: enrollmentNow)
}
private func enrollmentIntent() throws -> RelayEnrollmentIntent {
    try .init(invitation: enrollmentInvite(), signingKey: enrollmentKey(), accessToken: enrollmentToken, deviceID: "qa-phone")
}
private func alteredEnrollmentQR(_ payload: String, change: ([String: Any]) -> [String: Any]) throws -> String {
    var parts = URLComponents(string: payload)!
    let data = RelayDeviceEncoding.decodeBase64URL(parts.queryItems![0].value!)!
    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let changed = try JSONSerialization.data(withJSONObject: change(value), options: [.sortedKeys, .withoutEscapingSlashes])
    parts.queryItems = [.init(name: "payload", value: RelayDeviceEncoding.base64URL(changed))]
    return parts.string!
}
private func grantData(_ change: ([String: Any]) -> [String: Any] = { $0 }) throws -> Data {
    let intent = try enrollmentIntent(), invitation = intent.invitation
    let key = try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent.signingKey.publicKey))
    return try JSONSerialization.data(withJSONObject: change(["roomID": invitation.roomID, "keyID": invitation.keyID,
        "deviceID": intent.deviceID, "role": invitation.role.rawValue, "jwk": key, "expiresAt": invitation.grantExpiresAt]), options: [.sortedKeys])
}

@Test func enrollmentOwnerNonceRetryKeepsTheSameOfferAndDoesNotUploadTheInvitationSecret() throws {
    let offer = try RelayEnrollmentOffer(baseURL: enrollmentOrigin, roomID: "qa", keyID: String(repeating: "a", count: 32),
        role: .phone, grantExpiresAt: 1_800_000_600_000, ownerID: "qa-owner", ownerKey: enrollmentKey(true), now: enrollmentNow)
    let ownerToken = RelayDeviceEncoding.base64URL(Data(repeating: 94, count: 32))
    let first = try offer.request(accessToken: ownerToken, now: enrollmentNow)
    let second = try offer.request(accessToken: ownerToken, nonce: offer.secret, now: enrollmentNow.addingTimeInterval(1))
    #expect(first.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == offer.keyID)
    #expect(first.httpBody == second.httpBody)
    #expect(first.value(forHTTPHeaderField: "DPoP") != second.value(forHTTPHeaderField: "DPoP"))
    let body = try JSONSerialization.jsonObject(with: first.httpBody!) as! [String: Any]
    #expect(Set(body.keys) == ["invitationID", "role", "secretHash", "expiresAt", "grantExpiresAt"])
    #expect(body["secretHash"] as? String == RelayDeviceSigningKey.accessTokenHash(offer.secret))
    #expect(!String(decoding: first.httpBody!, as: UTF8.self).contains(offer.secret))
    #expect(throws: (any Error).self) { try offer.request(accessToken: ownerToken, now: enrollmentNow.addingTimeInterval(120)) }
}

@Test func enrollmentOwnerOnlyDisplaysQRCodeForAnExactUnconsumedPinnedServerResult() throws {
    let offer = try RelayEnrollmentOffer(baseURL: enrollmentOrigin, roomID: "qa", keyID: String(repeating: "a", count: 32),
        role: .phone, grantExpiresAt: 1_800_000_600_000, ownerID: "qa-owner", ownerKey: enrollmentKey(true), now: enrollmentNow)
    let value: [String: Any] = ["invitationID": offer.invitationID, "role": "phone", "nonce": offer.secret,
        "expiresAt": offer.expiresAt, "grantExpiresAt": offer.grantExpiresAt, "ownerID": offer.ownerID,
        "ownerThumbprint": offer.ownerKey.publicKey.thumbprint, "consumed": false]
    func response(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["authorized": true, "invitation": value]) }
    let invitation = try offer.invitation(from: response(value), now: enrollmentNow)
    #expect(invitation.secret == offer.secret); #expect(invitation.ownerKey == offer.ownerKey.publicKey)
    for (key, replacement) in [("role", "watch" as Any), ("invitationID", "different"), ("ownerID", "different"),
        ("ownerThumbprint", "untrusted"), ("expiresAt", offer.expiresAt + 1), ("grantExpiresAt", offer.grantExpiresAt + 1),
        ("consumed", true), ("nonce", "malformed")] {
        var altered = value; altered[key] = replacement
        let data = try response(altered)
        #expect(throws: (any Error).self) { try offer.invitation(from: data, now: enrollmentNow) }
    }
}

private func recoveredOwnerReceipt(_ offer: RelayEnrollmentOffer, change: ([String: Any]) -> [String: Any] = { $0 }) throws -> Data {
    try JSONSerialization.data(withJSONObject: change(["authorized": true, "createDigest": offer.creationDigest,
        "invitation": ["invitationID": offer.invitationID, "role": offer.role.rawValue, "nonce": offer.secret,
            "expiresAt": offer.expiresAt, "grantExpiresAt": offer.grantExpiresAt, "ownerID": offer.ownerID,
            "ownerThumbprint": offer.ownerKey.publicKey.thumbprint, "consumed": false]]))
}

@Test func ownerCreationRecoveryIsReadOnlyAndBindsExactFrozenOriginalBytes() throws {
    let offer = try RelayEnrollmentOffer(baseURL: enrollmentOrigin, roomID: "qa", keyID: String(repeating: "a", count: 32),
        role: .watch, grantExpiresAt: 1_800_000_600_000, ownerID: "qa-owner", ownerKey: enrollmentKey(true), now: enrollmentNow)
    let token = RelayDeviceEncoding.base64URL(Data(repeating: 94, count: 32))
    let first = try offer.request(accessToken: token, now: enrollmentNow)
    #expect(first.httpBody == offer.creationBody)
    #expect(offer.creationDigest == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: first.httpBody!))))
    for round in 0..<4 {
        let query = try offer.creationResultRequest(accessToken: token, nonce: offer.secret, now: enrollmentNow.addingTimeInterval(Double(round)))
        #expect(query.httpMethod == "GET"); #expect(query.httpBody == nil)
        #expect(query.url!.path == "/v3/rooms/qa/devices/invitations/" + offer.invitationID)
        #expect(query.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == offer.keyID)
        let claims = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(String(query.value(forHTTPHeaderField: "DPoP")!.split(separator: ".")[1]))!) as! [String: Any]
        #expect(claims["urn:codex-control:relay:v3:body-sha256"] == nil)
        let result = try offer.recoveredInvitation(from: recoveredOwnerReceipt(offer), now: enrollmentNow)
        #expect(result.secret == offer.secret); #expect(result.expiresAt == offer.expiresAt); #expect(result.role == .watch)
    }
    #expect(throws: (any Error).self) { try offer.creationResultRequest(accessToken: token, now: enrollmentNow.addingTimeInterval(120)) }
    #expect(throws: (any Error).self) { try offer.recoveredInvitation(from: recoveredOwnerReceipt(offer), now: enrollmentNow.addingTimeInterval(120)) }
}

@Test func recoveredOwnerReceiptRejectsChangedDigestMissingResultAndPrivateOrUnknownFields() throws {
    let offer = try RelayEnrollmentOffer(baseURL: enrollmentOrigin, roomID: "qa", keyID: String(repeating: "a", count: 32),
        role: .phone, grantExpiresAt: 1_800_000_600_000, ownerID: "qa-owner", ownerKey: enrollmentKey(true), now: enrollmentNow)
    for change: ([String: Any]) -> [String: Any] in [
        { var v = $0; v["createDigest"] = nil; return v },
        { var v = $0; v["createDigest"] = RelayDeviceEncoding.base64URL(Data(repeating: 0, count: 32)); return v },
        { var v = $0; v["authorized"] = false; return v },
        { var v = $0; v["invitation"] = nil; return v },
        { var v = $0; v["secretHash"] = "must-not-return"; return v },
        { var v = $0; var i = v["invitation"] as! [String: Any]; i["receipt"] = [:] as [String: Any]; v["invitation"] = i; return v },
        { var v = $0; var i = v["invitation"] as! [String: Any]; i["consumed"] = true; v["invitation"] = i; return v },
        { var v = $0; var i = v["invitation"] as! [String: Any]; i["expiresAt"] = offer.expiresAt + 1; v["invitation"] = i; return v }
    ] {
        let bytes = try recoveredOwnerReceipt(offer, change: change)
        #expect(throws: (any Error).self) { try offer.recoveredInvitation(from: bytes, now: enrollmentNow) }
    }
    #expect(throws: (any Error).self) { try offer.recoveredInvitation(from: Data(repeating: 32, count: 4097), now: enrollmentNow) }
}

@Test func ordinaryOwnerReceiptCannotMasqueradeAsDigestBoundRecoveryOrIgnoreExtraFields() throws {
    let offer = try RelayEnrollmentOffer(baseURL: enrollmentOrigin, roomID: "qa", keyID: String(repeating: "a", count: 32),
        role: .phone, grantExpiresAt: 1_800_000_600_000, ownerID: "qa-owner", ownerKey: enrollmentKey(true), now: enrollmentNow)
    var object = try JSONSerialization.jsonObject(with: recoveredOwnerReceipt(offer)) as! [String: Any]
    let recovered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try offer.invitation(from: recovered, now: enrollmentNow) }
    object["createDigest"] = nil
    let original = try JSONSerialization.data(withJSONObject: object)
    #expect(try offer.invitation(from: original, now: enrollmentNow).invitationID == offer.invitationID)
    #expect(throws: (any Error).self) { try offer.recoveredInvitation(from: original, now: enrollmentNow) }
    object["privateKey"] = "not-an-accepted-result"
    #expect(throws: (any Error).self) { try offer.invitation(from: JSONSerialization.data(withJSONObject: object), now: enrollmentNow) }
}

@Test func enrollmentQRCodeRoundTripsWithPreconfiguredOriginRoleAndOwnerPin() throws {
    let invitation = try enrollmentInvite(), qr = try invitation.qrPayload
    let parsed = try RelayEnrollmentInvitation.parse(qr, expectedBaseURL: URL(string: "https://RELAY.example:443")!, expectedRole: .phone, now: enrollmentNow)
    #expect(parsed == invitation)
    let expectedOwner = try enrollmentKey(true).publicKey
    #expect(parsed.ownerKey == expectedOwner)
    #expect(qr.hasPrefix("codexcontrol://pair-v3?payload="))
}

@Test func enrollmentQRRejectsForeignOriginsRoleConfusionAndAmbiguousPayloadsBeforeStorageOrNetwork() throws {
    let qr = try enrollmentInvite().qrPayload
    for payload in [qr + "&payload=duplicate", qr + "&code=123456", qr + "#fragment", "codexcontrol://pair-v3/path?payload=x",
        try alteredEnrollmentQR(qr) { var v = $0; v["unknown"] = true; return v },
        try alteredEnrollmentQR(qr) { var v = $0; v["version"] = 2; return v },
        try alteredEnrollmentQR(qr) { var v = $0; v["baseURL"] = "https://attacker.invalid/"; return v },
        try alteredEnrollmentQR(qr) { var v = $0; v["baseURL"] = "https://relay.example/redirect"; return v },
        try alteredEnrollmentQR(qr) { var v = $0; v["baseURL"] = "http://relay.example/"; return v },
        try alteredEnrollmentQR(qr) { var v = $0; v["role"] = "mac"; return v },
        String(repeating: "a", count: 8193)] {
        #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(payload, expectedBaseURL: enrollmentOrigin, expectedRole: .phone, now: enrollmentNow) }
    }
    #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(qr, expectedBaseURL: enrollmentOrigin, expectedRole: .watch, now: enrollmentNow) }
    #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(qr, expectedBaseURL: URL(string: "https://other.invalid/")!, expectedRole: .phone, now: enrollmentNow) }
}

@Test func enrollmentQRRejectsExpiredOverlongNoncanonicalAndPrivateKeyMaterial() throws {
    let qr = try enrollmentInvite().qrPayload
    #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(qr, expectedBaseURL: enrollmentOrigin, expectedRole: .phone,
        now: enrollmentNow.addingTimeInterval(120)) }
    for create in [
        { try enrollmentInvite(role: .mac) }, { try enrollmentInvite(room: "path/room") },
        { try enrollmentInvite(keyID: String(repeating: "A", count: 32)) },
        { try enrollmentInvite(deadline: 1_800_000_126_000) }, { try enrollmentInvite(grantDeadline: 1_800_000_100_000) }
    ] { #expect(throws: (any Error).self) { try create() } }
    let privateQR = try alteredEnrollmentQR(qr) { var v = $0; var key = v["ownerKey"] as! [String: Any]; key["d"] = "never-upload"; v["ownerKey"] = key; return v }
    #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(privateQR, expectedBaseURL: enrollmentOrigin, expectedRole: .phone, now: enrollmentNow) }
    var parts = URLComponents(string: qr)!
    let original = RelayDeviceEncoding.decodeBase64URL(parts.queryItems![0].value!)!
    var duplicate = original; duplicate.removeLast(); duplicate.append(contentsOf: Data(",\"version\":3}".utf8))
    parts.queryItems = [.init(name: "payload", value: RelayDeviceEncoding.base64URL(duplicate))]
    #expect(throws: (any Error).self) { try RelayEnrollmentInvitation.parse(parts.string!, expectedBaseURL: enrollmentOrigin, expectedRole: .phone, now: enrollmentNow) }
}

@Test func enrollmentRequestUsesAnIndependentSavedCapabilityAndBindsTheActualBody() throws {
    let intent = try enrollmentIntent(), request = try intent.enrollmentRequest(now: enrollmentNow)
    #expect(request.url!.absoluteString == "https://relay.example/v3/rooms/qa/devices/enroll")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == intent.invitation.keyID)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + intent.invitation.secret)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(Set(body.keys) == ["invitationID", "deviceID", "jwk", "tokenHash"])
    #expect(body["tokenHash"] as? String == RelayDeviceSigningKey.accessTokenHash(enrollmentToken))
    #expect(!String(decoding: request.httpBody!, as: UTF8.self).contains(enrollmentToken))
    let parts = request.value(forHTTPHeaderField: "DPoP")!.split(separator: ".").map(String.init)
    let claims = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(parts[1])!) as! [String: Any]
    #expect(claims["urn:codex-control:relay:v3:body-sha256"] as? String == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: request.httpBody!))))
    #expect(claims["ath"] as? String == RelayDeviceSigningKey.accessTokenHash(intent.invitation.secret))
    #expect(claims["nonce"] as? String == intent.invitation.nonce)
}

@Test func expiredInvitationStopsMutatingRegistrationButKeepsIdentityForReadOnlyRecovery() throws {
    let intent = try enrollmentIntent(), later = enrollmentNow.addingTimeInterval(121)
    #expect(throws: (any Error).self) { try intent.enrollmentRequest(now: later) }
    let request = try intent.ownGrantRequest(nonce: intent.invitation.nonce, now: later)
    #expect(request.httpMethod == "GET"); #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == intent.invitation.keyID)
    #expect(request.url!.path == "/v3/rooms/qa/devices/me")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + enrollmentToken)
    #expect(intent.deviceID == "qa-phone")
}

@Test func enrollmentIdentityRejectsOwnerKeyOwnerIDAndReusedInvitationCapability() throws {
    let invitation = try enrollmentInvite(), key = try enrollmentKey()
    for (key, token, id) in [(key, invitation.secret, "qa-phone"), (try enrollmentKey(true), enrollmentToken, "qa-phone"),
                             (key, enrollmentToken, invitation.ownerID), (key, "invalid-token", "qa-phone")] {
        #expect(throws: (any Error).self) { try RelayEnrollmentIntent(invitation: invitation, signingKey: key, accessToken: token, deviceID: id) }
    }
}

@Test func enrollmentGrantValidationRequiresTheExactSavedIdentityScopeRoleAndLifetime() throws {
    let intent = try enrollmentIntent(), peer = try intent.validateGrant(grantData(), now: enrollmentNow)
    #expect(peer.deviceID == intent.deviceID); #expect(peer.publicKey == intent.signingKey.publicKey)
    #expect(peer.role == .phone)
    let changes: [(String, Any)] = [("roomID", "other"), ("keyID", String(repeating: "b", count: 32)),
        ("deviceID", "other"), ("role", "mac"), ("expiresAt", intent.invitation.grantExpiresAt + 1),
        ("tokenHash", "must-not-be-in-public-grant")]
    for (key, value) in changes {
        let data = try grantData { var v = $0; v[key] = value; return v }
        #expect(throws: (any Error).self) { try intent.validateGrant(data, now: enrollmentNow) }
    }
    #expect(throws: (any Error).self) { try intent.validateGrant(grantData(), now: enrollmentNow.addingTimeInterval(600)) }
}

@Test func enrollmentExportsOnlyExplicitPublicSyntheticRequestVector() throws {
    guard let path = ProcessInfo.processInfo.environment["CODEX_ENROLLMENT_QA_OUTPUT"] else { return }
    guard path.hasPrefix("/private/tmp/relay-enrollment-qa."), URL(fileURLWithPath: path).lastPathComponent == "swift-enrollment.json" else {
        Issue.record("Synthetic enrollment export requires an explicit isolated QA path"); return
    }
    let intent = try enrollmentIntent(), request = try intent.enrollmentRequest(now: enrollmentNow)
    let result: [String: Any] = ["synthetic": true, "now": 1_800_000_000_000 as Int64,
        "uri": request.url!.absoluteString, "method": request.httpMethod!, "body": String(decoding: request.httpBody!, as: UTF8.self),
        "authorization": request.value(forHTTPHeaderField: "Authorization")!, "proof": request.value(forHTTPHeaderField: "DPoP")!,
        "keyIDHeader": request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID")!,
        "nonce": intent.invitation.nonce, "roomID": "qa", "keyID": String(repeating: "a", count: 32),
        "record": ["roomID": "qa", "keyID": String(repeating: "a", count: 32), "deviceID": intent.deviceID,
            "role": "phone", "jwk": try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent.signingKey.publicKey)),
            "tokenHash": RelayDeviceSigningKey.accessTokenHash(intent.invitation.secret), "expiresAt": intent.invitation.expiresAt]]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path), options: .atomic)
}

#if os(iOS)
@Test func enrollmentKeychainMigrationKeepsCanonicalDeviceIDAndRejectsRelabeling() throws {
    let store = RelayEnrollmentKeychain(service: "com.sunzizai.codexwatch.qa.enrollment." + UUID().uuidString)
    let invitation = try enrollmentInvite()
    defer { try? store.remove(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone) }
    let intent = try store.prepare(invitation, deviceID: "original-installation", now: enrollmentNow)
    #expect(intent.deviceID == "original-installation")
    let loaded = try store.load(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone)
    #expect(loaded?.deviceID == intent.deviceID)
    #expect(throws: (any Error).self) { try store.prepare(invitation, deviceID: "different-installation", now: enrollmentNow) }
    #expect(try store.prepare(invitation, deviceID: "original-installation", now: enrollmentNow).signingKey.publicKey == intent.signingKey.publicKey)
}

@Test func enrollmentKeychainAtomicallyKeepsTheSameIdentityAcrossLostACKAndExpiry() throws {
    let store = RelayEnrollmentKeychain(service: "com.sunzizai.codexwatch.qa.enrollment." + UUID().uuidString)
    let invitation = try enrollmentInvite()
    defer { for role in [RelayDeviceRole.phone, .watch] { try? store.remove(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: role) } }
    let first = try store.prepare(invitation, now: enrollmentNow), again = try store.prepare(invitation, now: enrollmentNow)
    #expect(first.deviceID == again.deviceID); #expect(first.accessToken == again.accessToken)
    #expect(first.signingKey.publicKey == again.signingKey.publicKey)
    let loaded = try store.load(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone)!
    #expect(loaded.signingKey.publicKey == first.signingKey.publicKey)
    #expect(try loaded.ownGrantRequest(now: enrollmentNow.addingTimeInterval(121)).value(forHTTPHeaderField: "Authorization") == "DPoP " + first.accessToken)
    #expect(try store.load(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .watch) == nil)
    #expect(try store.load(baseURL: URL(string: "https://other.invalid/")!, roomID: "qa", keyID: invitation.keyID, role: .phone) == nil)
    let watch = try store.prepare(enrollmentInvite(role: .watch), now: enrollmentNow)
    #expect(watch.signingKey.publicKey != first.signingKey.publicKey); #expect(watch.accessToken != first.accessToken)
    let changedInvitation = try enrollmentInvite(deadline: 1_800_000_119_000)
    #expect(throws: (any Error).self) { try store.prepare(changedInvitation, now: enrollmentNow) }
    #expect(try store.load(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone)?.deviceID == first.deviceID)
}

@Test func enrollmentKeychainConcurrentPrepareCreatesOnlyOneImmutableDeviceIdentity() async throws {
    let store = RelayEnrollmentKeychain(service: "com.sunzizai.codexwatch.qa.enrollment." + UUID().uuidString)
    let invitation = try enrollmentInvite()
    defer { try? store.remove(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone) }
    let results = try await withThrowingTaskGroup(of: RelayEnrollmentIntent.self) { group in
        for _ in 0..<16 { group.addTask { try store.prepare(invitation, now: enrollmentNow) } }
        var results: [RelayEnrollmentIntent] = []
        for try await result in group { results.append(result) }; return results
    }
    #expect(results.count == 16)
    #expect(Set(results.map(\.deviceID)).count == 1)
    #expect(Set(results.map(\.accessToken)).count == 1)
    #expect(Set(results.map { $0.signingKey.publicKey.thumbprint }).count == 1)
}

@Test func enrollmentKeychainCorruptionCannotBeReplacedWithASilentNewIdentity() throws {
    let service = "com.sunzizai.codexwatch.qa.enrollment." + UUID().uuidString
    let store = RelayEnrollmentKeychain(service: service), invitation = try enrollmentInvite()
    defer { try? store.remove(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone) }
    _ = try store.prepare(invitation, now: enrollmentNow)
    let scope = [enrollmentOrigin.absoluteString, "qa", invitation.keyID, "phone"].joined(separator: "\n")
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data(scope.utf8)))), kSecAttrSynchronizable as String: false]
    let corrupted = Data("{\"version\":0}".utf8)
    #expect(SecItemUpdate(query as CFDictionary, [kSecValueData as String: corrupted] as CFDictionary) == errSecSuccess)
    #expect(throws: (any Error).self) { try store.prepare(invitation, now: enrollmentNow) }
    #expect(throws: (any Error).self) { try store.load(baseURL: enrollmentOrigin, roomID: "qa", keyID: invitation.keyID, role: .phone) }
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
    #expect(result as? Data == corrupted)
}
#endif
