import Foundation
import CodexBridgeKit
import CodexWatchCore

@main
struct CodexWatchBridgeCommand {
    static func main() async {
        let options = Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let service = CodexBridgeService()

        do {
            try await service.start()
        } catch {
            FileHandle.standardError.write(Data("无法启动 Codex 桥接器：\(error.localizedDescription)\n".utf8))
            return
        }

        if let prompt = options.prompt {
            do {
                let threadID = try await service.startTask(
                    prompt: prompt,
                    workingDirectory: options.workingDirectory
                )
                print("已启动受 Apple Watch 控制的 Codex 任务：\(threadID)")
            } catch {
                FileHandle.standardError.write(Data("任务启动失败：\(error.localizedDescription)\n".utf8))
            }
        }

        if options.once {
            let snapshot = await service.snapshot()
            if let data = try? CodexWatchCoding.makeEncoder().encode(snapshot),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            await service.stop()
            return
        }

        let transport = MacPeerTransport()
        transport.start(
            snapshotProvider: { await service.snapshot() },
            decisionHandler: { decision in try await service.submit(decision) },
            commandHandler: { command in try await service.send(command) },
            usageResetHandler: { request in try await service.consumeResetCredit(request) },
            historyHandler: { request in try await service.history(request) },
            commandRecoveryHandler: { command in await service.confirmsAcceptedCommand(command) }
        )

        print("Codex Watch Bridge 已运行")
        print("iPhone 自动可信连接已开启")
        print("按 Control-C 停止")

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            await service.refresh()
            transport.broadcast(await service.snapshot())
        }

        transport.stop()
        await service.stop()
    }
}

private struct Options {
    var prompt: String?
    var workingDirectory = FileManager.default.currentDirectoryPath
    var once = false

    init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--run" where index + 1 < arguments.count:
                prompt = arguments[index + 1]
                index += 2
            case "--cwd" where index + 1 < arguments.count:
                workingDirectory = arguments[index + 1]
                index += 2
            case "--once":
                once = true
                index += 1
            default:
                index += 1
            }
        }
    }
}
