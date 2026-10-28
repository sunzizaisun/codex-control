import CryptoKit
import Foundation
import Security
import Testing
@testable import CodexWatchCore

private enum PairingQAFailure: Error { case storage }
final class PairingQAClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

@available(macOS 14.0, *)
struct PairingQAFixture: Sendable {
    let clock: PairingQAClock
    let aes = Data(repeating: 79, count: 32)
    let ownerKey = RelayDeviceSigningKey()
    let secure: RelaySecurePairingInvitation
    let offer: RelaySecurePairingOffer
    let serverResponse: Data
    let pending: RelaySecurePairingPending
    let device: RelayKeyDeliveryDevice
    let directory: URL
    init(role: RelayDeviceRole = .phone) throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        clock = PairingQAClock(now)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let enrollment = try RelayEnrollmentOffer(baseURL: URL(string: "https://relay.example")!, roomID: "pairing-qa",
            keyID: RelayKeyDeliveryDevice.keyID(aes), role: role, grantExpiresAt: Int64(now.timeIntervalSince1970 * 1000) + 3_600_000,
            ownerID: "qa-owner", ownerKey: ownerKey, now: now)
        offer = try .init(enrollment: enrollment)
        serverResponse = try JSONSerialization.data(withJSONObject: ["authorized": true, "invitation": [
            "invitationID": enrollment.invitationID, "role": role.rawValue,
            "nonce": RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32)), "expiresAt": enrollment.expiresAt,
            "grantExpiresAt": enrollment.grantExpiresAt, "ownerID": enrollment.ownerID,
            "ownerThumbprint": ownerKey.publicKey.thumbprint, "consumed": false]])
        secure = try offer.invitation(from: serverResponse, now: now)
        let intent = try RelayEnrollmentIntent(invitation: secure.enrollment, signingKey: RelayDeviceSigningKey(),
            accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 91, count: 32)), deviceID: "qa-" + role.rawValue)
        device = try .init(invitation: secure, intent: intent, exchangeKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        pending = .init(intent: intent, keyRequest: try device.makeRequest(now: now))
    }
    func peer(_ pending: RelaySecurePairingPending) throws -> RelayPeerIdentity {
        let intent = pending.intent
        return try .init(roomID: intent.invitation.roomID, keyID: intent.invitation.keyID, deviceID: intent.deviceID,
            role: intent.invitation.role, publicKey: intent.signingKey.publicKey,
            expiresAt: Date(timeIntervalSince1970: Double(intent.invitation.grantExpiresAt) / 1000))
    }
    func owner() throws -> RelayPeerIdentity {
        let base = secure.enrollment
        return try .init(roomID: base.roomID, keyID: base.keyID, deviceID: base.ownerID, role: .mac,
            publicKey: ownerKey.publicKey, expiresAt: Date(timeIntervalSince1970: Double(base.grantExpiresAt + 3_600_000) / 1000))
    }
    func response(to pending: RelaySecurePairingPending) throws -> RelayKeyDeliveryPacket {
        try RelayKeyDeliveryOwner(invitation: secure, exchangeKey: offer.exchangeKey.rawRepresentation)
            .makeResponse(pending.keyRequest, peer: peer(pending), encryptionKey: aes, now: clock.now())
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func client(_ store: any RelayPairingPersistence, server: PairingQAServer) -> RelayPairingCoordinator {
        let base = secure.enrollment
        let http = RelayDeviceHTTPClient(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID,
            requestTimeout: 2, waitsForConnectivity: false, requestTransport: { try await server.handle($0) }, clock: { clock.now() })
        return .init(store: store, http: http, clock: { clock.now() })
    }
}

