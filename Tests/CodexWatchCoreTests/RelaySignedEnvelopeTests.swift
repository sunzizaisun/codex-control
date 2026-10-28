import CryptoKit
import Foundation
import Testing
@testable import CodexWatchCore

private let signedNow = Date(timeIntervalSince1970: 1_800_000_000)
private let signedRoom = "qa-signed-room"
private func signedFixtureKey() throws -> RelayDeviceSigningKey {
    try .init(rawRepresentation: Data([0x9d,0x61,0xb1,0x9d,0xef,0xfd,0x5a,0x60,0xba,0x84,0x4a,0xf4,0x92,0xec,0x2c,0xc4,
        0x44,0x49,0xc5,0x69,0x7b,0x32,0x69,0x19,0x70,0x3b,0xac,0x03,0x1c,0xae,0x7f,0x60]))
}
private func signedCredentials() throws -> RelayCredentials {
    try .init(authToken: Data(repeating: 17, count: 32).base64EncodedString(), encryptionKey: Data(repeating: 29, count: 32))
}
private func signedIdentity(role: RelayDeviceRole = .phone, key: RelayDeviceSigningKey? = nil,
                            expiresAt: Date = signedNow.addingTimeInterval(3600), revokedAt: Date? = nil) throws -> RelayPeerIdentity {
    try .init(roomID: signedRoom, keyID: signedCredentials().keyID, deviceID: "qa-" + role.rawValue,
        role: role, publicKey: (key ?? signedFixtureKey()).publicKey, expiresAt: expiresAt, revokedAt: revokedAt)
}
private func originalEnvelope(sender: String = "qa-phone") -> BridgeEnvelope {
    .init(messageID: "qa-message-original", sentAt: signedNow, kind: .hello, senderDeviceID: sender,
        message: "中文 水獭-627🦦 / e\u{301}\n\"原文\" \\ end")
}
private func verifySigned(_ signed: RelaySignedEnvelope, identity: RelayPeerIdentity? = nil,
                          destination: RelaySignedDestination = .mac, now: Date = signedNow) throws -> VerifiedRelayEnvelope {
    try signed.verify(sender: identity ?? signedIdentity(), roomID: signedRoom, keyID: signedCredentials().keyID,
        destination: destination, now: now)
}
private func signOriginal() throws -> RelaySignedEnvelope {
    try .sign(originalEnvelope(), identity: signedIdentity(), key: signedFixtureKey(), destination: .mac, now: signedNow)
}
private func mutateSigned(_ signed: RelaySignedEnvelope, header changeHeader: ((inout [String: Any]) -> Void)? = nil,
                          payload changePayload: ((inout [String: Any]) -> Void)? = nil,
                          rawPayload: ((Data) -> Data)? = nil) throws -> RelaySignedEnvelope {
    let parts = signed.compactJWS.split(separator: ".").map(String.init)
    var header = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(parts[0])!) as! [String: Any]
    var payload = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(parts[1], maximumEncodedBytes: RelaySignedEnvelope.maximumCompactBytes)!) as! [String: Any]
    changeHeader?(&header); changePayload?(&payload)
    let h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
    let p = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    let input = RelayDeviceEncoding.base64URL(h) + "." + RelayDeviceEncoding.base64URL(rawPayload?(p) ?? p)
    return try .init(compactJWS: input + "." + RelayDeviceEncoding.base64URL(signedFixtureKey().signature(for: Data(input.utf8))))
}

@Test func signedRelayPreservesExactOriginalUnicodeBytesIDAndFingerprint() throws {
    let original = originalEnvelope(), signed = try signOriginal(), result = try verifySigned(signed)
    let bytes = try CodexWatchCoding.makeEncoder().encode(original)
    #expect(result.envelope == original)
    #expect(result.originalBytes == bytes)
    #expect(result.originalSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    #expect(result.envelope.message == "中文 水獭-627🦦 / e\u{301}\n\"原文\" \\ end")
}

