import CryptoKit
import Foundation
import Testing
@testable import CodexWatchCore

private struct DeviceFixture {
    let phoneKey = RelayDeviceSigningKey(), macKey = RelayDeviceSigningKey()
    let aes = Data(repeating: 83, count: 32)
    let token = RelayDeviceEncoding.base64URL(Data(repeating: 91, count: 32))
    let directory: URL
    let phone: RelayPeerIdentity
    let mac: RelayPeerIdentity
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-v3-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let epoch = SHA256.hash(data: aes).prefix(16).map { String(format: "%02x", $0) }.joined()
        let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
        phone = try .init(roomID: "native-qa", keyID: epoch, deviceID: "qa-phone", role: .phone,
            publicKey: phoneKey.publicKey, expiresAt: expiry)
        mac = try .init(roomID: "native-qa", keyID: epoch, deviceID: "qa-mac", role: .mac,
            publicKey: macKey.publicKey, expiresAt: expiry)
    }
    var configuration: RelayDeviceConfiguration {
        get throws { try .init(baseURL: URL(string: "https://relay.example")!, identity: phone, owner: mac,
            signingKey: phoneKey, accessToken: token, encryptionKey: aes, preparedPacketsURL: directory.appendingPathComponent("sealed.plist")) }
    }
    var macConfiguration: RelayDeviceConfiguration {
        get throws { try .init(baseURL: URL(string: "https://relay.example")!, identity: mac, owner: mac,
            signingKey: macKey, accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 97, count: 32)),
            encryptionKey: aes, preparedPacketsURL: directory.appendingPathComponent("mac-sealed.plist")) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    var envelope: BridgeEnvelope { .init(messageID: "native-original", sentAt: Date(), kind: .hello,
        senderDeviceID: phone.deviceID, message: "水獭-627🦦 e\u{301} / 中文\n原文") }
    func incoming(_ id: String = "incoming") throws -> RelaySealedPacket {
        let envelope = BridgeEnvelope(messageID: id, kind: .hello, senderDeviceID: mac.deviceID, message: "真实密码学，但不是dot回复 🍁")
        let signed = try RelaySignedEnvelope.sign(envelope, identity: mac, key: macKey, destination: .phone)
        return try RelaySignedPacketCipher(roomID: mac.roomID, encryptionKey: aes, keyID: mac.keyID)
            .seal(signed, sender: mac, destination: .phone)
    }
}

