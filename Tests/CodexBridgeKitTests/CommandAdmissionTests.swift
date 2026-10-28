import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

@Test func emptyCommandsAreRejectedBeforeStartingAProcessOrCreatingAThread() async {
    let client = AppServerClient(executableURL: URL(fileURLWithPath: "/nonexistent/fixture-codex"))
    let service = CodexBridgeService(client: client)
    for prompt in ["", " \n\t", "\u{00a0}"] {
        for route in 0..<3 {
            do {
                switch route {
                case 0: try await service.send(.init(taskID: "fixture", prompt: prompt, deviceID: "watch"))
                case 1: _ = try await service.startTask(prompt: prompt, workingDirectory: "/fixture")
                default: _ = try await service.startCodexConversation(prompt: prompt)
                }
                Issue.record("Empty input was reported as accepted")
            } catch CodexCompanionCommandError.invalidCommand {
                #expect(!MacActionFailure.isUnconfirmed(CodexCompanionCommandError.invalidCommand))
            } catch { Issue.record("Unexpected admission error: \(type(of: error))") }
            #expect(await client.isRunning == false)
        }
    }
}