@Test func signedRelayRetryKeepsExactSignedOriginalButEncryptionNoncesAreFresh() throws {
    let signed = try signOriginal(), identity = try signedIdentity()
    let cipher = try RelaySignedPacketCipher(roomID: signedRoom, credentials: signedCredentials())
    let a = try cipher.seal(signed, sender: identity, destination: .mac, now: signedNow)
    let b = try cipher.seal(signed, sender: identity, destination: .mac, now: signedNow.addingTimeInterval(2))
    #expect(a.id == b.id); #expect(a.sentAt == b.sentAt); #expect(a.expiresAt == b.expiresAt)
    #expect(a.sealed != b.sealed)
    #expect(try cipher.open(a, sender: identity, destination: .mac, now: signedNow).originalBytes
        == cipher.open(b, sender: identity, destination: .mac, now: signedNow).originalBytes)
    let again = try signOriginal()
    #expect(again.compactJWS.split(separator: ".").prefix(2) == signed.compactJWS.split(separator: ".").prefix(2))
    #expect(try verifySigned(again).originalBytes == verifySigned(signed).originalBytes)
}

@Test func signedRelayRejectsContentTamperingBeforeReturningAnyEnvelope() throws {
    let signed = try signOriginal(), parts = signed.compactJWS.split(separator: ".").map(String.init)
    var payload = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(parts[1], maximumEncodedBytes: RelaySignedEnvelope.maximumCompactBytes)!) as! [String: Any]
    var changed = originalEnvelope(); changed.message = "not the original"
    payload["envelope"] = RelayDeviceEncoding.base64URL(try CodexWatchCoding.makeEncoder().encode(changed))
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    let tampered = try RelaySignedEnvelope(compactJWS: parts[0] + "." + RelayDeviceEncoding.base64URL(bytes) + "." + parts[2])
    #expect(throws: (any Error).self) { try verifySigned(tampered) }
}

@Test func signedRelayRejectsEveryChangedScopeIdentityIDAndDeadlineEvenIfResigned() throws {
    let signed = try signOriginal()
    for (field, value) in [("roomID", "other-room" as Any), ("keyID", String(repeating: "b", count: 32)),
        ("destination", "watch"), ("senderDeviceID", "another-device"), ("senderRole", "mac"),
        ("messageID", "different-message"), ("sentAt", Int64(1_800_000_000_001)),
        ("expiresAt", Int64(1_800_000_900_001)), ("version", 2)] {
        let altered = try mutateSigned(signed, payload: { $0[field] = value })
        #expect(throws: (any Error).self) { try verifySigned(altered) }
    }
}

@Test func signedRelayRejectsDPoPAndUnknownOrDuplicateHeaderAndPayloadMembers() throws {
    let signed = try signOriginal()
    for changed in [try mutateSigned(signed, header: { $0["typ"] = "dpop+jwt" }),
        try mutateSigned(signed, header: { $0["alg"] = "EdDSA" }),
        try mutateSigned(signed, header: { $0["jwk"] = ["d": "private"] }),
        try mutateSigned(signed, payload: { $0["unexpected"] = true }),
        try mutateSigned(signed, rawPayload: { Data(("{\"version\":1," + String(decoding: $0, as: UTF8.self).dropFirst()).utf8) })] {
        #expect(throws: (any Error).self) { try verifySigned(changed) }
    }
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/qa/mailbox/mac")!)
    request.httpMethod = "POST"
    let proof = try signedFixtureKey().proof(for: request, accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 1, count: 32)), now: signedNow)
    #expect(throws: (any Error).self) { try verifySigned(RelaySignedEnvelope(compactJWS: proof)) }
}

@Test func signedRelayRejectsUnenrolledKeyRevokedExpiredAndWrongScopePins() throws {
    let signed = try signOriginal()
    for identity in [try signedIdentity(key: .init()), try signedIdentity(expiresAt: signedNow),
        try signedIdentity(revokedAt: signedNow)] {
        #expect(throws: (any Error).self) { try verifySigned(signed, identity: identity) }
    }
    #expect(throws: (any Error).self) {
        try signed.verify(sender: signedIdentity(), roomID: "other-room", keyID: signedCredentials().keyID, destination: .mac, now: signedNow)
    }
    #expect(throws: (any Error).self) { try verifySigned(signed, destination: .phone) }
}

