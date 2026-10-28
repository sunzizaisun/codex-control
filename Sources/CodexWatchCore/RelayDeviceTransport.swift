import CryptoKit
import Foundation

public enum RelayDeviceTransportError: LocalizedError {
    case deliveryUncertain, conflictingMessage, invalidPeer, unsafeResponse, unverifiedAcknowledgement
    public var errorDescription: String? {
        switch self {
        case .deliveryUncertain: CommandRecovery.unconfirmedText
        case .invalidPeer: RemoteRelayError.authenticationFailed.errorDescription
        case .conflictingMessage, .unsafeResponse, .unverifiedAcknowledgement: RemoteRelayError.invalidPacket.errorDescription
        }
    }
}

/// No bearer token is derived from the AES room key. The explicit public
/// owner pin comes from authenticated enrollment, not a downloaded message.
/// This initializer does not provision first-owner trust or deliver AES keys.
public struct RelayDeviceConfiguration: Sendable, CustomDebugStringConvertible {
    public let baseURL: URL
    public let identity: RelayPeerIdentity
    public let owner: RelayPeerIdentity
    let signingKey: RelayDeviceSigningKey
    let accessToken: String
    let encryptionKey: Data
    let journal: RelayPreparedPacketStore
    public init(baseURL: URL, identity: RelayPeerIdentity, owner: RelayPeerIdentity,
                signingKey: RelayDeviceSigningKey, accessToken: String, encryptionKey: Data,
                preparedPacketsURL: URL) throws {
        self.baseURL = try RelayEnrollmentInvitation.origin(baseURL)
        guard identity.publicKey == signingKey.publicKey, owner.role == .mac,
              owner.roomID == identity.roomID, owner.keyID == identity.keyID,
              identity.role != .mac || identity == owner,
              identity.role == .mac || identity.deviceID != owner.deviceID,
              identity.role == .mac || identity.publicKey != owner.publicKey,
              let tokenBytes = RelayDeviceEncoding.decodeBase64URL(accessToken), tokenBytes.count == 32,
              tokenBytes != encryptionKey, signingKey.storageRepresentation != encryptionKey,
              signingKey.storageRepresentation != tokenBytes,
              preparedPacketsURL.isFileURL else { throw RelayDeviceTransportError.invalidPeer }
        _ = try RelaySignedPacketCipher(roomID: identity.roomID, encryptionKey: encryptionKey, keyID: identity.keyID)
        self.identity = identity; self.owner = owner; self.signingKey = signingKey
        self.accessToken = accessToken; self.encryptionKey = encryptionKey
        let scope = [self.baseURL.absoluteString, identity.roomID, identity.keyID, identity.deviceID,
                     identity.role.rawValue, identity.publicKey.thumbprint,
                     owner.deviceID, owner.publicKey.thumbprint].joined(separator: "\n")
        journal = RelayPreparedPacketStore(fileURL: preparedPacketsURL, scope: scope)
    }
    public var debugDescription: String {
        "RelayDeviceConfiguration(role: \(identity.role.rawValue), credentials: <redacted>)"
    }
}

