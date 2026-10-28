@preconcurrency import Foundation
import CodexWatchCore

public enum AppServerRequestID: Hashable, Sendable {
    case integer(Int)
    case string(String)

    public init?(_ value: JSONValue?) {
        if let integer = value?.intValue {
            self = .integer(integer)
        } else if let string = value?.stringValue {
            self = .string(string)
        } else {
            return nil
        }
    }

    var wireValue: JSONValue {
        switch self {
        case .integer(let value): return .integer(value)
        case .string(let value): return .string(value)
        }
    }
}

public struct AppServerEvent: Sendable {
    public let method: String
    public let params: JSONValue
    public let requestID: AppServerRequestID?

    public init(method: String, params: JSONValue, requestID: AppServerRequestID?) {
        self.method = method
        self.params = params
        self.requestID = requestID
    }
}

public enum AppServerClientError: LocalizedError, Sendable {
    case executableNotFound
    case notRunning
    case processExited
    case timedOut(method: String)
    case invalidResponse
    case server(code: Int?, message: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Could not find the Codex executable. Set CODEX_BIN to its absolute path."
        case .notRunning:
            "Codex app-server is not running."
        case .processExited:
            "Codex app-server exited before replying."
        case .timedOut(let method):
            "Codex app-server timed out while handling \(method)."
        case .invalidResponse:
            "Codex app-server returned an invalid response."
        case .server(_, let message):
            message
        }
    }
}

public enum AppServerConnectionSource: String, Sendable {
    case managedDaemon
    case standalone
}

