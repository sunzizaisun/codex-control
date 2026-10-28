import Foundation
import CodexWatchCore
import Darwin

/// Persists accepted actions before execution. A process interruption leaves
/// an unknown result; it never authorizes an automatic second execution.
public final class BridgeMessageDeduplicator: @unchecked Sendable {
    public enum BeginResult: Equatable, Sendable {
        case started
        case inFlight
        case completed(outcome: String?)
        case failed(message: String)
    }

    private struct Receipt: Codable, Sendable {
        enum State: String, Codable { case running, succeeded, failed, unknown }
        var state: State
        var fingerprint: String?
        var ownerBinding: CommandOwnerBinding? = nil
        let outcome: String?
        let failure: String?
        let updatedAt: Date

        var isValid: Bool {
            guard updatedAt.timeIntervalSince1970.isFinite else { return false }
            // The public journal treats fingerprints as opaque bounded IDs;
            // the transport currently supplies SHA-256, but restoration must
            // not silently impose that encoding on all existing callers.
            if let fingerprint, fingerprint.isEmpty || fingerprint.utf8.count > 256 { return false }
            if let ownerBinding, !ownerBinding.isValid || fingerprint == nil { return false }
            switch state {
            case .running: return outcome == nil && failure == nil
            case .succeeded: return failure == nil
            case .failed: return outcome == nil && failure != nil
            case .unknown: return outcome == nil
            }
        }
    }

    private let lock = NSLock()
    private let capacity: Int
    private let persistenceURL: URL?
    private var storageUnavailable = false
    private var journalLease: Int32 = -1
    private var inFlight: Set<String> = []
    private var activeFingerprints: [String: String] = [:]
    private var completed: [String: Receipt] = [:]
    private var completionOrder: [String] = []
    private var recoveryClaims: [String: UUID] = [:]
    private var lastRecoveryAttempt: [String: Date] = [:]

    /// Only a matching, durable unknown receipt can enter read-only recovery.
    /// This lease is shared by nearby and internet ingress; no await holds the
    /// journal lock and a second route cannot launch another simultaneous read.
    struct RecoveryClaim: Sendable {
        let messageID: String
        let fingerprint: String
        let token: UUID
        let ownerThreadID: String?
    }