/// Selected by RemoteRelayClient's explicit v3 initializer. HTTPS mailbox
/// remains authoritative; connection hints never become execution receipts.
actor RelayDeviceTransport {
    private let configuration: RelayDeviceConfiguration
    private let cipher: RelaySignedPacketCipher
    private let http: RelayDeviceHTTPClient
    private var verifiedDeliveries: Set<String> = []
    init(configuration: RelayDeviceConfiguration, requestTimeout: TimeInterval,
         waitsForConnectivity: Bool, requestTransport: RemoteRelayClient.RequestTransport?) {
        self.configuration = configuration
        cipher = try! .init(roomID: configuration.identity.roomID, encryptionKey: configuration.encryptionKey,
                            keyID: configuration.identity.keyID)
        http = RelayDeviceHTTPClient(baseURL: configuration.baseURL, roomID: configuration.identity.roomID,
            keyID: configuration.identity.keyID, requestTimeout: requestTimeout,
            waitsForConnectivity: waitsForConnectivity, requestTransport: requestTransport)
    }
    private func endpoint(_ resource: String, cursor: String? = nil) -> URL {
        var url = configuration.baseURL.appendingPathComponent("v3/rooms/\(configuration.identity.roomID)/\(resource)")
        if let cursor {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "cursor", value: cursor)]; url = parts.url!
        }
        return url
    }
    private func request(_ resource: String, method: String = "GET", body: Data? = nil,
                         cursor: String? = nil) async throws -> Data {
        try configuration.identity.validate(now: Date())
        var request = URLRequest(url: endpoint(resource, cursor: cursor))
        request.httpMethod = method; request.httpBody = body
        return try await http.send(request, signingKey: configuration.signingKey, accessToken: configuration.accessToken,
            expiresAt: configuration.identity.expiresAt).data
    }
    private var registry: RelayDeviceRegistryClient {
        .init(baseURL: configuration.baseURL, identity: configuration.identity, signingKey: configuration.signingKey,
            accessToken: configuration.accessToken, http: http)
    }
    private func ownGrant() async throws { _ = try await registry.ownGrant() }
    private func peers() async throws -> [RelayPeerIdentity] {
        let active = try await registry.peers()
        guard active.contains(configuration.owner) else { throw RelayDeviceTransportError.invalidPeer }
        return configuration.identity.role == .mac ? active : [configuration.owner]
    }
    private func requireFresh(_ milliseconds: Int64) throws {
        let current = Date().timeIntervalSince1970 * 1000
        guard milliseconds >= 0, milliseconds <= 9_007_199_254_740_991,
              Double(milliseconds) <= current + 60_000, Double(milliseconds) >= current - 120_000 else {
            throw RelayDeviceTransportError.unsafeResponse
        }
    }
    func enqueue(originalBytes: Data, to mailbox: RemoteRelayMailbox) async throws {
        guard let destination = RelaySignedDestination(rawValue: mailbox.rawValue), destination != .snapshot,
              RelaySignedEnvelope.allows(configuration.identity.role, destination) else { throw RemoteRelayError.invalidPacket }
        let signed = try RelaySignedEnvelope.sign(originalBytes: originalBytes, identity: configuration.identity,
            key: configuration.signingKey, destination: destination)
        let original = try signed.verify(sender: configuration.identity, roomID: configuration.identity.roomID,
            keyID: configuration.identity.keyID, destination: destination)
        let candidate: RelayPreparedPacketStore.Record
        if let saved = try configuration.journal.record(id: original.envelope.messageID, destination: destination) { candidate = saved }
        else {
            let packet = try cipher.seal(signed, sender: configuration.identity, destination: destination)
            candidate = .init(id: packet.id, destination: destination, originalSHA256: original.originalSHA256,
                body: try CodexWatchCoding.makeEncoder().encode(packet), expiresAt: original.envelope.deliveryExpiresAt, state: .prepared)
        }
        let record = try configuration.journal.insert(candidate, now: Date())
        guard record.originalSHA256 == original.originalSHA256 else { throw RelayDeviceTransportError.conflictingMessage }
        let packet = try CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: record.body)
        let restored = try cipher.open(packet, sender: configuration.identity, destination: destination)
        guard restored.originalBytes == originalBytes else { throw RelayDeviceTransportError.conflictingMessage }
        switch record.state {
        case .accepted: return // Relay acceptance only; owner ACK is separate.
        case .attempted: throw RelayDeviceTransportError.deliveryUncertain
        case .prepared: break
        }
        // A valid sender grant does not imply that the pinned owner is still
        // active. Refresh both before admitting a new durable mailbox write.
        _ = try await peers()
        // Compare-and-set before the first possible write also prevents two
        // clients from posting simultaneously. A crash here is conservative.
        _ = try configuration.journal.transition(id: record.id, destination: destination, from: .prepared, to: .attempted)
        do {
            let bytes = try await request("mailbox/\(mailbox.rawValue)", method: "POST", body: record.body)
            struct Receipt: Decodable { let stored: Bool; let id: String; let packetDigest: String; let delivery: String }
            guard bytes.count <= 1024 else { throw RelayDeviceTransportError.unsafeResponse }
            let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
            let digest = try packetDigest(packet)
            guard receipt.stored, receipt.id == record.id, receipt.packetDigest == digest,
                  ["queued", "acknowledged"].contains(receipt.delivery) else { throw RelayDeviceTransportError.unsafeResponse }
            _ = try configuration.journal.transition(id: record.id, destination: destination, from: .attempted, to: .accepted)
        } catch {
            // No network error, 5xx, cancellation, malformed receipt or save
            // failure authorizes another POST. Query the original owner.
            throw RelayDeviceTransportError.deliveryUncertain
        }
    }
    func uploadSnapshot(_ snapshot: DashboardSnapshot, sender: String) async throws {
        guard configuration.identity.role == .mac, sender == configuration.identity.deviceID else { throw RemoteRelayError.invalidPacket }
        try await ownGrant()
        let signed = try RelaySignedEnvelope.sign(.snapshot(snapshot, sender: sender), identity: configuration.identity,
            key: configuration.signingKey, destination: .snapshot)
        let packet = try cipher.seal(signed, sender: configuration.identity, destination: .snapshot)
        let bytes = try await request("snapshot", method: "PUT", body: CodexWatchCoding.makeEncoder().encode(packet))
        struct Receipt: Decodable { let stored: Bool; let id: String; let packetDigest: String?; let superseded: Bool? }
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.id == packet.id,
              receipt.stored ? receipt.packetDigest == (try packetDigest(packet)) : receipt.superseded == true else {
            throw RelayDeviceTransportError.unsafeResponse
        }
    }
    func latestSnapshot() async throws -> BridgeEnvelope? {
        let pins = try await peers(), bytes = try await request("snapshot")
        guard !bytes.isEmpty else { return nil }
        let envelope = try cipher.open(CodexWatchCoding.makeDecoder().decode(RelaySealedPacket.self, from: bytes),
            peers: pins.filter { $0.role == .mac }, destination: .snapshot).envelope
        // Match the server's separate five-minute snapshot freshness gate;
        // the signed original delivery deadline is not a liveness claim.
        let now = Date()
        guard envelope.kind == .snapshot, let snapshot = envelope.snapshot,
              envelope.sentAt > now.addingTimeInterval(-300),
              snapshot.capturedAt > now.addingTimeInterval(-300), snapshot.capturedAt <= now.addingTimeInterval(60) else {
            throw RelayDeviceTransportError.unsafeResponse
        }
        return envelope
    }
    func messages(for mailbox: RemoteRelayMailbox) async throws -> [BridgeEnvelope] {
        guard mailbox.rawValue == configuration.identity.role.rawValue,
              let destination = RelaySignedDestination(rawValue: mailbox.rawValue) else { throw RemoteRelayError.invalidPacket }
        let pins = try await peers()
        struct Page: Decodable {
            struct Rejection: Decodable { let id: String; let reason: String }
            let packets: [RelaySealedPacket]; let rejected: [Rejection]; let nextCursor: String?; let capturedAt: Int64
        }
        var envelopes: [BridgeEnvelope] = [], cursor: String?, seen: Set<String> = []
        // The server holds <=128 queued rows. Bound pages even for filtered
        // pages so a bad/mutating server cannot create an endless foreground.
        for _ in 0..<128 {
            let bytes = try await request("mailbox/\(mailbox.rawValue)", cursor: cursor)
            let page = try JSONDecoder().decode(Page.self, from: bytes)
            try requireFresh(page.capturedAt)
            guard page.packets.count + page.rejected.count <= 8,
                  page.rejected.allSatisfy({ RelayCredentials.validIdentifier($0.id) && $0.reason == "sender_no_longer_authorized" }) else {
                throw RelayDeviceTransportError.unsafeResponse
            }
            for packet in page.packets {
                guard seen.insert(packet.id).inserted else { throw RelayDeviceTransportError.unsafeResponse }
                let verified = try cipher.open(packet, peers: pins, destination: destination)
                envelopes.append(verified.envelope)
                guard envelopes.count <= 128 else { throw RelayDeviceTransportError.unsafeResponse }
            }
            guard let next = page.nextCursor else {
                verifiedDeliveries = Set(envelopes.map(\.messageID)); return envelopes
            }
            guard next.utf8.count == 16, next.utf8.allSatisfy({ (48...57).contains($0) }),
                  cursor == nil || next > cursor! else { throw RelayDeviceTransportError.unsafeResponse }
            cursor = next
        }
        throw RelayDeviceTransportError.unsafeResponse
    }
    func acknowledge(_ messageID: String, in mailbox: RemoteRelayMailbox) async throws {
        guard mailbox.rawValue == configuration.identity.role.rawValue,
              RelayCredentials.validIdentifier(messageID), verifiedDeliveries.contains(messageID) else {
            throw RelayDeviceTransportError.unverifiedAcknowledgement
        }
        _ = try await request("mailbox/\(mailbox.rawValue)/\(messageID)", method: "DELETE")
        verifiedDeliveries.remove(messageID)
    }
    func waitForMailboxActivity(_ mailbox: RemoteRelayMailbox, timeout: TimeInterval) async throws {
        guard mailbox.rawValue == configuration.identity.role.rawValue else { throw RemoteRelayError.invalidPacket }
        // V3 socket handshake/nonce recovery is a separate release gate.
        // No legacy WebSocket or watchOS-prohibited socket is opened here.
        try await Task.sleep(for: .seconds(min(30, max(1, timeout.isFinite ? timeout : 10))))
    }
    private func packetDigest(_ packet: RelaySealedPacket) throws -> String {
        let values: [Any] = [packet.version, packet.keyID, packet.destination, packet.id, packet.sentAt, packet.expiresAt, packet.sealed]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        return RelayDeviceEncoding.base64URL(Data(SHA256.hash(data: data)))
    }
}
