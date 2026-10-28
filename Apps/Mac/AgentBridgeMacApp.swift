import SwiftUI
import CodexWatchCore

@main
struct AgentBridgeMacApp: App {
    @StateObject private var model = MacBridgeViewModel()

    var body: some Scene {
        Window("Codex Control", id: "control") {
            AppAppearanceRoot {
                MacBridgeMenuView(model: model)
                    .frame(minWidth: 380, minHeight: 560)
                    .task { model.start() }
            }
        }
        .defaultSize(width: 380, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            AppAppearanceRoot {
                MacBridgeMenuView(model: model)
                    .frame(width: 380, height: 560)
                    .task { model.start() }
            }
        } label: {
            Label("Codex Watch", systemImage: model.snapshot.pendingApprovals.isEmpty ? "applewatch" : "exclamationmark.applewatch")
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