@Test func signedRelayCannotRenewExpiredOriginalOrStaleOriginalAction() throws {
    var original = originalEnvelope(); original.sentAt = signedNow.addingTimeInterval(-901)
    #expect(throws: (any Error).self) {
        try RelaySignedEnvelope.sign(original, identity: signedIdentity(), key: signedFixtureKey(), destination: .mac, now: signedNow)
    }
    let signed = try signOriginal()
    #expect(throws: (any Error).self) { try verifySigned(signed, now: signedNow.addingTimeInterval(900)) }
    original = originalEnvelope(); original.sentAt = signedNow.addingTimeInterval(61)
    #expect(throws: (any Error).self) {
        try RelaySignedEnvelope.sign(original, identity: signedIdentity(), key: signedFixtureKey(), destination: .mac, now: signedNow)
    }
    let action = TaskCommand(id: "qa-stale-action", taskID: "qa-task", prompt: "原始动作不能续期", sentAt: signedNow.addingTimeInterval(-86_401), deviceID: "qa-phone")
    let renewedWrapper = BridgeEnvelope(messageID: "qa-fresh-wrapper", sentAt: signedNow, kind: .taskCommand,
        senderDeviceID: "qa-phone", taskCommand: action)
    #expect(throws: (any Error).self) {
        try RelaySignedEnvelope.sign(renewedWrapper, identity: signedIdentity(), key: signedFixtureKey(), destination: .mac, now: signedNow)
    }
}

@Test func signedRelayRoutesByPinnedRoleAndNeverSelfReportedRole() throws {
    for role in RelayDeviceRole.allCases {
        let identity = try signedIdentity(role: role), envelope = originalEnvelope(sender: identity.deviceID)
        for destination in [RelaySignedDestination.mac, .phone, .watch, .snapshot] {
            if role == .mac ? destination != .mac : destination == .mac {
                let signed = try RelaySignedEnvelope.sign(envelope, identity: identity, key: signedFixtureKey(), destination: destination, now: signedNow)
                #expect(try signed.verify(sender: identity, roomID: signedRoom, keyID: signedCredentials().keyID, destination: destination, now: signedNow).envelope == envelope)
            } else {
                #expect(throws: (any Error).self) {
                    try RelaySignedEnvelope.sign(envelope, identity: identity, key: signedFixtureKey(), destination: destination, now: signedNow)
                }
            }
        }
    }
}

@Test func signedRelayRoomKeyHolderCannotForgeAnotherPinnedDevice() throws {
    let attackerKey = RelayDeviceSigningKey(), attacker = try signedIdentity(key: attackerKey), identity = try signedIdentity()
    let cipher = try RelaySignedPacketCipher(roomID: signedRoom, credentials: signedCredentials())
    let forged = try RelaySignedEnvelope.sign(originalEnvelope(), identity: attacker, key: attackerKey, destination: .mac, now: signedNow)
    let packet = try cipher.seal(forged, sender: attacker, destination: .mac, now: signedNow)
    #expect(throws: (any Error).self) { try cipher.open(packet, sender: identity, destination: .mac, now: signedNow) }
}

@Test func signedRelayCodecRejectsLegacyUnsignedWrongKeyAndOuterMetadataChanges() throws {
    let credentials = try signedCredentials(), cipher = RelaySignedPacketCipher(roomID: signedRoom, credentials: credentials)
    let signed = try signOriginal(), identity = try signedIdentity()
    let packet = try cipher.seal(signed, sender: identity, destination: .mac, now: signedNow)
    let legacy = try RelayPacketCipher(roomID: signedRoom, credentials: credentials).seal(originalEnvelope(), destination: "mac")
    #expect(throws: (any Error).self) { try cipher.open(legacy, sender: identity, destination: .mac, now: signedNow) }
    let wrongCredentials = try RelayCredentials(authToken: Data(repeating: 20, count: 32).base64EncodedString(), encryptionKey: Data(repeating: 21, count: 32))
    #expect(throws: (any Error).self) { try RelaySignedPacketCipher(roomID: signedRoom, credentials: wrongCredentials).open(packet, sender: identity, destination: .mac, now: signedNow) }
    for change in 0..<5 {
        var changed = packet
        switch change { case 0: changed.id = "different-id"; case 1: changed.expiresAt += 1
        case 2: changed.sentAt += 1; case 3: changed.destination = "watch"; default: changed.version = 2 }
        #expect(throws: (any Error).self) { try cipher.open(changed, sender: identity, destination: .mac, now: signedNow) }
    }
    // Even a room-key holder re-encrypting under a new outer AAD cannot alter
    // the signed inner deadline by the old v2 codec's 1ms compatibility fuzz.
    var rebound = packet; rebound.expiresAt += 1
    let aad = Data(["codex-control/relay/signed", "3", rebound.keyID, signedRoom, rebound.destination,
                    rebound.id, String(rebound.sentAt), String(rebound.expiresAt)].joined(separator: "\n").utf8)
    rebound.sealed = try AES.GCM.seal(Data(signed.compactJWS.utf8), using: SymmetricKey(data: credentials.encryptionKey), authenticating: aad).combined!.base64EncodedString()
    #expect(throws: (any Error).self) { try cipher.open(rebound, sender: identity, destination: .mac, now: signedNow) }
    let unsigned = try AES.GCM.seal(CodexWatchCoding.makeEncoder().encode(originalEnvelope()), using: SymmetricKey(data: credentials.encryptionKey), authenticating: aad)
    rebound.sealed = unsigned.combined!.base64EncodedString()
    #expect(throws: (any Error).self) { try cipher.open(rebound, sender: identity, destination: .mac, now: signedNow) }
}

