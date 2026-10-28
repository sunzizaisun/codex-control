import SwiftUI
import CodexWatchCore

@main
struct CodexRelayApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UIPreview") && args.contains("-QAResetPreferences") {
            // Reset only display preferences in the QA simulator. Unlike
            // launch-default overrides, these remain editable by the UI.
            UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppPreferenceKeys.language)
            UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppPreferenceKeys.appearance)
        }
        #endif
    }
    @StateObject private var relay = PhoneRelayController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppAppearanceRoot {
                previewContent
                .task { if !previewingDots { relay.start() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && !previewingDots { relay.resumeConnectivity() }
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
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewNewCodex") {
            NavigationStack {
                PhoneNewCodexView(relay: relay)
            }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewTaskDetail"),
           let task = relay.snapshot.tasks.first(where: { $0.id == "preview-recent" }) {
            NavigationStack {
                PhoneTaskDetailView(task: task, relay: relay)
            }
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewSettings") {
            PhoneSettingsView()
        } else if ProcessInfo.processInfo.arguments.contains("-PreviewApprovalDetail"),
           let request = relay.snapshot.pendingApprovals.first {
            NavigationStack {
                ScrollView {
                    ApprovalSummaryRow(request: request, relay: relay)
                        .padding(16)
                }
                .background(CodexBackdrop())
                .navigationTitle(AppLocalizer.text("审批"))
                .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            PhoneDashboardView(relay: relay)
        }
    }

}
