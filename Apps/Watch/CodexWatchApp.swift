import SwiftUI
import CodexWatchCore
import WatchKit

@main
struct CodexWatchApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UIPreview") && args.contains("-QAResetPreferences") {
            UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppPreferenceKeys.language)
            UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppPreferenceKeys.appearance)
        }
        #endif
    }
    @WKApplicationDelegateAdaptor(CodexWatchApplicationDelegate.self) private var applicationDelegate
    @StateObject private var relay = WatchRelayController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppAppearanceRoot {
                previewContent
                .task {
                    guard !previewingDots else { return }
                    relay.start()
                    relay.setForegroundActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    if !previewingDots { relay.setForegroundActive(phase == .active) }
                }
                .task {
                    guard !previewingDots else { return }
                    WatchBackgroundRefreshCoordinator.shared.install { task in
                        relay.performBackgroundRefresh(task)
                    }
                }
            }
        }
    }

    private var previewSharedDot: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-PreviewDotsShared")
        #else
        false
        #endif
    }
    private var previewingDots: Bool { previewSharedDot || ProcessInfo.processInfo.arguments.contains("-PreviewDots") }

    @ViewBuilder
    private var previewContent: some View {
        if previewSharedDot {
            NavigationStack { DotsConversationView() }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewDots") {
            NavigationStack { DotsConversationView(thread: "11111111-1111-4111-8111-111111111111") }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewSettings") {
            NavigationStack { WatchSettingsView() }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewNewCodex") {
            NavigationStack { WatchNewCodexView(relay: relay) }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewApprovalDetail"),
           let request = relay.snapshot.pendingApprovals.first {
            NavigationStack {
                WatchApprovalDetail(request: request, relay: relay)
            }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewTaskDetail"),
           let task = relay.snapshot.tasks.first(where: { $0.id == "preview-recent" }) {
            NavigationStack {
                WatchTaskDetailView(task: task, relay: relay)
            }
        } else {
            WatchDashboardView(relay: relay)
        }
    }

}