private actor DeviceHTTPFixture {
    enum Mode { case normal, rotateWriteNonce, failWrite, rejectWrite500, cancelWrite, wrongReceipt, wrongOrigin, missingCapability, repeatNonce, wrongOwner, stalePeers, revokedOwner, unknownGrant, paged, loopingCursor }
    let fixture: DeviceFixture
    let mode: Mode
    let principal: RelayPeerIdentity
    let accessToken: String
    var requests: [URLRequest] = []
    var incoming: [RelaySealedPacket] = []
    var nonce = RelayDeviceEncoding.base64URL(Data(repeating: 13, count: 32))
    var rotated = false
    var proofIDs: Set<String> = []
    init(_ fixture: DeviceFixture, mode: Mode = .normal, incoming: [RelaySealedPacket] = [], asMac: Bool = false) {
        self.fixture = fixture; self.mode = mode; self.incoming = incoming
        principal = asMac ? fixture.mac : fixture.phone
        accessToken = asMac ? RelayDeviceEncoding.base64URL(Data(repeating: 97, count: 32)) : fixture.token
    }
    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url), method = request.httpMethod ?? "GET"
        #expect(url.path.hasPrefix("/v3/rooms/native-qa/"))
        #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + accessToken)
        #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == fixture.phone.keyID)
        let proof = try #require(request.value(forHTTPHeaderField: "DPoP"))
        let parts = proof.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let bytes = try #require(RelayDeviceEncoding.decodeBase64URL(parts[1]))
        let claims = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(claims["htm"] as? String == method)
        #expect(claims["htu"] as? String == (try RelayDeviceSigningKey.targetURI(url)))
        #expect(claims["ath"] as? String == RelayDeviceSigningKey.accessTokenHash(accessToken))
        let jti = try #require(claims["jti"] as? String)
        #expect(proofIDs.insert(jti).inserted)
        let signature = try #require(RelayDeviceEncoding.decodeBase64URL(parts[2]))
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: principal.publicKey.rawRepresentation)
            .isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        if let body = request.httpBody {
            #expect(claims["urn:codex-control:relay:v3:body-sha256"] as? String == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: body))))
        } else { #expect(claims["urn:codex-control:relay:v3:body-sha256"] == nil) }
        if mode == .wrongOrigin { return response(request, ["error": "use_dpop_nonce"], status: 401, wrongURL: true) }
        if mode == .repeatNonce || claims["nonce"] as? String != nonce { return challenge(request) }
        if method == "POST" && mode == .rotateWriteNonce && !rotated {
            rotated = true; nonce = RelayDeviceEncoding.base64URL(Data(repeating: 14, count: 32)); return challenge(request)
        }
        if url.path.hasSuffix("devices/me") { return response(request, ["authorized": true, "grant": grant(principal)]) }
        if url.path.hasSuffix("devices/peers") {
            var owner = grant(fixture.mac)
            if mode == .wrongOwner { owner["jwk"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RelayDeviceSigningKey().publicKey)) }
            if mode == .revokedOwner { owner["revokedAt"] = now() - 1 }
            if mode == .unknownGrant { owner["tokenHash"] = "must-not-be-returned" }
            return response(request, ["peers": [grant(fixture.phone), owner], "capturedAt": now() - (mode == .stalePeers ? 180_000 : 0)])
        }
        if method == "POST" || method == "PUT" {
            if mode == .failWrite { throw URLError(.networkConnectionLost) }
            if mode == .cancelWrite { throw CancellationError() }
            if mode == .rejectWrite500 { return response(request, ["error": "device_relay_unavailable"], status: 503) }
            let packet = try CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: #require(request.httpBody))
            let values: [Any] = [packet.version, packet.keyID, packet.destination, packet.id, packet.sentAt, packet.expiresAt, packet.sealed]
            let digest = RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]))))
            if method == "PUT" { incoming = [packet]; return response(request, ["stored": true, "id": packet.id, "packetDigest": digest]) }
            return response(request, ["stored": true, "duplicate": false, "id": packet.id,
                "packetDigest": mode == .wrongReceipt ? "bad" : digest, "delivery": "queued"])
        }
        if method == "DELETE" { return response(request, nil, status: 204) }
        if url.path.hasSuffix("snapshot"), let packet = incoming.first {
            return response(request, try JSONSerialization.jsonObject(with: CodexWatchCoding.makeEncoder().encode(packet)))
        }
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        let packets = mode == .paged ? (cursor == nil ? Array(incoming.prefix(1)) : Array(incoming.dropFirst())) : incoming
        let packetObjects = try packets.map { try JSONSerialization.jsonObject(with: CodexWatchCoding.makeEncoder().encode($0)) }
        let next: Any = mode == .loopingCursor || (mode == .paged && cursor == nil) ? "0000000000000001" : NSNull()
        return response(request, ["packets": packetObjects, "rejected": [], "nextCursor": next, "capturedAt": now()])
    }
    func snapshot() -> [URLRequest] { requests }
    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func grant(_ identity: RelayPeerIdentity) -> [String: Any] {
        ["roomID": identity.roomID, "keyID": identity.keyID, "deviceID": identity.deviceID, "role": identity.role.rawValue,
         "jwk": ["kty": "OKP", "crv": "Ed25519", "x": identity.publicKey.x],
         "expiresAt": Int64(identity.expiresAt.timeIntervalSince1970 * 1000)]
    }
    private func challenge(_ request: URLRequest) -> (Data, URLResponse) {
        response(request, ["error": "use_dpop_nonce"], status: 401,
            headers: ["DPoP-Nonce": nonce, "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""])
    }
    private func response(_ request: URLRequest, _ body: Any?, status: Int = 200,
                          headers: [String: String] = [:], wrongURL: Bool = false) -> (Data, URLResponse) {
        var headers = headers
        if mode != .missingCapability { headers["X-Codex-Relay-Device-Protocol"] = "3" }
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) } ?? Data()
        return (data, HTTPURLResponse(url: wrongURL ? URL(string: "https://evil.example/")! : request.url!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

@Test func nativeDeviceTransportSignsBodiesAndRetriesOnlyExplicitNonceWithExactPacket() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture, mode: .rotateWriteNonce)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    let original = try CodexWatchCoding.makeEncoder().encode(fixture.envelope)
    try await client.enqueue(originalEnvelopeData: original, to: .mac)
    let requests = await server.snapshot(), writes = requests.filter { $0.httpMethod == "POST" }
    #expect(requests.count == 4); #expect(writes.count == 2)
    #expect(writes[0].httpBody == writes[1].httpBody)
    #expect(writes[0].value(forHTTPHeaderField: "DPoP") != writes[1].value(forHTTPHeaderField: "DPoP"))
    let packet = try CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: #require(writes.first?.httpBody))
    let opened = try RelaySignedPacketCipher(roomID: fixture.phone.roomID, encryptionKey: fixture.aes, keyID: fixture.phone.keyID)
        .open(packet, sender: fixture.phone, destination: .mac)
    #expect(opened.originalBytes == original)
    let restarted = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    try await restarted.enqueue(originalEnvelopeData: original, to: .mac)
    #expect(await server.snapshot().count == requests.count)
}

@Test func nativeDeviceTransportLostWriteResponseDoesNotRepostAcrossClientRestart() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture, mode: .failWrite), bytes = try CodexWatchCoding.makeEncoder().encode(fixture.envelope)
    for _ in 0..<3 {
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: RelayDeviceTransportError.self) { try await client.enqueue(originalEnvelopeData: bytes, to: .mac) }
    }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func nativeDeviceTransportRejectsMalformedAcceptanceWithoutAutomaticRetry() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture, mode: .wrongReceipt)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    let envelope = fixture.envelope
    await #expect(throws: RelayDeviceTransportError.self) { try await client.enqueue(envelope, to: .mac) }
    await #expect(throws: RelayDeviceTransportError.self) { try await client.enqueue(envelope, to: .mac) }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func nativeDeviceTransportRejectsChangedOriginalWithSameIDAndNeverRewritesJournal() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    var envelope = fixture.envelope
    try await client.enqueue(envelope, to: .mac)
    let before = try Data(contentsOf: fixture.configuration.journal.fileURL)
    envelope.message = "not the original"
    await #expect(throws: RelayDeviceTransportError.self) { try await client.enqueue(envelope, to: .mac) }
    #expect(try Data(contentsOf: fixture.configuration.journal.fileURL) == before)
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func nativeDeviceTransportNoDowngradeOnOriginOrCapabilityOrRepeatedChallenge() async throws {
    for mode in [DeviceHTTPFixture.Mode.wrongOrigin, .missingCapability, .repeatNonce] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        let server = DeviceHTTPFixture(fixture, mode: mode)
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: (any Error).self) { try await client.enqueue(fixture.envelope, to: .mac) }
        let requests = await server.snapshot()
        #expect(requests.count <= 2); #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url!.path.contains("/v3/") })
    }
}