    func claimRecovery(_ messageID: String, fingerprint: String, command: TaskCommand? = nil, now: Date = Date()) -> RecoveryClaim? {
        lock.lock()
        defer { lock.unlock() }
        guard refreshLeaseHealth(), let receipt = completed[messageID], receipt.state == .unknown,
              receipt.fingerprint == fingerprint, recoveryClaims[messageID] == nil,
              lastRecoveryAttempt[messageID].map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return nil }
        if let binding = receipt.ownerBinding {
            guard let command, binding.clientMessageID == command.id, binding.sourceTaskID == command.taskID,
                  binding.commandFingerprint == (try? CommandOwnerBinding.fingerprint(command)) else { return nil }
        }
        lastRecoveryAttempt = lastRecoveryAttempt.filter { completed[$0.key] != nil }
        let token = UUID()
        recoveryClaims[messageID] = token
        lastRecoveryAttempt[messageID] = now
        return RecoveryClaim(messageID: messageID, fingerprint: fingerprint, token: token,
            ownerThreadID: receipt.ownerBinding?.ownerThreadID)
    }

    /// A positive owner proof only confirms input acceptance, not completion.
    /// Persist it before returning an acknowledgement; on write failure retain
    /// the unknown in-memory receipt and close admission through persist().
    func finishRecovery(_ claim: RecoveryClaim, accepted: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recoveryClaims[claim.messageID] == claim.token else { return false }
        recoveryClaims.removeValue(forKey: claim.messageID)
        guard accepted, refreshLeaseHealth(), let previous = completed[claim.messageID],
              previous.state == .unknown, previous.fingerprint == claim.fingerprint else { return false }
        completed[claim.messageID] = Receipt(state: .succeeded, fingerprint: claim.fingerprint,
            ownerBinding: previous.ownerBinding,
            outcome: nil, failure: nil, updatedAt: Date())
        guard persist() else { completed[claim.messageID] = previous; return false }
        return true
    }

    public static var defaultJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexControl/ReliableActions/receipts-v2.json")
    }

    public init(capacity: Int = 512, persistenceURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.persistenceURL = persistenceURL
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(persistenceURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { storageUnavailable = true; return }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor); storageUnavailable = true; return
            }
            journalLease = descriptor
            guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
            let attributes = try FileManager.default.attributesOfItem(atPath: persistenceURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else {
                storageUnavailable = true; return
            }
            let data = try Data(contentsOf: persistenceURL)
            guard data.count <= 8 * 1024 * 1024 else { storageUnavailable = true; return }
            let restored = try JSONDecoder().decode([String: Receipt].self, from: data)
            guard restored.count <= self.capacity, restored.allSatisfy({ id, receipt in
                !id.isEmpty && id.utf8.count <= 160 && receipt.isValid
            }) else { storageUnavailable = true; return }
            let commandIDs = restored.values.compactMap { $0.ownerBinding?.clientMessageID }
            guard Set(commandIDs).count == commandIDs.count else { storageUnavailable = true; return }
            completed = restored
            for (id, var receipt) in completed {
                if receipt.state == .running { receipt.state = .unknown; completed[id] = receipt }
            }
        } catch { storageUnavailable = true }
    }

    deinit {
        if journalLease >= 0 { _ = flock(journalLease, LOCK_UN); close(journalLease) }
    }

    /// Borrow the existing process lease for brief synchronous owner setup.
    /// In-memory/preview journals never qualify. A replaced/linked/insecure
    /// lock file or inherited descriptor closes admission, not a new lock.
    func withExclusiveDurableOwnerLease<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard persistenceURL != nil, refreshLeaseHealth() else { throw CommandOwnerBindingError.persistenceUnavailable }
        return try operation()
    }
    /// Called with `lock` held. No actor suspension or filesystem repair.
    private func refreshLeaseHealth() -> Bool {
        guard !storageUnavailable else { return false }
        guard let persistenceURL else { return true }
        var descriptor = stat(), pathname = stat()
        let flags = fcntl(journalLease, F_GETFD)
        guard journalLease >= 0, flags >= 0, flags & FD_CLOEXEC != 0,
              fstat(journalLease, &descriptor) == 0,
              lstat(persistenceURL.appendingPathExtension("lock").path, &pathname) == 0,
              descriptor.st_dev == pathname.st_dev, descriptor.st_ino == pathname.st_ino,
              descriptor.st_nlink == 1, pathname.st_nlink == 1,
              descriptor.st_mode & S_IFMT == S_IFREG, pathname.st_mode & S_IFMT == S_IFREG,
              descriptor.st_uid == geteuid(), pathname.st_uid == geteuid(),
              descriptor.st_mode & 0o777 == 0o600 else { storageUnavailable = true; return false }
        return true
    }

    public func begin(_ messageID: String, fingerprint: String? = nil, command: TaskCommand? = nil) -> BeginResult {
        lock.lock()
        defer { lock.unlock() }
        guard refreshLeaseHealth() else { return .failed(message: AppLocalizer.text("无法保存操作回执，请在 Mac 上检查后重试。")) }
        guard !messageID.isEmpty, messageID.utf8.count <= 160 else {
            return .failed(message: AppLocalizer.text("远程数据校验失败"))
        }
        if let fingerprint, fingerprint.isEmpty || fingerprint.utf8.count > 256 {
            return .failed(message: AppLocalizer.text("远程数据校验失败"))
        }
        let ownerBinding: CommandOwnerBinding?
        do { ownerBinding = try command.map(CommandOwnerBinding.init) }
        catch { return .failed(message: AppLocalizer.text("远程数据校验失败")) }
        if ownerBinding != nil && fingerprint == nil { return .failed(message: AppLocalizer.text("远程数据校验失败")) }
        if let value = completed[messageID] {
            if value.fingerprint != fingerprint { return .failed(message: AppLocalizer.text("同一消息编号的内容已改变，操作未执行。")) }
            if let binding = value.ownerBinding {
                guard let ownerBinding, binding.clientMessageID == ownerBinding.clientMessageID,
                      binding.sourceTaskID == ownerBinding.sourceTaskID,
                      binding.commandFingerprint == ownerBinding.commandFingerprint else {
                    return .failed(message: AppLocalizer.text("同一消息编号的内容已改变，操作未执行。"))
                }
            }
            if value.state == .unknown { return .failed(message: AppLocalizer.text("上次操作结果未确认，请先检查原任务。")) }
            if value.state == .running { return .inFlight }
            if let failure = value.failure { return .failed(message: failure) }
            return .completed(outcome: value.outcome)
        }
        if storageUnavailable { return .failed(message: AppLocalizer.text("无法保存操作回执，请在 Mac 上检查后重试。")) }
        if let ownerBinding, let prior = completed.values.first(where: {
            $0.ownerBinding?.clientMessageID == ownerBinding.clientMessageID
        }) {
            // Rewrapping the same command in a new transport envelope is not
            // a new user action, even after a process restart.
            guard prior.ownerBinding?.commandFingerprint == ownerBinding.commandFingerprint else {
                return .failed(message: AppLocalizer.text("同一消息编号的内容已改变，操作未执行。"))
            }
            switch prior.state {
            case .running: return .inFlight
            case .unknown: return .failed(message: AppLocalizer.text("上次操作结果未确认，请先检查原任务。"))
            case .failed: return .failed(message: prior.failure ?? AppLocalizer.text("上次操作结果未确认，请先检查原任务。"))
            case .succeeded: return .completed(outcome: prior.outcome)
            }
        }
        if inFlight.contains(messageID), activeFingerprints[messageID] != fingerprint {
            return .failed(message: AppLocalizer.text("同一消息编号的内容已改变，操作未执行。"))
        }
        guard inFlight.insert(messageID).inserted else {
            return .inFlight
        }
        activeFingerprints[messageID] = fingerprint
        if persistenceURL != nil || ownerBinding != nil {
            // Keep receipts beyond the maximum command lifetime. When the
            // journal is full, refuse new work rather than evicting an action
            // that can still be replayed from a durable delivery queue.
            completed = completed.filter { $0.value.state == .running || Date().timeIntervalSince($0.value.updatedAt) < 25 * 60 * 60 }
            guard completed.count < capacity else {
                inFlight.remove(messageID)
                activeFingerprints.removeValue(forKey: messageID)
                return .failed(message: AppLocalizer.text("操作回执空间已满，请稍后再试。"))
            }
            // In-memory CLI/test callers need the same bounded per-command
            // protection while this process lives. Only persistent callers
            // claim restart recovery; changing a wrapper bypasses neither.
            completed[messageID] = Receipt(state: .running, fingerprint: fingerprint,
                ownerBinding: ownerBinding, outcome: nil, failure: nil, updatedAt: Date())
            if !persist() {
                completed.removeValue(forKey: messageID); inFlight.remove(messageID); activeFingerprints.removeValue(forKey: messageID)
                return .failed(message: AppLocalizer.text("无法保存操作回执，请在 Mac 上检查后重试。"))
            }
        }
        return .started
    }

    @discardableResult
    public func finish(_ messageID: String, outcome: String? = nil) -> Bool {
        complete(messageID, outcome: outcome, failure: nil)
    }

    /// Inspect only. This method cannot insert an action, claim execution or
    /// evict a receipt. A missing/corrupt journal is not proof of rejection.
    func inspect(_ messageID: String, fingerprint: String) -> CommandStatusReceipt {
        lock.lock()
        defer { lock.unlock() }
        func receipt(_ state: CommandStatusReceipt.State, _ value: Receipt? = nil) -> CommandStatusReceipt {
            .init(originalMessageID: messageID, state: state,
                ownerThreadID: value?.ownerBinding?.ownerThreadID, message: value?.failure)
        }
        guard refreshLeaseHealth() else { return receipt(.unavailable) }
        guard let value = completed[messageID] else {
            if inFlight.contains(messageID), activeFingerprints[messageID] == fingerprint { return receipt(.inFlight) }
            return receipt(.notFound)
        }
        guard value.fingerprint == fingerprint else { return receipt(.unavailable) }
        switch value.state {
        case .running: return receipt(.inFlight, value)
        case .unknown: return receipt(.unconfirmed, value)
        case .failed: return receipt(.rejected, value)
        case .succeeded: return receipt(.accepted, value)
        }
    }

    /// A transport retry is not a new user decision. A timeout may happen
    /// after Codex accepted the operation, so replay the original error
    /// instead of running a second turn or consuming a second reset card.
    public func fail(_ messageID: String, message: String) {
        complete(messageID, outcome: nil, failure: message)
    }

    public func markUnconfirmed(_ messageID: String) {
        complete(messageID, outcome: nil,
            failure: AppLocalizer.text("上次操作结果未确认，请先检查原任务。"), unconfirmed: true)
    }

    /// Persist the server-assigned owner before turn/start can send input.
    /// Local non-journal commands have no matching receipt and are untouched.
    /// An existing binding is immutable: a retry must not create a new owner.
    public func bindAssignedOwner(_ command: TaskCommand, threadID: String) throws {
        guard command.startsNewCodexChat, CommandOwnerBinding.validOwnerID(threadID) else {
            throw CommandOwnerBindingError.invalidOwner
        }
        let commandFingerprint = try CommandOwnerBinding.fingerprint(command)
        lock.lock()
        defer { lock.unlock() }
        let ids = completed.compactMap { id, receipt in
            receipt.ownerBinding?.clientMessageID == command.id ? id : nil
        }
        guard !ids.isEmpty else { return }
        guard refreshLeaseHealth() else { throw CommandOwnerBindingError.persistenceUnavailable }
        guard ids.allSatisfy({ id in
            guard let binding = completed[id]?.ownerBinding else { return false }
            return completed[id]?.state == .running && binding.sourceTaskID == command.taskID
                && binding.commandFingerprint == commandFingerprint
                && (binding.ownerThreadID == nil || binding.ownerThreadID == threadID)
        }) else { throw CommandOwnerBindingError.ownerChanged }
        let previous = completed
        for id in ids { completed[id]?.ownerBinding?.ownerThreadID = threadID }
        guard persist() else {
            completed = previous
            throw CommandOwnerBindingError.persistenceUnavailable
        }
    }

    @discardableResult
    private func complete(_ messageID: String, outcome: String?, failure: String?, unconfirmed: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(messageID)
        guard completed[messageID] == nil || completed[messageID]?.state == .running else {
            return refreshLeaseHealth() && completed[messageID]?.state == .succeeded
        }
        let fingerprint = completed[messageID]?.fingerprint ?? activeFingerprints[messageID]
        let ownerBinding = completed[messageID]?.ownerBinding
        activeFingerprints.removeValue(forKey: messageID)
        completed[messageID] = Receipt(state: unconfirmed ? .unknown : (failure == nil ? .succeeded : .failed),
            fingerprint: fingerprint, ownerBinding: ownerBinding, outcome: outcome, failure: failure, updatedAt: Date())
        if persistenceURL == nil { completionOrder.append(messageID) }
        if persistenceURL == nil, completionOrder.count > capacity {
            let removed = completionOrder.removeFirst()
            completed.removeValue(forKey: removed)
        }
        guard persist() else {
            // The owner may have acted, but the success is not durable. The
            // previous on-disk running record safely restores as unknown.
            completed[messageID] = Receipt(state: .unknown, fingerprint: fingerprint, ownerBinding: ownerBinding,
                outcome: nil, failure: AppLocalizer.text("上次操作结果未确认，请先检查原任务。"), updatedAt: Date())
            return false
        }
        return true
    }

    public func cancel(_ messageID: String) {
        lock.lock()
        inFlight.remove(messageID)
        activeFingerprints.removeValue(forKey: messageID)
        if var receipt = completed[messageID], receipt.state == .running {
            receipt.state = .unknown; completed[messageID] = receipt; _ = persist()
        }
        lock.unlock()
    }

    /// Called with the lock held. A write failure closes admission to new
    /// actions. The previous on-disk running record still blocks re-execution
    /// after a restart even if writing the final outcome fails.
    private func persist() -> Bool {
        guard refreshLeaseHealth() else { return false }
        guard let persistenceURL else { return true }
        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(completed)
            guard data.count <= 8 * 1024 * 1024 else { storageUnavailable = true; return false }
            try data.write(to: persistenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
            return true
        } catch { storageUnavailable = true; return false }
    }
}