/// Memory seam for cross-platform state-machine tests, NOT persistent-storage
/// proof. Separate iOS tests below use the real isolated Keychain adapter.
@available(macOS 14.0, *)
final class PairingQAMemory: RelayPairingPersistence, @unchecked Sendable {
    let fixture: PairingQAFixture
    private let lock = NSLock()
    private var enrolledAttempted = false, keyAttempted = false
    private var encryption: Data?
    private var claimFailure: RelayPairingAttempt?
    private var finishFailure = false
    init(_ fixture: PairingQAFixture) { self.fixture = fixture }
    func state() throws -> RelayPairingStoredState {
        lock.lock(); defer { lock.unlock() }
        return .init(pending: fixture.pending, enrollmentAttempted: enrolledAttempted, keyRequestAttempted: keyAttempted, keyReady: encryption != nil)
    }
    func claim(_ phase: RelayPairingAttempt, pending: RelaySecurePairingPending) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimFailure == phase { throw PairingQAFailure.storage }
        guard pending.keyRequest == fixture.pending.keyRequest else { throw RelayKeyDeliveryError.identityConflict }
        switch phase {
        case .enrollment: guard !enrolledAttempted else { return false }; enrolledAttempted = true
        case .keyRequest: guard !keyAttempted else { return false }; keyAttempted = true
        }
        return true
    }
    func finish(_ response: RelayKeyDeliveryPacket, now: Date) throws {
        let key = try fixture.device.openResponse(response, request: fixture.pending.keyRequest, now: now)
        lock.lock(); defer { lock.unlock() }
        if finishFailure { throw PairingQAFailure.storage }; encryption = key
    }
    func configuration(ownGrant: Data, owner: RelayPeerIdentity, now: Date) throws -> RelayDeviceConfiguration {
        lock.lock(); let key = encryption; lock.unlock()
        guard let key else { throw RelayKeyDeliveryError.notReady }
        let intent = fixture.pending.intent
        return try .init(baseURL: intent.invitation.baseURL, identity: intent.validateGrant(ownGrant, now: now), owner: owner,
            signingKey: intent.signingKey, accessToken: intent.accessToken, encryptionKey: key,
            preparedPacketsURL: fixture.directory.appendingPathComponent("packets.plist"))
    }
    func failClaim(_ phase: RelayPairingAttempt?) { lock.lock(); defer { lock.unlock() }; claimFailure = phase }
    func failFinish(_ value: Bool) { lock.lock(); defer { lock.unlock() }; finishFailure = value }
}

