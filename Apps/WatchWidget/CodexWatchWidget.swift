import CodexWatchCore
import SwiftUI
import WidgetKit

@main
struct CodexWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexStatusWidget()
    }
}

private struct CodexStatusWidget: Widget {
    private let kind = "CodexWatchStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
            CodexStatusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WatchWidgetBackground()
                }
        }
        .configurationDisplayName(WidgetText.status)
        .description(WidgetText.description)
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct CodexTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: DashboardSnapshot
    let relevance: TimelineEntryRelevance?
    let isCached: Bool
    let diagnostic: String?
}

private struct LoadedWidgetSnapshot {
    let snapshot: DashboardSnapshot
    let isCached: Bool
    let diagnostic: String?
}

/// Widget extensions are granted short, system-managed execution windows.
/// Retain the last verified relay response in the extension container so a
/// temporary background-network delay never replaces useful status with
/// "Mac Offline". The next timeline request still attempts a live refresh.
private enum WidgetSnapshotCache {
    private static let key = "CodexWatchWidget.lastVerifiedSnapshot"
    private static let maxAge: TimeInterval = 6 * 60 * 60

    static func save(_ snapshot: DashboardSnapshot) {
        guard let data = try? CodexWatchCoding.makeEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> DashboardSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? CodexWatchCoding.makeDecoder().decode(DashboardSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.capturedAt) <= maxAge else {
            return nil
        }
        return snapshot
    }
}

private struct CodexTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexTimelineEntry {
        makeEntry(snapshot: .uiPreview(english: WidgetText.isEnglish), date: Date(), isCached: false, diagnostic: nil)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (CodexTimelineEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        load(completion: completion)
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<CodexTimelineEntry>) -> Void
    ) {
        load { entry in
            var entries = [entry]
            if entry.snapshot.isMacOnline(now: entry.date) {
                let expiry = entry.snapshot.capturedAt.addingTimeInterval(RelayTimingPolicy.snapshotFreshness + 0.1)
                entries.append(makeEntry(snapshot: entry.snapshot.reconcilingMacPresence(now: expiry),
                    date: expiry, isCached: true, diagnostic: nil))
            }
            completion(
                Timeline(
                    entries: entries,
                    policy: .after(Date().addingTimeInterval(refreshInterval(for: entry.snapshot)))
                )
            )
        }
    }

    private func load(completion: @escaping (CodexTimelineEntry) -> Void) {
        let completion = TimelineCompletion(completion)
        Task {
            let result = await loadRemoteSnapshot()
            completion.call(makeEntry(snapshot: result.snapshot, date: Date(), isCached: result.isCached, diagnostic: result.diagnostic))
        }
    }

    private func loadRemoteSnapshot() async -> LoadedWidgetSnapshot {
        guard let configuration = RemoteRelayConfiguration.fromMainBundle() else {
            return cachedOrEmpty(diagnostic: "Missing relay configuration")
        }

        do {
            // Widgets have a tightly bounded execution window.  Waiting for a
            // connection here can leave the Smart Stack with an old offline
            // timeline until the full Watch app is opened.  Make one quick,
            // independent relay request instead; WidgetKit will ask again at
            // the next timeline update if the network is temporarily asleep.
            let client = RemoteRelayClient(
                configuration: configuration,
                requestTimeout: 8,
                waitsForConnectivity: false
            )
            guard let envelope = try await client.latestSnapshot() else {
                return cachedOrEmpty(diagnostic: "Relay has no snapshot")
            }
            guard envelope.kind == .snapshot, let snapshot = envelope.snapshot else {
                return cachedOrEmpty(diagnostic: "Relay returned invalid snapshot")
            }
            let age = Date().timeIntervalSince(envelope.sentAt)
            guard RelayTimingPolicy.isFresh(envelope.sentAt), RelayTimingPolicy.isFresh(snapshot.capturedAt) else {
                return cachedOrEmpty(diagnostic: "Snapshot is \(Int(max(0, age)))s old")
            }
            WidgetSnapshotCache.save(snapshot)
            return LoadedWidgetSnapshot(snapshot: snapshot.reconcilingMacPresence(), isCached: false, diagnostic: nil)
        } catch {
            return cachedOrEmpty(diagnostic: error.localizedDescription)
        }
    }

    private func cachedOrEmpty(diagnostic: String) -> LoadedWidgetSnapshot {
        if let cached = WidgetSnapshotCache.load() {
            return LoadedWidgetSnapshot(snapshot: cached.reconcilingMacPresence(), isCached: true, diagnostic: nil)
        }
        return LoadedWidgetSnapshot(snapshot: .empty, isCached: false, diagnostic: diagnostic)
    }

    private func makeEntry(snapshot: DashboardSnapshot, date: Date, isCached: Bool, diagnostic: String?) -> CodexTimelineEntry {
        let pending = snapshot.pendingApprovals.lazy.filter { !$0.isExpired }.count
        // Smart Stack ultimately decides what to surface, but a connected
        // bridge should remain relevant enough to be suggested.  Active work
        // and approvals receive the maximum relevance for the whole current
        // timeline window, so an urgent request can surface promptly.
        let score: Float
        let duration: TimeInterval
        if pending > 0 {
            score = 100
            duration = 60 * 60
        } else if snapshot.activeTaskCount > 0 {
            score = 100
            duration = 30 * 60
        } else if snapshot.bridgeConnected {
            score = 80
            duration = 10 * 60
        } else {
            score = 0
            duration = 0
        }
        return CodexTimelineEntry(
            date: date,
            snapshot: snapshot,
            relevance: TimelineEntryRelevance(score: score, duration: duration),
            isCached: isCached,
            diagnostic: diagnostic
        )
    }

    private func refreshInterval(for snapshot: DashboardSnapshot) -> TimeInterval {
        let hasApproval = snapshot.pendingApprovals.contains { !$0.isExpired }
        if hasApproval { return 60 }
        if snapshot.activeTaskCount > 0 { return 120 }
        return 600
    }
}

