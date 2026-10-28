import CryptoKit
import Foundation
import Testing
@testable import CodexWatchCore

private let syntheticDeviceToken = RelayDeviceEncoding.base64URL(Data(repeating: 93, count: 32))
private func deviceQAKey() throws -> RelayDeviceSigningKey {
    // RFC 8032 test seed, public fixture material, never a production key.
    try .init(rawRepresentation: Data([0x9d,0x61,0xb1,0x9d,0xef,0xfd,0x5a,0x60,0xba,0x84,0x4a,0xf4,0x92,0xec,0x2c,0xc4,
        0x44,0x49,0xc5,0x69,0x7b,0x32,0x69,0x19,0x70,0x3b,0xac,0x03,0x1c,0xae,0x7f,0x60]))
}

@Test func deviceProofUsesAnIndependentEd25519KeyAndCanonicalPublicThumbprint() throws {
    let key = try deviceQAKey()
    #expect(key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    #expect(key.publicKey.thumbprint != RelayDeviceSigningKey.accessTokenHash(syntheticDeviceToken))
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key.publicKey)) as! [String: String]
    #expect(Set(json.keys) == ["kty", "crv", "x"])
    #expect(try JSONDecoder().decode(RelayDevicePublicKey.self, from: JSONEncoder().encode(key.publicKey)) == key.publicKey)
}

@Test func deviceProofJWTContainsTheActualTargetTokenHashNonceAndNoPrivateMaterial() throws {
    let key = try deviceQAKey(), now = Date(timeIntervalSince1970: 1_800_000_000)
    var request = URLRequest(url: URL(string: "https://Relay.Example:443/v3/rooms/qa/mailbox/mac?ignored=1#fragment")!)
    request.httpMethod = "POST"
    let id = UUID(uuidString: "129CDDCB-E568-4F32-B906-93B5631D82C7")!
    let proof = try key.proof(for: request, accessToken: syntheticDeviceToken, nonce: "test-nonce-123", now: now, requestID: id)
    let segments = proof.split(separator: ".").map(String.init)
    #expect(segments.count == 3)
    let header = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(segments[0])!) as! [String: Any]
    let claims = try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(segments[1])!) as! [String: Any]
    #expect(header["alg"] as? String == "Ed25519")
    #expect(header["typ"] as? String == "dpop+jwt")
    #expect(Set((header["jwk"] as! [String: Any]).keys) == ["kty", "crv", "x"])
    #expect(claims["htu"] as? String == "https://relay.example/v3/rooms/qa/mailbox/mac")
    #expect(claims["htm"] as? String == "POST")
    #expect(claims["iat"] as? Int64 == 1_800_000_000)
    #expect(claims["jti"] as? String == id.uuidString)
    #expect(claims["nonce"] as? String == "test-nonce-123")
    #expect(claims["ath"] as? String == RelayDeviceSigningKey.accessTokenHash(syntheticDeviceToken))
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    #expect(verifier.isValidSignature(RelayDeviceEncoding.decodeBase64URL(segments[2])!, for: Data((segments[0] + "." + segments[1]).utf8)))
    #expect(!verifier.isValidSignature(RelayDeviceEncoding.decodeBase64URL(segments[2])!, for: Data((segments[0] + ".altered").utf8)))
}

@Test func deviceProofFreshRequestsHaveDistinctReplayIdentifiersEvenForTheSamePacket() throws {
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/qa/mailbox/mac")!)
    request.httpMethod = "POST"
    let key = try deviceQAKey()
    #expect(try key.proof(for: request, accessToken: syntheticDeviceToken)
        != key.proof(for: request, accessToken: syntheticDeviceToken))
}

@Test func deviceProofBindsExactUTF8BodyIncludingWhitespaceAndEmojiInPrivateProfile() throws {
    let key = try deviceQAKey()
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/qa/devices/enroll")!)
    request.httpMethod = "POST"
    let claim = "urn:codex-control:relay:v3:body-sha256"
    func claims(_ request: URLRequest) throws -> [String: Any] {
        let proof = try key.proof(for: request, accessToken: syntheticDeviceToken)
        let payload = String(proof.split(separator: ".")[1])
        return try JSONSerialization.jsonObject(with: RelayDeviceEncoding.decodeBase64URL(payload)!) as! [String: Any]
    }
    #expect(try claims(request)[claim] == nil)
    request.httpBody = Data("{\"message\":\"中文🍁e\u{301}\"}\n".utf8)
    let first = try claims(request)[claim] as? String
    #expect(first == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: request.httpBody!))))
    request.httpBody!.append(0x20)
    #expect(try claims(request)[claim] as? String != first)
    request.httpBody = Data()
    #expect(try claims(request)[claim] as? String == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data()))))
}