@available(macOS 14.0, *)
actor PairingQAServer {
    enum Mode: Equatable { case normal, delayedOwner, lostEnrollmentACK, rejectedEnrollment, malformedEnrollment,
        lostKeyACK, absentAfterLostKey, malformedKeyReceipt, wrongOwner, stalePeers, badResponse, queryFailure,
        externalOwner, ownerLostACK, ownerRejected, ownerMalformedReceipt, ownerRotatedNonce, ownerCancelled,
        ownerMissingAfterLostACK, staleKeyRequests, malformedKeyRequests, duplicateKeyRequests, wrongRecipientKey,
        ownerExpiresDuringChallenge }
    let fixture: PairingQAFixture
    let pending: RelaySecurePairingPending
    let mode: Mode
    private var registered = false
    private var keyBytes: Data?
    private var responseBytes: Data?
    private var requests: [URLRequest] = []
    private var proofIDs: Set<String> = []
    private var nonce = RelayDeviceEncoding.base64URL(Data(repeating: 31, count: 32))
    private var ownerNonceRotated = false
    private var automaticReplies = 0
    private var ownerResponsesStored = 0
    private var receiverKeyChanged = false
    private var conflictingOwnerResponse = false
    private var externalOwner: Bool { [Mode.externalOwner, .ownerLostACK, .ownerRejected, .ownerMalformedReceipt,
        .ownerRotatedNonce, .ownerCancelled, .ownerMissingAfterLostACK, .staleKeyRequests,
        .malformedKeyRequests, .duplicateKeyRequests, .wrongRecipientKey, .ownerExpiresDuringChallenge].contains(mode) }
    private let ownerToken = RelayDeviceEncoding.base64URL(Data(repeating: 97, count: 32))
    init(_ fixture: PairingQAFixture, mode: Mode = .normal, pending: RelaySecurePairingPending? = nil) {
        self.fixture = fixture; self.mode = mode; self.pending = pending ?? fixture.pending
    }
    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let intent = pending.intent, url = try #require(request.url), enrolling = url.path.hasSuffix("devices/enroll")
        let isOwner = !enrolling && request.value(forHTTPHeaderField: "Authorization") == "DPoP " + ownerToken
        let token = enrolling ? intent.invitation.secret : isOwner ? ownerToken : intent.accessToken
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP " + token)
        #expect(request.value(forHTTPHeaderField: "X-Codex-Relay-Key-ID") == intent.invitation.keyID)
        let compact = try #require(request.value(forHTTPHeaderField: "DPoP")), pieces = compact.split(separator: ".").map(String.init)
        #expect(pieces.count == 3)
        let claimBytes = try #require(RelayDeviceEncoding.decodeBase64URL(pieces[1]))
        let claims = try #require(JSONSerialization.jsonObject(with: claimBytes) as? [String: Any])
        #expect(claims["htm"] as? String == request.httpMethod)
        #expect(claims["htu"] as? String == (try RelayDeviceSigningKey.targetURI(url)))
        #expect(claims["ath"] as? String == RelayDeviceSigningKey.accessTokenHash(token))
        let signature = try #require(RelayDeviceEncoding.decodeBase64URL(pieces[2])), proofID = try #require(claims["jti"] as? String)
        #expect(proofIDs.insert(proofID).inserted)
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: isOwner ? fixture.ownerKey.publicKey.rawRepresentation : intent.signingKey.publicKey.rawRepresentation)
            .isValidSignature(signature, for: Data((pieces[0] + "." + pieces[1]).utf8)))
        if let body = request.httpBody {
            #expect(claims["urn:codex-control:relay:v3:body-sha256"] as? String == RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: body))))
        }
        if enrolling {
            #expect(claims["nonce"] as? String == intent.invitation.nonce)
            if mode == .rejectedEnrollment { return json(request, ["error": "unavailable"], status: 503) }
            registered = true
            if mode == .lostEnrollmentACK { throw URLError(.networkConnectionLost) }
            var grant = grant(try fixture.peer(pending))
            if mode == .malformedEnrollment { grant["deviceID"] = "not-our-device" }
            return json(request, ["enrolled": true, "alreadyEnrolled": false, "grant": grant])
        }
        guard registered || isOwner else { return json(request, ["error": "invalid_dpop_proof"], status: 401) }
        if claims["nonce"] as? String != nonce {
            return json(request, ["error": "use_dpop_nonce"], status: 401,
                headers: ["DPoP-Nonce": nonce, "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""])
        }
        if url.path.hasSuffix("devices/me") { return json(request, ["authorized": true, "grant": grant(try isOwner ? fixture.owner() : fixture.peer(pending))]) }
        if url.path.hasSuffix("devices/peers") {
            var owner = grant(try fixture.owner())
            if mode == .wrongOwner { owner["jwk"] = ["kty": "OKP", "crv": "Ed25519", "x": RelayDeviceSigningKey().publicKey.x] }
            var recipients = registered ? [grant(try fixture.peer(pending))] : []
            if mode == .wrongRecipientKey || receiverKeyChanged, !recipients.isEmpty {
                recipients[0]["jwk"] = ["kty": "OKP", "crv": "Ed25519", "x": RelayDeviceSigningKey().publicKey.x]
            }
            return json(request, ["peers": recipients + [owner],
                "capturedAt": Int64(fixture.clock.now().timeIntervalSince1970 * 1000) - (mode == .stalePeers ? 181_000 : 0)])
        }
        if url.path.hasSuffix("devices/key-requests") {
            #expect(isOwner)
            let items: [[String: String]] = responseBytes == nil && keyBytes != nil ? [["packet": RelayDeviceEncoding.base64URL(keyBytes!)]] : []
            if mode == .malformedKeyRequests { return json(request, ["requests": [["packet": "bad", "unknown": "field"]], "capturedAt": Int64(fixture.clock.now().timeIntervalSince1970 * 1000)]) }
            return json(request, ["requests": mode == .duplicateKeyRequests ? items + items : items,
                "capturedAt": Int64(fixture.clock.now().timeIntervalSince1970 * 1000) - (mode == .staleKeyRequests ? 181_000 : 0)])
        }
        if url.path.contains("/devices/key-responses/") {
            #expect(isOwner)
            if request.httpMethod == "GET" {
                if mode == .ownerMissingAfterLostACK { return raw(request, nil) }
                if conflictingOwnerResponse, let bytes = responseBytes {
                    var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    value["sealed"] = RelayDeviceEncoding.base64URL(Data(repeating: 8, count: 64))
                    return raw(request, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
                }
                return raw(request, responseBytes)
            }
            if (mode == .ownerRotatedNonce || mode == .ownerExpiresDuringChallenge) && !ownerNonceRotated {
                ownerNonceRotated = true; nonce = RelayDeviceEncoding.base64URL(Data(repeating: 32, count: 32))
                if mode == .ownerExpiresDuringChallenge {
                    fixture.clock.advance(Double(pending.keyRequest.expiresAt) / 1000 - fixture.clock.now().timeIntervalSince1970)
                }
                return json(request, ["error": "use_dpop_nonce"], status: 401,
                    headers: ["DPoP-Nonce": nonce, "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""])
            }
            if mode == .ownerRejected { return json(request, ["error": "unavailable"], status: 503) }
            let bytes = try #require(request.httpBody), packet = try RelayKeyDeliveryPacket.parse(bytes)
            #expect(packet.phase == "response"); #expect(packet.requestDigest == (try pending.keyRequest.digest))
            #expect(responseBytes == nil || responseBytes == bytes); responseBytes = bytes; ownerResponsesStored += 1
            if mode == .ownerLostACK || mode == .ownerMissingAfterLostACK { throw URLError(.networkConnectionLost) }
            if mode == .ownerCancelled { throw CancellationError() }
            return json(request, ["stored": true, "duplicate": false, "requestID": packet.requestID,
                "digest": mode == .ownerMalformedReceipt ? "wrong" : try packet.digest])
        }
        if url.path.hasSuffix("key-request") {
            if request.httpMethod == "GET" {
                if mode == .queryFailure { return json(request, ["error": "unavailable"], status: 503) }
                return raw(request, mode == .absentAfterLostKey ? nil : keyBytes)
            }
            let bytes = try #require(request.httpBody)
            #expect(bytes == (try pending.keyRequest.encodedData))
            #expect(keyBytes == nil || keyBytes == bytes); keyBytes = bytes
            if mode != .delayedOwner && !externalOwner { try completeOwner() }
            if mode == .lostKeyACK || mode == .absentAfterLostKey { throw URLError(.networkConnectionLost) }
            return json(request, ["stored": true, "duplicate": false, "requestID": pending.keyRequest.requestID,
                "digest": mode == .malformedKeyReceipt ? "wrong" : try pending.keyRequest.digest])
        }
        #expect(url.path.hasSuffix("room-key"))
        if mode == .badResponse, let responseBytes {
            var object = try JSONSerialization.jsonObject(with: responseBytes) as! [String: Any]
            object["sealed"] = RelayDeviceEncoding.base64URL(Data(repeating: 8, count: 64))
            return raw(request, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        return raw(request, responseBytes)
    }
    func completeOwner() throws { if responseBytes == nil { responseBytes = try fixture.response(to: pending).encodedData; automaticReplies += 1 } }
    func snapshot() -> [URLRequest] { requests }
    func automaticReplyCount() -> Int { automaticReplies }
    func storedOwnerResponseCount() -> Int { ownerResponsesStored }
    func changeRecipientKey() { receiverKeyChanged = true }
    func conflictResponse() { conflictingOwnerResponse = true }
    private func grant(_ peer: RelayPeerIdentity) -> [String: Any] {
        ["roomID": peer.roomID, "keyID": peer.keyID, "deviceID": peer.deviceID, "role": peer.role.rawValue,
         "jwk": ["kty": "OKP", "crv": "Ed25519", "x": peer.publicKey.x], "expiresAt": Int64(peer.expiresAt.timeIntervalSince1970 * 1000)]
    }
    private func json(_ request: URLRequest, _ body: [String: Any], status: Int = 200, headers: [String: String] = [:]) -> (Data, URLResponse) {
        let bytes = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return raw(request, bytes, status: status, headers: headers)
    }
    private func raw(_ request: URLRequest, _ bytes: Data?, status: Int? = nil, headers: [String: String] = [:]) -> (Data, URLResponse) {
        var headers = headers; headers["X-Codex-Relay-Device-Protocol"] = "3"
        return (bytes ?? Data(), HTTPURLResponse(url: request.url!, statusCode: status ?? (bytes == nil ? 204 : 200),
            httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

private func expectReady(_ update: RelayPairingUpdate) throws -> RelayDeviceConfiguration {
    guard case .ready(let configuration) = update else { Issue.record("pairing did not become key-ready"); throw RelayKeyDeliveryError.notReady }
    return configuration
}

private actor PairingHTTPBoundary {
    enum Mode { case nonce, wrongOrigin, wrongQuery, missingProtocol, oversized, dirty204, unavailable }
    let mode: Mode
    private var requests: [URLRequest] = []
    init(_ mode: Mode = .nonce) { self.mode = mode }
    func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let proof = try #require(request.value(forHTTPHeaderField: "DPoP")), parts = proof.split(separator: ".").map(String.init)
        let headerBytes = try #require(RelayDeviceEncoding.decodeBase64URL(parts[0])), claimBytes = try #require(RelayDeviceEncoding.decodeBase64URL(parts[1]))
        let header = try #require(JSONSerialization.jsonObject(with: headerBytes) as? [String: Any])
        let claims = try #require(JSONSerialization.jsonObject(with: claimBytes) as? [String: Any])
        let jwk = try #require(header["jwk"] as? [String: String]), x = try #require(jwk["x"])
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let nonce = RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: Data((authorization + x).utf8))))
        var headers = ["X-Codex-Relay-Device-Protocol": "3"], status = 200, bytes = Data("{}".utf8), url = request.url!
        switch mode {
        case .nonce:
            if claims["nonce"] as? String != nonce {
                status = 401; bytes = Data("{\"error\":\"use_dpop_nonce\"}".utf8)
                headers["WWW-Authenticate"] = "DPoP error=\"use_dpop_nonce\""; headers["DPoP-Nonce"] = nonce
            }
        case .wrongOrigin: url = URL(string: "https://other.example/v3/rooms/pairing-qa/devices/me")!
        case .wrongQuery: var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.query = "injected=1"; url = parts.url!
        case .missingProtocol: headers.removeValue(forKey: "X-Codex-Relay-Device-Protocol")
        case .oversized: bytes = Data(repeating: 1, count: 2048)
        case .dirty204: status = 204
        case .unavailable: status = 503
        }
        return (bytes, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    func snapshot() -> [URLRequest] { requests }
}

@Test func sharedPairingHTTPRejectsUntrustedOriginsAndRoutesBeforeCredentialsLeave() async throws {
    let server = PairingHTTPBoundary(), http = RelayDeviceHTTPClient(baseURL: URL(string: "https://relay.example")!,
        roomID: "pairing-qa", keyID: String(repeating: "a", count: 32), requestTimeout: 2, waitsForConnectivity: false,
        requestTransport: { try await server.handle($0) })
    for url in ["https://other.example/v3/rooms/pairing-qa/devices/me", "http://relay.example/v3/rooms/pairing-qa/devices/me",
        "https://relay.example/v3/rooms/other/devices/me", "https://relay.example/v3/rooms/pairing-qa/devices/me#fragment",
        "https://relay.example/unrelated/v3/rooms/pairing-qa/devices/me",
        "https://relay.example/v3/rooms/pairing-qa/../other/devices/me",
        "https://relay.example/v3/rooms/pairing-qa/%2E%2E/other/devices/me",
        "https://relay.example/v3/rooms/pairing-qa/devices%2Fme"] {
        await #expect(throws: (any Error).self) { try await http.send(URLRequest(url: URL(string: url)!),
            signingKey: RelayDeviceSigningKey(), accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 7, count: 32)),
            expiresAt: Date().addingTimeInterval(3600)) }
    }
    #expect(await server.snapshot().isEmpty)
}

@Test func sharedPairingHTTPNonceCacheSeparatesKeyAndTokenAndFreezesExactBody() async throws {
    let server = PairingHTTPBoundary(), http = RelayDeviceHTTPClient(baseURL: URL(string: "https://relay.example")!,
        roomID: "pairing-qa", keyID: String(repeating: "a", count: 32), requestTimeout: 2, waitsForConnectivity: false,
        requestTransport: { try await server.handle($0) })
    let key = RelayDeviceSigningKey(), other = RelayDeviceSigningKey(), token = RelayDeviceEncoding.base64URL(Data(repeating: 8, count: 32))
    let otherToken = RelayDeviceEncoding.base64URL(Data(repeating: 9, count: 32)), body = Data(" { \"原文\":\"e\u{301}🦦\" }\n".utf8)
    var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/pairing-qa/devices/me")!)
    request.httpMethod = "POST"; request.httpBody = body
    for (signer, access) in [(key, token), (key, token), (other, token), (key, otherToken), (key, token)] {
        _ = try await http.send(request, signingKey: signer, accessToken: access, expiresAt: Date().addingTimeInterval(3600), maximumResponseBytes: 1024)
    }
    let requests = await server.snapshot()
    #expect(requests.count == 8); #expect(requests.allSatisfy { $0.httpBody == body })
    #expect(Set(requests.compactMap { $0.value(forHTTPHeaderField: "DPoP") }).count == requests.count)
}

@Test func sharedPairingHTTPFixedEnrollmentNonceCannotBeReplacedByAnHTTPChallenge() async throws {
    let server = PairingHTTPBoundary(), http = RelayDeviceHTTPClient(baseURL: URL(string: "https://relay.example")!,
        roomID: "pairing-qa", keyID: String(repeating: "a", count: 32), requestTimeout: 2, waitsForConnectivity: false,
        requestTransport: { try await server.handle($0) })
    await #expect(throws: (any Error).self) { try await http.send(URLRequest(url: URL(string: "https://relay.example/v3/rooms/pairing-qa/devices/enroll")!),
        signingKey: RelayDeviceSigningKey(), accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 8, count: 32)),
        expiresAt: Date().addingTimeInterval(3600), fixedNonce: RelayDeviceEncoding.base64URL(Data(repeating: 23, count: 32))) }
    #expect(await server.snapshot().count == 1)
}