public actor AppServerClient {
    public typealias EventHandler = @Sendable (AppServerEvent) async -> Void

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    /// The file-handle readiness callback can fire again while an earlier
    /// chunk is still being decoded or delivered to the event handler. The
    /// previous implementation created one unbounded Task per callback. A
    /// busy app-server stream therefore accumulated thousands of suspended
    /// tasks, which made the desktop bridge consume a full CPU core and grow
    /// its memory footprint over time. A single AsyncStream reader provides
    /// back-pressure and preserves protocol order.
    private var outputReadTask: Task<Void, Never>?
    private var outputStreamContinuation: AsyncStream<Data>.Continuation?
    private var readBuffer = Data()
    /// Start the next newline search after the bytes already inspected. A
    /// partial JSONL line split across many pipe callbacks must not be scanned
    /// from byte zero on every callback, otherwise a long response becomes an
    /// O(n²) CPU loop.
    private var readSearchOffset = 0
    private static let maximumBufferedLineBytes = 16 * 1_024 * 1_024
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var eventHandler: EventHandler?
    private var lifecycleHandler: (@Sendable () async -> Void)?
    /// Tests and local development can supply a private executable without
    /// mutating the process-wide CODEX_BIN environment variable. Production
    /// callers leave this nil and use the normal resolution order below.
    private let executableOverride: URL?

    public private(set) var isRunning = false
    public private(set) var connectionSource: AppServerConnectionSource = .standalone

    public init(executableURL: URL? = nil) {
        executableOverride = executableURL
    }

    /// Command sessions share the executable, not the conversation writer.
    public nonisolated func makeSibling() -> AppServerClient {
        AppServerClient(executableURL: executableOverride)
    }

    public func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    public func setLifecycleHandler(
        _ handler: (@Sendable () async -> Void)?
    ) {
        lifecycleHandler = handler
    }

    @discardableResult
    public func start(preferManagedDaemon: Bool = true) async throws -> JSONValue {
        if isRunning {
            return .object([:])
        }

        let executable = try Self.resolveCodexExecutable(overriding: executableOverride)
        let proxySocket = preferManagedDaemon ? Self.resolveDaemonSocket() : nil
        do {
            try launch(executable: executable, daemonSocket: proxySocket)
            let result = try await initialize()
            connectionSource = proxySocket == nil ? .standalone : .managedDaemon
            return result
        } catch {
            // A stale daemon socket should never prevent the bridge from
            // working. Fall back to the bundled stdio server, which is the
            // behavior used by older installations and local development.
            if proxySocket != nil {
                stop()
                do {
                    try launch(executable: executable, daemonSocket: nil)
                    let result = try await initialize()
                    connectionSource = .standalone
                    return result
                } catch {
                    // Do not leave a half-started fallback process around. A
                    // later reconnect must be able to launch a fresh client.
                    stop()
                    throw error
                }
            }
            stop()
            throw error
        }
    }

    private func launch(executable: URL, daemonSocket: String?) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executable
        if let daemonSocket {
            process.arguments = ["app-server", "proxy", "--sock", daemonSocket]
        } else {
            process.arguments = ["app-server", "--stdio"]
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        process.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { await self?.processDidExit(expectedPID: pid) }
        }

        try process.run()
        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        isRunning = true
        startReaders(output: outputHandle, error: errorHandle, expectedPID: process.processIdentifier)
    }

    private func initialize() async throws -> JSONValue {
        let initializeResult = try await request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("codex_watch_bridge"),
                    "title": .string("Codex Watch Bridge"),
                    "version": .string("0.2.1"),
                ]),
                // Required by the installed official schema for structured
                // request_user_input. Mobile RPCs remain narrowly allowlisted.
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ]),
            // A dead or half-started child must not hold the recovery state
            // machine for the full normal request timeout. Other requests
            // retain the 30-second budget for long desktop operations.
            timeout: .seconds(15)
        )
        try sendNotification(method: "initialized", params: .object([:]))
        return initializeResult
    }

    public func stop() {
        outputStreamContinuation?.finish()
        outputReadTask?.cancel()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        finishPending(with: AppServerClientError.processExited)
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputStreamContinuation = nil
        outputReadTask = nil
        readBuffer.removeAll(keepingCapacity: true)
        readSearchOffset = 0
        isRunning = false
        connectionSource = .standalone
    }

    public func stopAndWaitForExit() async {
        let child = process
        stop()
        // The writer lock belongs to the actual child, not isRunning above.
        // Wait briefly for its exit before a new connection takes the task.
        for _ in 0..<100 where child?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    public func request(
        method: String,
        params: JSONValue = .object([:]),
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        guard isRunning, let inputHandle else {
            throw AppServerClientError.notRunning
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let message: JSONValue = .object([
            "id": .integer(requestID),
            "method": .string(method),
            "params": params,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeout(requestID: requestID, method: method)
            }
            do {
                try Self.write(message, to: inputHandle)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func timeout(requestID: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: AppServerClientError.timedOut(method: method))
    }

    public func respond(to requestID: AppServerRequestID, result: JSONValue) throws {
        guard isRunning, let inputHandle else {
            throw AppServerClientError.notRunning
        }
        try Self.write(
            .object([
                "id": requestID.wireValue,
                "result": result,
            ]),
            to: inputHandle
        )
    }

    public func respondWithError(
        to requestID: AppServerRequestID,
        code: Int = -32601,
        message: String
    ) throws {
        guard isRunning, let inputHandle else {
            throw AppServerClientError.notRunning
        }
        try Self.write(
            .object([
                "id": requestID.wireValue,
                "error": .object([
                    "code": .integer(code),
                    "message": .string(message),
                ]),
            ]),
            to: inputHandle
        )
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        guard isRunning, let inputHandle else {
            throw AppServerClientError.notRunning
        }
        try Self.write(
            .object([
                "method": .string(method),
                "params": params,
            ]),
            to: inputHandle
        )
    }

    private func ingest(_ data: Data) async {
        guard !data.isEmpty else {
            await processDidExit()
            return
        }

        readBuffer.append(data)
        guard readBuffer.count <= Self.maximumBufferedLineBytes else {
            // A malformed/non-JSONL child must not retain unbounded memory or
            // keep the parser hot forever. Drop the partial frame and resume
            // at the next newline-delimited response.
            if let newlineIndex = readBuffer[readSearchOffset...].firstIndex(of: 0x0A) {
                readBuffer.removeSubrange(...newlineIndex)
            } else {
                readBuffer.removeAll(keepingCapacity: true)
            }
            readSearchOffset = 0
            return
        }
        while let newlineIndex = readBuffer[readSearchOffset...].firstIndex(of: 0x0A) {
            let line = readBuffer[..<newlineIndex]
            readBuffer.removeSubrange(...newlineIndex)
            readSearchOffset = 0
            guard !line.isEmpty else { continue }
            do {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                await handle(value)
            } catch {
                // Ignore malformed log lines. App-server protocol output remains JSONL on stdout.
            }
        }
        // No newline yet: every byte before this offset has been inspected;
        // the next callback only needs to search its newly appended suffix.
        readSearchOffset = readBuffer.count
    }

    /// Consume child pipes from the file-descriptor readiness callback. A
    /// blocking `availableData` loop can miss the first reply when this code
    /// runs inside a SwiftUI GUI process, leaving initialize pending forever.
    private func startReaders(output: FileHandle, error: FileHandle, expectedPID: Int32) {
        let stream = AsyncStream<Data>.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        outputStreamContinuation = stream.continuation
        output.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                stream.continuation.finish()
                return
            }
            stream.continuation.yield(data)
        }
        error.readabilityHandler = { handle in
            // Drain stderr so diagnostic output cannot block stdout protocol.
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        outputReadTask = Task { [weak self] in
            for await data in stream.stream {
                guard !Task.isCancelled else { return }
                await self?.ingest(data)
            }
            guard !Task.isCancelled else { return }
            await self?.processDidExit(expectedPID: expectedPID)
        }
    }

    private func handle(_ value: JSONValue) async {
        if let responseID = value["id"]?.intValue,
           value["method"] == nil,
           let continuation = pending.removeValue(forKey: responseID) {
            if let error = value["error"] {
                let code = error["code"]?.intValue
                let message = error["message"]?.stringValue ?? "Codex app-server error"
                continuation.resume(throwing: AppServerClientError.server(code: code, message: message))
            } else if let result = value["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: AppServerClientError.invalidResponse)
            }
            return
        }

        guard let method = value["method"]?.stringValue else { return }
        let event = AppServerEvent(
            method: method,
            params: value["params"] ?? .object([:]),
            requestID: AppServerRequestID(value["id"])
        )
        await eventHandler?(event)
    }

    private func processDidExit(expectedPID: Int32? = nil) async {
        if let expectedPID, process?.processIdentifier != expectedPID { return }
        guard isRunning else { return }
        outputStreamContinuation?.finish()
        outputReadTask?.cancel()
        outputStreamContinuation = nil
        outputReadTask = nil
        isRunning = false
        readBuffer.removeAll(keepingCapacity: true)
        finishPending(with: AppServerClientError.processExited)
        await lifecycleHandler?()
    }

    private func finishPending(with error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private static func write(_ value: JSONValue, to handle: FileHandle) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func resolveCodexExecutable(overriding executableOverride: URL? = nil) throws -> URL {
        try CodexExecutableLocator.resolve(
            overriding: executableOverride,
            environment: ProcessInfo.processInfo.environment,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

}

/// Ordered, testable discovery of vendor-bundled and separately installed CLI
/// versions. Never depend on the Finder-launched app inheriting a shell PATH.
enum CodexExecutableLocator {
    static func resolve(
        overriding executableOverride: URL? = nil,
        environment: [String: String],
        applicationPath: String = "/Applications/ChatGPT.app",
        isExecutable: (String) -> Bool
    ) throws -> URL {
        if let executableOverride, isExecutable(executableOverride.path) {
            return executableOverride
        }
        let candidates = [
            environment["CODEX_BIN"],
            "\(applicationPath)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(applicationPath)/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap { $0 }

        for path in candidates where isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        throw AppServerClientError.executableNotFound
    }

}

private extension AppServerClient {

    /// The managed daemon is the only supported local way to attach a second
    /// client to an already-running app-server session. The desktop app does
    /// not expose its private stdio pipes, so this is intentionally opt-in
    /// through the documented daemon control socket and never guesses at
    /// private desktop IPC.
    private static func resolveDaemonSocket() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_APP_SERVER_SOCKET"],
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/app-server-control/app-server-control.sock").path,
        ].compactMap { $0 }
        return candidates.first { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let type = attributes[.type] as? FileAttributeType else { return false }
            return type == .typeSocket
        }
    }
}
