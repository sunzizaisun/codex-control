import Foundation
import Testing
@testable import CodexWatchCore

@Test func statusQueryIsBoundedReadOnlyAndRoundTripsInV3() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let original = BridgeEnvelope(sentAt: now, kind: .taskCommand, senderDeviceID: "watch",
        taskCommand: .init(taskID: "owner", prompt: "中文🦦", sentAt: now, deviceID: "watch"))
    var query = BridgeEnvelope(sentAt: now, kind: .requestSnapshot, senderDeviceID: "watch",
        commandStatusQuery: .init(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(original)))
    #expect(query.commandStatusQuery?.validatedOriginal(for: query, now: now) == original)
    let bytes = try CodexWatchCoding.makeEncoder().encode(query)
    #expect(try CodexWatchCoding.makeDecoder().decode(BridgeEnvelope.self, from: bytes) == query)
    query.commandStatusQuery = .init(originalEnvelope: Data(repeating: 65, count: CommandStatusQuery.maximumOriginalBytes + 1))
    #expect(query.commandStatusQuery?.validatedOriginal(for: query) == nil)
    query.commandStatusQuery = .init(originalEnvelope: Data())
    #expect(query.commandStatusQuery?.validatedOriginal(for: query) == nil)
}

@Test func staleMixedOrNestedStatusQueriesFailClosed() throws {
    let original = BridgeEnvelope.taskCommand(.init(taskID: "owner", prompt: "input", deviceID: "watch"), sender: "watch")
    let originalData = try CodexWatchCoding.makeEncoder().encode(original)
    let query = BridgeEnvelope(kind: .requestSnapshot, senderDeviceID: "watch", commandStatusQuery: .init(originalEnvelope: originalData))
    var bad = query; bad.sentAt = Date().addingTimeInterval(-901)
    #expect(bad.commandStatusQuery?.validatedOriginal(for: bad) == nil)
    bad = query; bad.taskCommand = original.taskCommand
    #expect(bad.commandStatusQuery?.validatedOriginal(for: bad) == nil)
    bad = query; bad.kind = .hello
    #expect(bad.commandStatusQuery?.validatedOriginal(for: bad) == nil)
    bad = query; bad.commandStatusQuery = .init(originalEnvelope: try CodexWatchCoding.makeEncoder().encode(query))
    #expect(bad.commandStatusQuery?.validatedOriginal(for: bad) == nil)
}