@Test func sharedPairingHTTPBadResponseOrServerFailureCannotTriggerAnotherPOST() async throws {
    for mode in [PairingHTTPBoundary.Mode.wrongOrigin, .wrongQuery, .missingProtocol, .oversized, .dirty204, .unavailable] {
        let server = PairingHTTPBoundary(mode), http = RelayDeviceHTTPClient(baseURL: URL(string: "https://relay.example")!,
            roomID: "pairing-qa", keyID: String(repeating: "a", count: 32), requestTimeout: 2, waitsForConnectivity: false,
            requestTransport: { try await server.handle($0) })
        var request = URLRequest(url: URL(string: "https://relay.example/v3/rooms/pairing-qa/devices/me")!)
        request.httpMethod = "POST"; request.httpBody = Data("frozen".utf8)
        await #expect(throws: (any Error).self) { try await http.send(request, signingKey: RelayDeviceSigningKey(),
            accessToken: RelayDeviceEncoding.base64URL(Data(repeating: 8, count: 32)), expiresAt: Date().addingTimeInterval(3600), maximumResponseBytes: 1024) }
        #expect(await server.snapshot().count == 1)
    }
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorCompletesActualHPKEAndIndependentProofsForPhoneAndWatch() async throws {
    for role in [RelayDeviceRole.phone, .watch] {
        let f = try PairingQAFixture(role: role); defer { f.cleanup() }
        let store = PairingQAMemory(f), server = PairingQAServer(f)
        let config = try expectReady(await f.client(store, server: server).advance())
        #expect(config.encryptionKey == f.aes); #expect(config.identity == (try f.peer(f.pending)))
        let requests = await server.snapshot()
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(requests.filter { $0.url!.path.hasSuffix("devices/me") }.count == 2)
    }
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorWaitingOwnerUsesReadOnlyPollsAndRetainsTheSameKeys() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .delayedOwner)
    for _ in 0..<3 { guard case .awaitingOwner = try await f.client(store, server: server).advance() else { Issue.record("not waiting"); return } }
    try await server.completeOwner()
    #expect(try expectReady(await f.client(store, server: server).advance()).encryptionKey == f.aes)
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 2)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorLostEnrollmentReceiptRecoversWithoutAnotherRegistration() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .lostEnrollmentACK)
    guard case .enrollmentUnconfirmed = try await f.client(store, server: server).advance() else { Issue.record("not uncertain"); return }
    #expect(try expectReady(await f.client(store, server: server).advance()).identity == f.peer(f.pending))
    #expect(await server.snapshot().filter { $0.url!.path.hasSuffix("devices/enroll") }.count == 1)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorRejectedRegistrationNeverBlindlyRetriesEvenIfOwnGrantIsAbsent() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .rejectedEnrollment)
    guard case .enrollmentUnconfirmed = try await f.client(store, server: server).advance() else { Issue.record("not uncertain"); return }
    for _ in 0..<3 { await #expect(throws: (any Error).self) { try await f.client(store, server: server).advance() } }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorWrongEnrollmentReceiptCannotReportReadyButCanRecoverActualOwnGrant() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .malformedEnrollment)
    guard case .enrollmentUnconfirmed = try await f.client(store, server: server).advance() else { Issue.record("bad grant accepted"); return }
    _ = try expectReady(await f.client(store, server: server).advance())
    #expect(await server.snapshot().filter { $0.url!.path.hasSuffix("devices/enroll") }.count == 1)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorLostOrMalformedKeyReceiptRecoversExactCiphertextWithoutReupload() async throws {
    for mode in [PairingQAServer.Mode.lostKeyACK, .malformedKeyReceipt] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: mode)
        guard case .keyRequestUnconfirmed = try await f.client(store, server: server).advance() else { Issue.record("not uncertain"); return }
        _ = try expectReady(await f.client(store, server: server).advance())
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("key-request") }.count == 1)
    }
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorAbsentKeyAfterUnknownUploadDoesNotAuthorizeAnotherPOST() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .absentAfterLostKey)
    for _ in 0..<3 { guard case .keyRequestUnconfirmed = try await f.client(store, server: server).advance() else { Issue.record("uncertainty lost"); return } }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 2)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorQueryFailureCannotBecomeAKeyUpload() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .queryFailure)
    for _ in 0..<2 { await #expect(throws: (any Error).self) { try await f.client(store, server: server).advance() } }
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorWrongOrStaleOwnerRegistryVetoesKeyUpload() async throws {
    for mode in [PairingQAServer.Mode.wrongOwner, .stalePeers] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: mode)
        await #expect(throws: (any Error).self) { try await f.client(store, server: server).advance() }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 1)
        #expect(try !store.state().keyReady)
    }
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorBadHPKEResponseDoesNotBecomeReadyOrRegenerateARequest() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f, mode: .badResponse)
    for _ in 0..<2 { await #expect(throws: (any Error).self) { try await f.client(store, server: server).advance() } }
    #expect(try !store.state().keyReady); #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 2)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorFailedDurableClaimVetoesRegistrationAndKeyWrites() async throws {
    for phase in [RelayPairingAttempt.enrollment, .keyRequest] {
        let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f)
        store.failClaim(phase)
        await #expect(throws: PairingQAFailure.self) { try await f.client(store, server: server).advance() }
        #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == (phase == .enrollment ? 0 : 1))
    }
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorFailedKeySaveIsNotReadyAndRecoveryDoesNotRepost() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f)
    store.failFinish(true)
    await #expect(throws: PairingQAFailure.self) { try await f.client(store, server: server).advance() }
    #expect(try !store.state().keyReady); store.failFinish(false)
    _ = try expectReady(await f.client(store, server: server).advance())
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 2)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorReadyKeySurvivesPairingDeadlineWithoutRepeatingTheHandshake() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f)
    _ = try expectReady(await f.client(store, server: server).advance()); let before = await server.snapshot().count
    f.clock.advance(600)
    _ = try expectReady(await f.client(store, server: server).advance())
    let added = Array(await server.snapshot().dropFirst(before))
    #expect(added.allSatisfy { $0.httpMethod == "GET" && !$0.url!.path.hasSuffix("key-request") && !$0.url!.path.hasSuffix("room-key") })
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorExpiredInitialInviteMakesNoNetworkAttempt() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f)
    f.clock.advance(130)
    await #expect(throws: (any Error).self) { try await f.client(store, server: server).advance() }
    #expect(await server.snapshot().isEmpty); #expect(try !store.state().enrollmentAttempted)
}