@Test func nativeDeviceTransportCorruptJournalVetoesNetworkWithoutReset() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let url = try fixture.configuration.journal.fileURL, bad = Data("corrupt original".utf8)
    try bad.write(to: url)
    let server = DeviceHTTPFixture(fixture)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { try await client.enqueue(fixture.envelope, to: .mac) }
    #expect(await server.snapshot().isEmpty); #expect(try Data(contentsOf: url) == bad)
}

@Test func nativeDeviceTransportRequiresSignatureAndFreshPinnedOwnerBeforeAck() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let packet = try fixture.incoming(), server = DeviceHTTPFixture(fixture, incoming: [packet])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: RelayDeviceTransportError.self) { try await client.acknowledge(packet.id, in: .phone) }
    #expect(await server.snapshot().isEmpty)
    let envelopes = try await client.messages(for: .phone)
    #expect(envelopes.count == 1); #expect(envelopes[0].message == "真实密码学，但不是dot回复 🍁")
    try await client.acknowledge(packet.id, in: .phone)
    #expect(await server.snapshot().filter { $0.httpMethod == "DELETE" }.count == 1)
    await #expect(throws: RelayDeviceTransportError.self) { try await client.acknowledge(packet.id, in: .phone) }
}

@Test func nativeDeviceTransportWrongOrStalePeerRegistryCannotAuthenticateMailbox() async throws {
    for mode in [DeviceHTTPFixture.Mode.wrongOwner, .stalePeers] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        let server = try DeviceHTTPFixture(fixture, mode: mode, incoming: [fixture.incoming()])
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: (any Error).self) { _ = try await client.messages(for: .phone) }
        #expect(await server.snapshot().allSatisfy { !$0.url!.path.contains("mailbox/") })
    }
}