private final class TimelineCompletion: @unchecked Sendable {
    private let completion: (CodexTimelineEntry) -> Void

    init(_ completion: @escaping (CodexTimelineEntry) -> Void) {
        self.completion = completion
    }

    func call(_ entry: CodexTimelineEntry) {
        completion(entry)
    }
}

private struct CodexStatusWidgetView: View {
    let entry: CodexTimelineEntry

    private var pendingApprovals: [ApprovalRequest] {
        entry.snapshot.pendingApprovals.filter { !$0.isExpired }
    }

    private var primaryTask: AgentTask? {
        let visibleTasks = entry.snapshot.tasks.filter {
            !$0.isChat && !$0.isNativeChat && AgentTaskPresentation.isVisible($0)
        }
        return visibleTasks.first(where: { $0.state == .waitingForApproval })
            ?? visibleTasks.first(where: { $0.state == .running })
            ?? visibleTasks.first
    }

    var body: some View {
        HStack(spacing: 9) {
            statusSymbol
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(heading)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let progress = TaskLiveActivityPolicy.progress(primaryTask?.progress) {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.cyan)
                    }
                }

                Text(mainText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if let progress = TaskLiveActivityPolicy.progress(primaryTask?.progress), pendingApprovals.isEmpty {
                    ProgressView(value: progress)
                        .tint(.cyan)
                } else {
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if !pendingApprovals.isEmpty {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        } else if entry.snapshot.activeTaskCount > 0 {
            Image(systemName: "sparkles")
                .foregroundStyle(.cyan)
        } else if entry.snapshot.bridgeConnected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var heading: String {
        if !pendingApprovals.isEmpty {
            return WidgetText.approval
        }
        if entry.snapshot.activeTaskCount > 0 {
            return WidgetText.running
        }
        return WidgetText.status
    }

    private var mainText: String {
        if entry.diagnostic != nil {
            return WidgetText.relayUnavailable
        }
        if let approval = pendingApprovals.first {
            return approval.title
        }
        if let task = primaryTask {
            return task.title
        }
        return entry.snapshot.bridgeConnected ? WidgetText.noActiveTask : WidgetText.offline
    }

    private var detailText: String {
        if let diagnostic = entry.diagnostic {
            return diagnostic
        }
        if entry.isCached {
            return WidgetText.cached
        }
        if pendingApprovals.count > 1 {
            return WidgetText.approvalCount(pendingApprovals.count)
        }
        if let approval = pendingApprovals.first {
            return approval.summary
        }
        if let task = primaryTask {
            return AgentTaskPresentation.detail(task.detail) ?? WidgetText.updated
        }
        return WidgetText.openApp
    }
}

private struct WatchWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark
                ? [
                    Color(red: 0.04, green: 0.10, blue: 0.14),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                ]
                : [
                    Color(red: 0.90, green: 0.97, blue: 1.0),
                    Color(red: 0.96, green: 0.92, blue: 1.0),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private enum WidgetText {
    static var language: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKeys.language)
        return AppLanguage(rawValue: raw ?? "") ?? .system
    }
    static var isEnglish: Bool { language.resolvesToEnglish }
    private static func text(_ key: String) -> String { AppLocalizer.text(key, language: language) }

    static var status: String { "Codex " + text("状态") }
    static var description: String { text("最近任务") + " · " + text("处理审批") }
    static var approval: String { text("等待批准") }
    static var running: String { text("运行中") }
    static var noActiveTask: String { text("暂无受控任务") }
    static var offline: String { text("Mac 未连接") }
    static var updated: String { text("刚刚") }
    static var openApp: String { text("Codex 控制") }
    static var cached: String { text("上次确认的状态") }
    static var relayUnavailable: String { text("中继不可用") }

    static func approvalCount(_ count: Int) -> String {
        "\(count) · " + text("等待批准")
    }
}

#Preview(as: .accessoryRectangular) {
    CodexStatusWidget()
} timeline: {
    CodexTimelineEntry(
        date: .now,
        snapshot: .uiPreview(english: WidgetText.isEnglish),
        relevance: TimelineEntryRelevance(score: 100),
        isCached: false,
        diagnostic: nil
    )
}