@available(macOS 14.0, *)
@Test func pairingCoordinatorConcurrentInstancesCannotClaimTheSameWriteTwice() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let store = PairingQAMemory(f), server = PairingQAServer(f)
    await withTaskGroup(of: Void.self) { group in for _ in 0..<8 { group.addTask { _ = try? await f.client(store, server: server).advance() } } }
    _ = try expectReady(await f.client(store, server: server).advance())
    #expect(await server.snapshot().filter { $0.url!.path.hasSuffix("devices/enroll") }.count == 1)
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("key-request") }.count == 1)
}

#if os(iOS)
@Test func pairingCoordinatorRealKeychainCompletesAndReconstructedClientMakesNoPOST() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }
    let service = "qa.pairing-coordinator." + UUID().uuidString, keychain = RelayEnrollmentKeychain(service: service), base = f.secure.enrollment
    defer { try? keychain.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let pending = try keychain.prepareSecure(f.secure, deviceID: "qa-phone", now: f.clock.now())
    let server = PairingQAServer(f, mode: .lostKeyACK, pending: pending)
    func client() -> RelayPairingCoordinator { .init(keychain: RelayEnrollmentKeychain(service: service), baseURL: base.baseURL,
        roomID: base.roomID, keyID: base.keyID, role: base.role, preparedPacketsURL: f.directory.appendingPathComponent("sealed.plist"),
        requestTransport: { try await server.handle($0) }) }
    guard case .keyRequestUnconfirmed = try await client().advance() else { Issue.record("not uncertain"); return }
    let saved = try keychain.securePairingState(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role)
    #expect(saved.enrollmentAttempted && saved.keyRequestAttempted && !saved.keyReady)
    let config = try expectReady(await client().advance())
    #expect(config.encryptionKey == f.aes); #expect(config.identity.publicKey == pending.intent.signingKey.publicKey)
    _ = try expectReady(await client().advance())
    #expect(await server.snapshot().filter { $0.httpMethod == "POST" }.count == 2)
}