@Test func nativeDeviceTransportRejectsWrongMailboxAndSenderBeforeNetwork() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { _ = try await client.messages(for: .mac) }
    await #expect(throws: (any Error).self) { try await client.enqueue(fixture.envelope, to: .phone) }
    var other = fixture.envelope; other.senderDeviceID = "wrong-device"
    await #expect(throws: (any Error).self) { try await client.enqueue(other, to: .mac) }
    #expect(await server.snapshot().isEmpty)
}

@Test func signedRelayFrozenNoncanonicalJSONIsNotReserialized() throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let envelope = fixture.envelope
    let object = try JSONSerialization.jsonObject(with: CodexWatchCoding.makeEncoder().encode(envelope))
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    let signed = try RelaySignedEnvelope.sign(originalBytes: bytes, identity: fixture.phone, key: fixture.phoneKey, destination: .mac)
    #expect(try signed.verify(sender: fixture.phone, roomID: fixture.phone.roomID, keyID: fixture.phone.keyID, destination: .mac).originalBytes == bytes)
}

@Test func nativeDeviceTransportServerFailureAndCancellationNeverAuthorizeRepost() async throws {
    for mode in [DeviceHTTPFixture.Mode.rejectWrite500, .cancelWrite] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        let server = DeviceHTTPFixture(fixture, mode: mode)
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        let bytes = try CodexWatchCoding.makeEncoder().encode(fixture.envelope)
        for _ in 0..<3 {
            await #expect(throws: RelayDeviceTransportError.self) { try await client.enqueue(originalEnvelopeData: bytes, to: .mac) }
        }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
    }
}

@Test func nativeDeviceTransportJournalWriteFailureAndSymlinkVetoNetwork() async throws {
    for symlink in [false, true] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("protected.txt"), original = Data("do not replace".utf8)
        try original.write(to: target)
        let path = try fixture.configuration.journal.fileURL
        if symlink { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
        else { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let server = DeviceHTTPFixture(fixture)
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: (any Error).self) { try await client.enqueue(fixture.envelope, to: .mac) }
        #expect(await server.snapshot().isEmpty)
        #expect(try Data(contentsOf: target) == original)
    }
}

@Test func nativeDeviceTransportScopeChangeNeverReusesOrResetsPreviousJournal() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    try await client.enqueue(fixture.envelope, to: .mac)
    let file = try fixture.configuration.journal.fileURL, before = try Data(contentsOf: file)
    let changedID = try RelayPeerIdentity(roomID: fixture.phone.roomID, keyID: fixture.phone.keyID, deviceID: "other-phone",
        role: .phone, publicKey: fixture.phoneKey.publicKey, expiresAt: fixture.phone.expiresAt)
    let changed = try RelayDeviceConfiguration(baseURL: URL(string: "https://relay.example")!, identity: changedID,
        owner: fixture.mac, signingKey: fixture.phoneKey, accessToken: fixture.token, encryptionKey: fixture.aes, preparedPacketsURL: file)
    let count = await server.snapshot().count
    let other = RemoteRelayClient(deviceConfiguration: changed, requestTransport: { try await server.handle($0) })
    var envelope = fixture.envelope; envelope.senderDeviceID = changedID.deviceID
    await #expect(throws: (any Error).self) { try await other.enqueue(envelope, to: .mac) }
    #expect(try Data(contentsOf: file) == before); #expect(await server.snapshot().count == count)
}

