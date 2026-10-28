import Foundation

extension RelayKeyDeliveryOwnerStore: RelayOwnerCreationPersistence {}

/// A locally saved scan invitation, not mobile key-ready or Mac Online.
/// Its original 120-second deadline still governs scanning/enrollment.
public enum RelayOwnerPairingUpdate: Sendable {
    case invitationSaved(RelaySecurePairingInvitation)
    case creationUnconfirmed(invitationID: String)
}

/// Explicit bounded creation flow. No timer, root self-registration, default
/// UI activation, replacement QR or new runtime dependency for cloud dot.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
public actor RelayOwnerPairingCreator {
    private let configuration: RelayDeviceConfiguration
    private let store: any RelayOwnerCreationPersistence
    private let http: RelayDeviceHTTPClient
    private let clock: @Sendable () -> Date
    private var advancing = false

    public init(ownerConfiguration: RelayDeviceConfiguration, store: RelayKeyDeliveryOwnerStore = .init(),
                requestTimeout: TimeInterval = 10, requestTransport: RemoteRelayClient.RequestTransport? = nil) throws {
        guard ownerConfiguration.identity.role == .mac, ownerConfiguration.identity == ownerConfiguration.owner else {
            throw RelayDeviceTransportError.invalidPeer
        }
        configuration = ownerConfiguration; self.store = store; clock = { Date() }
        http = .init(baseURL: ownerConfiguration.baseURL, roomID: ownerConfiguration.identity.roomID,
            keyID: ownerConfiguration.identity.keyID, requestTimeout: requestTimeout,
            waitsForConnectivity: false, requestTransport: requestTransport)
    }
    init(configuration: RelayDeviceConfiguration, store: any RelayOwnerCreationPersistence,
         http: RelayDeviceHTTPClient, clock: @escaping @Sendable () -> Date) {
        self.configuration = configuration; self.store = store; self.http = http; self.clock = clock
    }
    /// Explicit user-start only. Never call this from reconnect/restore.
    /// An existing draft, even expired/corrupt, cannot be replaced by begin.
    public func begin(role: RelayDeviceRole, grantExpiresAt: Int64) async throws -> RelayOwnerPairingUpdate {
        try await run(role: role, grantExpiresAt: grantExpiresAt, allowCreation: true)
    }
    /// Continue only the previously saved slot. Missing material is not a
    /// fresh pairing request and cannot regenerate a capability or contact IO.
    public func advance(role: RelayDeviceRole, grantExpiresAt: Int64) async throws -> RelayOwnerPairingUpdate {
        try await run(role: role, grantExpiresAt: grantExpiresAt, allowCreation: false)
    }
    private func run(role: RelayDeviceRole, grantExpiresAt: Int64, allowCreation: Bool) async throws -> RelayOwnerPairingUpdate {
        guard !advancing else { throw RelayKeyDeliveryError.notReady }; advancing = true; defer { advancing = false }
        // Save original capability/HPKE material before even the first GET.
        // A save error vetoes all network IO, not just the later mutation.
        let draft: RelayOwnerCreationDraft
        if allowCreation {
            draft = try store.stageCreation(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: clock())
        } else {
            guard let saved = try store.loadCreation(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: clock()) else {
                throw RelayKeyDeliveryError.notReady
            }
            draft = saved
        }
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: clock())
        let owner = configuration.identity, offer = draft.offer.enrollment
        let registry = RelayDeviceRegistryClient(baseURL: configuration.baseURL, identity: owner,
            signingKey: configuration.signingKey, accessToken: configuration.accessToken, http: http, clock: clock)
        _ = try await registry.ownGrant()
        // Preflight recovery support BEFORE a creation POST. An old server
        // lacking this exact query cannot leave an unrecoverable new offer.
        if let found = try await registry.ownerInvitationReceipt(for: offer) {
            return try saved(draft, receipt: found.data, role: role, grantExpiresAt: grantExpiresAt)
        }
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: clock())
        guard !draft.attempted, try store.claimCreation(draft, configuration: configuration, now: clock()) else {
            return .creationUnconfirmed(invitationID: offer.invitationID)
        }
        do {
            let request = try offer.request(accessToken: configuration.accessToken, now: clock())
            let reply = try await http.send(request, signingKey: configuration.signingKey, accessToken: configuration.accessToken,
                expiresAt: min(owner.expiresAt, Date(timeIntervalSince1970: Double(offer.expiresAt) / 1000)),
                maximumResponseBytes: 4096)
            guard reply.status == 200 else { throw RelayDeviceTransportError.unsafeResponse }
            _ = try offer.invitation(from: reply.data, now: clock())
        } catch is CancellationError { throw CancellationError() }
        catch { return .creationUnconfirmed(invitationID: offer.invitationID) }
        let found: (invitation: RelayEnrollmentInvitation, data: Data)?
        do { found = try await registry.ownerInvitationReceipt(for: offer) }
        catch is CancellationError { throw CancellationError() }
        catch { return .creationUnconfirmed(invitationID: offer.invitationID) }
        guard let found else { return .creationUnconfirmed(invitationID: offer.invitationID) }
        // Keychain promotion errors are not hidden as successful pairing.
        return try saved(draft, receipt: found.data, role: role, grantExpiresAt: grantExpiresAt)
    }
    private func saved(_ draft: RelayOwnerCreationDraft, receipt: Data, role: RelayDeviceRole,
                       grantExpiresAt: Int64) throws -> RelayOwnerPairingUpdate {
        let invitation = try store.confirmCreation(draft, serverResponse: receipt, configuration: configuration, now: clock())
        // Synchronous Keychain IO may itself take time. Never return an
        // expired QR even if its valid save already committed; retain it.
        try draft.validate(configuration: configuration, role: role, grantExpiresAt: grantExpiresAt, now: clock())
        try invitation.enrollment.validate(now: clock())
        return .invitationSaved(invitation)
    }
}