@Test func deviceProofRejectsBodyStreamsRatherThanSigningUnsentOrConsumedBytes() throws {
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/qa/devices/enroll")!)
    request.httpMethod = "POST"
    request.httpBodyStream = InputStream(data: Data("not-buffered".utf8))
    let key = try deviceQAKey()
    #expect(throws: (any Error).self) { try key.proof(for: request, accessToken: syntheticDeviceToken) }
}

@Test func deviceProofRejectsInsecureTargetsUserInfoWrongTokenAndMalformedPublicKeys() throws {
    let key = try deviceQAKey()
    for raw in ["http://relay.example/", "https://user:pass@relay.example/"] {
        #expect(throws: (any Error).self) { try key.proof(for: .init(url: URL(string: raw)!), accessToken: syntheticDeviceToken) }
    }
    let request = URLRequest(url: URL(string: "https://relay.example/")!)
    for token in ["", "room-bootstrap-secret", syntheticDeviceToken + "=", "密钥"] {
        #expect(throws: (any Error).self) { try key.proof(for: request, accessToken: token) }
    }
    for json in ["{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"bad\"}",
        "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"\(key.publicKey.x)\",\"d\":\"private\"}",
        "{\"kty\":\"EC\",\"crv\":\"Ed25519\",\"x\":\"\(key.publicKey.x)\"}"] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RelayDevicePublicKey.self, from: Data(json.utf8)) }
    }
    #expect(try RelayDeviceSigningKey.targetURI(URL(string: "https://EXAMPLE.com:443?x=1#y")!) == "https://example.com/")
}

@Test func deviceProofExportsOnlySyntheticInteropMaterialWhenExplicitlyRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["CODEX_DEVICE_PROOF_QA_OUTPUT"] else { return }
    guard path.hasPrefix("/private/tmp/device-proof-interop."), URL(fileURLWithPath: path).lastPathComponent == "swift-vector.json" else {
        Issue.record("Interop export is restricted to the explicit synthetic temporary directory"); return
    }
    let key = try deviceQAKey(), now = Date(timeIntervalSince1970: 1_800_000_000)
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/qa/mailbox/mac?ignored=1")!)
    request.httpMethod = "POST"
    let proof = try key.proof(for: request, accessToken: syntheticDeviceToken, nonce: "test-nonce-123", now: now,
        requestID: UUID(uuidString: "129CDDCB-E568-4F32-B906-93B5631D82C7")!)
    let result: [String: Any] = ["synthetic": true, "jwk": ["kty": "OKP", "crv": "Ed25519", "x": key.publicKey.x],
        "thumbprint": key.publicKey.thumbprint, "accessToken": syntheticDeviceToken, "proof": proof,
        "url": request.url!.absoluteString, "method": "POST", "now": now.timeIntervalSince1970, "nonce": "test-nonce-123"]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
}

#if os(iOS)
@Test func deviceIdentityKeychainKeepsRoomAndRoleKeysSeparateAndDoesNotResetOnReload() throws {
    let store = RelayDeviceIdentityKeychain(service: "com.sunzizai.codexwatch.qa.identity." + UUID().uuidString)
    defer { for role in RelayDeviceRole.allCases { try? store.remove(roomID: "synthetic-room", role: role) } }
    let phone = try store.loadOrCreate(roomID: "synthetic-room", role: .phone)
    let watch = try store.loadOrCreate(roomID: "synthetic-room", role: .watch)
    #expect(phone.publicKey != watch.publicKey)
    #expect(try store.loadOrCreate(roomID: "synthetic-room", role: .phone).publicKey == phone.publicKey)
    #expect(try store.load(roomID: "different-room", role: .phone) == nil)
    try store.remove(roomID: "synthetic-room", role: .phone)
    #expect(try store.load(roomID: "synthetic-room", role: .phone) == nil)
    #expect(try store.load(roomID: "synthetic-room", role: .watch)?.publicKey == watch.publicKey)
}
#endif