@Test func nativeDeviceTransportExpiredOriginalCannotBeFreshlyWrapped() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    var envelope = fixture.envelope; envelope.sentAt = Date().addingTimeInterval(-3600)
    await #expect(throws: (any Error).self) { try await client.enqueue(envelope, to: .mac) }
    #expect(await server.snapshot().isEmpty)
}

@Test func nativeDeviceTransportEncryptedButUnpinnedSenderCannotReceiveAck() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let impostorKey = RelayDeviceSigningKey()
    let impostor = try RelayPeerIdentity(roomID: fixture.mac.roomID, keyID: fixture.mac.keyID, deviceID: fixture.mac.deviceID,
        role: .mac, publicKey: impostorKey.publicKey, expiresAt: fixture.mac.expiresAt)
    let envelope = BridgeEnvelope(kind: .hello, senderDeviceID: impostor.deviceID)
    let signed = try RelaySignedEnvelope.sign(envelope, identity: impostor, key: impostorKey, destination: .phone)
    let packet = try RelaySignedPacketCipher(roomID: impostor.roomID, encryptionKey: fixture.aes, keyID: impostor.keyID)
        .seal(signed, sender: impostor, destination: .phone)
    let server = DeviceHTTPFixture(fixture, incoming: [packet])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { _ = try await client.messages(for: .phone) }
    await #expect(throws: (any Error).self) { try await client.acknowledge(packet.id, in: .phone) }
    #expect(await server.snapshot().allSatisfy { $0.httpMethod != "DELETE" })
}

@Test func nativeDeviceTransportDuplicatePageIDsAndTamperedOuterMetadataCannotBeAcked() async throws {
    for duplicate in [false, true] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        var packet = try fixture.incoming()
        if !duplicate { packet.sentAt += 1 }
        let server = DeviceHTTPFixture(fixture, incoming: duplicate ? [packet, packet] : [packet])
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: (any Error).self) { _ = try await client.messages(for: .phone) }
        await #expect(throws: (any Error).self) { try await client.acknowledge(packet.id, in: .phone) }
    }
}

@Test func nativeDeviceTransportConcurrentClientsShareOneDurableWriteAdmission() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture), bytes = try CodexWatchCoding.makeEncoder().encode(fixture.envelope)
    let config = try fixture.configuration
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let client = RemoteRelayClient(deviceConfiguration: config, requestTransport: { try await server.handle($0) })
                do { try await client.enqueue(originalEnvelopeData: bytes, to: .mac) }
                catch { #expect(error is RelayDeviceTransportError) }
            }
        }
    }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@Test func nativeDeviceTransportRevokedOwnerOrPrivateGrantFieldsFailClosed() async throws {
    for mode in [DeviceHTTPFixture.Mode.revokedOwner, .unknownGrant] {
        let fixture = try DeviceFixture(); defer { fixture.cleanup() }
        let server = try DeviceHTTPFixture(fixture, mode: mode, incoming: [fixture.incoming()])
        let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
        await #expect(throws: (any Error).self) { _ = try await client.messages(for: .phone) }
        #expect(await server.snapshot().allSatisfy { !$0.url!.path.contains("mailbox/") })
    }
}

@Test func nativeDeviceTransportReadsAllPagesAndProofURIExcludesCursor() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = try DeviceHTTPFixture(fixture, mode: .paged, incoming: [fixture.incoming("one"), fixture.incoming("two")])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    let messages = try await client.messages(for: .phone)
    #expect(messages.map(\.messageID) == ["one", "two"])
    let reads = await server.snapshot().filter { $0.url!.path.contains("mailbox/") }
    #expect(reads.count == 2); #expect(reads.last?.url?.query == "cursor=0000000000000001")
}

@Test func nativeDeviceTransportRejectsNonadvancingCursorWithoutAckOrInfiniteLoop() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture, mode: .loopingCursor)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { _ = try await client.messages(for: .phone) }
    #expect(await server.snapshot().filter { $0.url!.path.contains("mailbox/") }.count == 2)
}