@Test func signedRelayBoundsLargeMessageBeforeNetworkAndFitsTheExistingRelayPacketBudget() throws {
    var envelope = originalEnvelope(); envelope.message = String(repeating: "a", count: 740_000)
    let identity = try signedIdentity(), signed = try RelaySignedEnvelope.sign(envelope, identity: identity, key: signedFixtureKey(), destination: .mac, now: signedNow)
    let cipher = try RelaySignedPacketCipher(roomID: signedRoom, credentials: signedCredentials())
    let packet = try cipher.seal(signed, sender: identity, destination: .mac, now: signedNow)
    #expect(packet.sealed.utf8.count < 1_900_000)
    #expect(try cipher.open(packet, sender: identity, destination: .mac, now: signedNow).envelope.message == envelope.message)
    envelope.message = String(repeating: "a", count: RelaySignedEnvelope.maximumEnvelopeBytes)
    #expect(throws: (any Error).self) { try RelaySignedEnvelope.sign(envelope, identity: identity, key: signedFixtureKey(), destination: .mac, now: signedNow) }
    #expect(throws: (any Error).self) { try RelaySignedEnvelope(compactJWS: String(repeating: "a", count: RelaySignedEnvelope.maximumCompactBytes + 1)) }
}

@Test func signedRelayExportsOnlyExplicitSyntheticInteropFixture() throws {
    guard let output = ProcessInfo.processInfo.environment["CODEX_SIGNED_ENVELOPE_QA_OUTPUT"] else { return }
    guard output.hasPrefix("/private/tmp/relay-signed-interop."), URL(fileURLWithPath: output).lastPathComponent == "swift-envelope.json" else {
        Issue.record("Export only to explicit synthetic temporary fixture path"); return
    }
    let key = try signedFixtureKey(), identity = try signedIdentity(), signed = try signOriginal(), result = try verifySigned(signed)
    let fixture: [String: Any] = ["synthetic": true, "now": Int64(signedNow.timeIntervalSince1970 * 1000),
        "identity": ["roomID": identity.roomID, "keyID": identity.keyID, "deviceID": identity.deviceID, "role": identity.role.rawValue,
            "expiresAt": Int64(identity.expiresAt.timeIntervalSince1970 * 1000), "jwk": ["kty": "OKP", "crv": "Ed25519", "x": key.publicKey.x]],
        "destination": "mac", "compactJWS": signed.compactJWS, "originalBase64URL": RelayDeviceEncoding.base64URL(result.originalBytes),
        "originalSHA256": result.originalSHA256]
    try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: output), options: .atomic)
}

@Test func signedRelayAcceptsIndependentNodeEncodedBytesWithoutChangingTheirOrderOrText() throws {
    guard let input = ProcessInfo.processInfo.environment["CODEX_SIGNED_ENVELOPE_NODE_QA_INPUT"] else { return }
    guard input.hasPrefix("/private/tmp/relay-signed-interop."), URL(fileURLWithPath: input).lastPathComponent == "node-envelope.json" else {
        Issue.record("Read only the explicit synthetic Node fixture"); return
    }
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [String: Any]
    #expect(fixture["synthetic"] as? Bool == true)
    let result = try verifySigned(RelaySignedEnvelope(compactJWS: fixture["compactJWS"] as! String))
    #expect(result.envelope.messageID == "qa-node-original")
    #expect(result.envelope.message == "Node→Swift：松果-819🐿️\nnext")
    #expect(RelayDeviceEncoding.base64URL(result.originalBytes) == fixture["originalBase64URL"] as? String)
    #expect(result.originalSHA256 == fixture["originalSHA256"] as? String)
}