@Test func pairingCoordinatorRealKeychainClaimsAreMonotonicAndConcurrentOnlyOnce() async throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let base = f.secure.enrollment
    let keychain = RelayEnrollmentKeychain(service: "qa.pairing-claims." + UUID().uuidString)
    defer { try? keychain.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let pending = try keychain.prepareSecure(f.secure, now: f.clock.now())
    for phase in [RelayPairingAttempt.enrollment, .keyRequest] {
        let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { try keychain.claimSecureAttempt(phase, pending: pending) } }
            var results = [Bool](); for try await value in group { results.append(value) }; return results
        }
        #expect(claims.filter { $0 }.count == 1)
    }
    let saved = try keychain.securePairingState(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role)
    #expect(saved.enrollmentAttempted && saved.keyRequestAttempted && saved.pending.keyRequest == pending.keyRequest)
}

@Test func pairingCoordinatorOlderSecureBundleWithoutAttemptFlagsIsUncertainNotFresh() throws {
    let f = try PairingQAFixture(); defer { f.cleanup() }; let base = f.secure.enrollment
    let service = "qa.pairing-old." + UUID().uuidString, keychain = RelayEnrollmentKeychain(service: service)
    defer { try? keychain.remove(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role) }
    let pending = try keychain.prepareSecure(f.secure, now: f.clock.now())
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
    var selection = query; selection[kSecReturnData as String] = true; selection[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; #expect(SecItemCopyMatching(selection as CFDictionary, &result) == errSecSuccess)
    let bytes = try #require(result as? Data); var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    object.removeValue(forKey: "enrollmentAttempted"); object.removeValue(forKey: "keyRequestAttempted")
    let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(SecItemUpdate(query as CFDictionary, [kSecValueData as String: old] as CFDictionary) == errSecSuccess)
    let saved = try keychain.securePairingState(baseURL: base.baseURL, roomID: base.roomID, keyID: base.keyID, role: base.role)
    #expect(saved.enrollmentAttempted && saved.keyRequestAttempted)
    #expect(try !keychain.claimSecureAttempt(.enrollment, pending: pending)); #expect(try !keychain.claimSecureAttempt(.keyRequest, pending: pending))
}
#endif