@Test func nativeDeviceTransportOldSnapshotCannotClaimCurrentMacState() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    var envelope = BridgeEnvelope.snapshot(.empty, sender: fixture.mac.deviceID)
    envelope.sentAt = Date().addingTimeInterval(-301)
    let signed = try RelaySignedEnvelope.sign(envelope, identity: fixture.mac, key: fixture.macKey, destination: .snapshot)
    let packet = try RelaySignedPacketCipher(roomID: fixture.mac.roomID, encryptionKey: fixture.aes, keyID: fixture.mac.keyID)
        .seal(signed, sender: fixture.mac, destination: .snapshot)
    let server = DeviceHTTPFixture(fixture, incoming: [packet])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { _ = try await client.latestSnapshot() }
}

@Test func nativeDevicePreparedJournalIsBoundedCannotResetAttemptedAndKeepsOnlyCiphertext() throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let store = try fixture.configuration.journal, now = Date()
    for index in 0..<64 {
        let record = RelayPreparedPacketStore.Record(id: "id-\(index)", destination: .mac,
            originalSHA256: String(repeating: "a", count: 64), body: Data("ciphertext".utf8),
            expiresAt: now.addingTimeInterval(index == 0 ? -1 : 900), state: .prepared)
        _ = try store.insert(record, now: now.addingTimeInterval(-2))
    }
    let full = RelayPreparedPacketStore.Record(id: "full", destination: .mac, originalSHA256: String(repeating: "b", count: 64),
        body: Data("sealed only".utf8), expiresAt: now.addingTimeInterval(900), state: .prepared)
    #expect(throws: (any Error).self) { try store.insert(full, now: now.addingTimeInterval(-2)) }
    _ = try store.insert(full, now: now) // Only the definitely expired row is reclaimed.
    #expect(try store.record(id: "id-0", destination: .mac) == nil)
    _ = try store.transition(id: full.id, destination: .mac, from: .prepared, to: .attempted)
    #expect(throws: (any Error).self) { try store.transition(id: full.id, destination: .mac, from: .attempted, to: .prepared) }
    #expect(try store.record(id: full.id, destination: .mac)?.state == .attempted)
    let bytes = try Data(contentsOf: store.fileURL)
    #expect(bytes.range(of: fixture.token.data(using: .utf8)!) == nil)
    #expect(bytes.range(of: fixture.aes) == nil)
}

@Test func nativeDeviceConfigurationRejectsAliasedSecretsAndOwnerKeys() throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let aliasKey = try RelayDeviceSigningKey(rawRepresentation: fixture.aes)
    let aliasIdentity = try RelayPeerIdentity(roomID: fixture.phone.roomID, keyID: fixture.phone.keyID,
        deviceID: fixture.phone.deviceID, role: .phone, publicKey: aliasKey.publicKey, expiresAt: fixture.phone.expiresAt)
    #expect(throws: (any Error).self) {
        try RelayDeviceConfiguration(baseURL: URL(string: "https://relay.example")!, identity: aliasIdentity, owner: fixture.mac,
            signingKey: aliasKey, accessToken: fixture.token, encryptionKey: fixture.aes,
            preparedPacketsURL: fixture.directory.appendingPathComponent("alias.plist"))
    }
    #expect(throws: (any Error).self) {
        try RelayDeviceConfiguration(baseURL: URL(string: "https://relay.example")!, identity: fixture.phone, owner: fixture.mac,
            signingKey: fixture.phoneKey, accessToken: RelayDeviceEncoding.base64URL(fixture.phoneKey.storageRepresentation),
            encryptionKey: fixture.aes, preparedPacketsURL: fixture.directory.appendingPathComponent("alias-token.plist"))
    }
    let aliasOwner = try RelayPeerIdentity(roomID: fixture.mac.roomID, keyID: fixture.mac.keyID,
        deviceID: fixture.mac.deviceID, role: .mac, publicKey: fixture.phone.publicKey, expiresAt: fixture.mac.expiresAt)
    #expect(throws: (any Error).self) {
        try RelayDeviceConfiguration(baseURL: URL(string: "https://relay.example")!, identity: fixture.phone, owner: aliasOwner,
            signingKey: fixture.phoneKey, accessToken: fixture.token, encryptionKey: fixture.aes,
            preparedPacketsURL: fixture.directory.appendingPathComponent("alias-owner.plist"))
    }
}

