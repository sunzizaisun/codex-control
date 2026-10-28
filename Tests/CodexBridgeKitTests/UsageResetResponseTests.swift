import Foundation
import Testing
import CodexWatchCore
@testable import CodexBridgeKit

@Test func resetUsesTheExactOriginalRedemptionKeyAndOnlyKnownOutcomes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    for outcome in ["reset", "alreadyRedeemed", "nothingToReset", "noCredit", "unknown", "missing"] {
        let executable = directory.appendingPathComponent("fixture-\(outcome)")
        let log = directory.appendingPathComponent("requests-\(outcome).jsonl")
        let logLiteral = String(data: try JSONEncoder().encode(log.path), encoding: .utf8)!
        let script = """
        #!/usr/bin/env node
        const fs=require('fs'),rl=require('readline').createInterface({input:process.stdin});
        rl.on('line',l=>{const v=JSON.parse(l);if(v.id===undefined)return;
          fs.appendFileSync(\(logLiteral),JSON.stringify(v)+'\\n');
          let result={};
          if(v.method==='account/rateLimitResetCredit/consume')result=\(outcome == "missing" ? "{}" : "{outcome:'\(outcome)'}");
          else if(v.method==='thread/list'||v.method==='model/list')result={data:[],nextCursor:null};
          process.stdout.write(JSON.stringify({id:v.id,result})+'\\n');
        });
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = AppServerClient(executableURL: executable), service = CodexBridgeService(client: client)
        try await service.start(refreshImmediately: false, preferManagedDaemon: false)
        let request = UsageResetRequest(id: "stable-redemption-\(outcome)", creditID: "opaque-credit-🦦", deviceID: "watch")
        do {
            let result = try await service.consumeResetCredit(request)
            #expect(UsageResetOutcome(rawValue: outcome) != nil)
            #expect(result == outcome)
        } catch AppServerClientError.invalidResponse {
            #expect(["unknown", "missing"].contains(outcome))
            #expect(MacActionFailure.isUnconfirmed(AppServerClientError.invalidResponse))
        } catch { Issue.record("Unexpected fixture error: \(type(of: error))") }
        await service.stop()
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        let redemptions = rows.filter { $0["method"]?.stringValue == "account/rateLimitResetCredit/consume" }
        #expect(redemptions.count == 1)
        #expect(redemptions.first?["params"]?["idempotencyKey"]?.stringValue == request.id)
        #expect(redemptions.first?["params"]?["creditId"]?.stringValue == request.creditID)
        if UsageResetOutcome(rawValue: outcome) != nil {
            #expect(rows.contains { $0["method"]?.stringValue == "account/rateLimits/read" })
        }
    }
}

@Test func emptyResetIdentifiersAreRejectedBeforeAnyRemoteCall() async {
    let client = AppServerClient(executableURL: URL(fileURLWithPath: "/nonexistent/fixture"))
    let service = CodexBridgeService(client: client)
    for request in [UsageResetRequest(id: "", creditID: nil, deviceID: "watch"),
                    UsageResetRequest(creditID: "  ", deviceID: "watch")] {
        do { _ = try await service.consumeResetCredit(request); Issue.record("Empty identifier was accepted") }
        catch CodexCompanionCommandError.invalidCommand { }
        catch { Issue.record("Unexpected validation error: \(type(of: error))") }
        #expect(await client.isRunning == false)
    }
}