@Test func nativeDeviceTransportFreshWrapperCannotHideStaleSnapshotContent() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let snapshot = DashboardSnapshot(bridgeConnected: true, capturedAt: Date().addingTimeInterval(-3600))
    let envelope = BridgeEnvelope.snapshot(snapshot, sender: fixture.mac.deviceID)
    let signed = try RelaySignedEnvelope.sign(envelope, identity: fixture.mac, key: fixture.macKey, destination: .snapshot)
    let packet = try RelaySignedPacketCipher(roomID: fixture.mac.roomID, encryptionKey: fixture.aes, keyID: fixture.mac.keyID)
        .seal(signed, sender: fixture.mac, destination: .snapshot)
    let server = DeviceHTTPFixture(fixture, incoming: [packet])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { _ = try await client.latestSnapshot() }
}

@Test func nativeDeviceTransportFreshSnapshotPreservesAuthoritativeOfflineState() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let snapshot = DashboardSnapshot(bridgeConnected: false, capturedAt: Date())
    let envelope = BridgeEnvelope.snapshot(snapshot, sender: fixture.mac.deviceID)
    let signed = try RelaySignedEnvelope.sign(envelope, identity: fixture.mac, key: fixture.macKey, destination: .snapshot)
    let packet = try RelaySignedPacketCipher(roomID: fixture.mac.roomID, encryptionKey: fixture.aes, keyID: fixture.mac.keyID)
        .seal(signed, sender: fixture.mac, destination: .snapshot)
    let server = DeviceHTTPFixture(fixture, incoming: [packet])
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    let result = try await client.latestSnapshot()
    #expect(result?.snapshot?.bridgeConnected == false)
    #expect(result?.messageID == envelope.messageID)
}

@Test func nativeDeviceConfigurationDebugOutputNeverContainsCredentials() throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let value = String(reflecting: try fixture.configuration)
    #expect(value.contains("<redacted>"))
    #expect(!value.contains(fixture.token))
    #expect(!value.contains(fixture.aes.base64EncodedString()))
    #expect(!value.contains(RelayDeviceEncoding.base64URL(fixture.phoneKey.storageRepresentation)))
}

@Test func nativeDeviceTransportCannotQueueToRevokedOwnerEvenIfOwnGrantIsValid() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let server = DeviceHTTPFixture(fixture, mode: .revokedOwner)
    let client = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { try await client.enqueue(fixture.envelope, to: .mac) }
    #expect(await server.snapshot().allSatisfy { $0.httpMethod == "GET" })
}

@Test func nativeDeviceTransportMacToPhoneSnapshotRoundTripUsesIndependentIdentities() async throws {
    let fixture = try DeviceFixture(); defer { fixture.cleanup() }
    let macServer = DeviceHTTPFixture(fixture, asMac: true)
    let mac = try RemoteRelayClient(deviceConfiguration: fixture.macConfiguration, requestTransport: { try await macServer.handle($0) })
    let snapshot = DashboardSnapshot(bridgeConnected: true, capturedAt: Date())
    try await mac.uploadSnapshot(snapshot, sender: fixture.mac.deviceID)
    let request = try #require(await macServer.snapshot().first { $0.httpMethod == "PUT" })
    let packet = try CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: #require(request.httpBody))
    let phoneServer = DeviceHTTPFixture(fixture, incoming: [packet])
    let phone = try RemoteRelayClient(deviceConfiguration: fixture.configuration, requestTransport: { try await phoneServer.handle($0) })
    let received = try await phone.latestSnapshot()
    #expect(received?.snapshot?.bridgeConnected == true)
    #expect(received?.senderDeviceID == fixture.mac.deviceID)
    #expect(abs((received?.snapshot?.capturedAt ?? .distantPast).timeIntervalSince(snapshot.capturedAt)) < 0.001)
    #expect(request.value(forHTTPHeaderField: "Authorization") != "DPoP " + fixture.token)
}
