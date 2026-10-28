import ActivityKit
import SwiftUI
import WidgetKit
import CodexWatchCore

@main
struct CodexLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        CodexTaskLiveActivity()
    }
}

struct CodexTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodexTaskActivityAttributes.self) { context in
            TaskActivityContentView(state: context.state)
                // nil restores the system's readable light/dark background;
                // clear made the text appear painted over the watch face.
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TaskActivityStatusIcon(state: context.state).font(.body)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let progress = TaskLiveActivityPolicy.progress(context.state.progress) {
                        ProgressView(value: progress).tint(.cyan)
                    } else {
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } compactLeading: {
                TaskActivityStatusIcon(state: context.state)
            } compactTrailing: {
                TaskActivityProgressText(state: context.state)
            } minimal: {
                TaskActivityStatusIcon(state: context.state)
            }
            .keylineTint(.cyan)
        }
        .supplementalActivityFamilies([.small, .medium])
    }

}

/// Environment values must be read by the rendered View, not the Widget
/// configuration. Otherwise the Watch can receive the medium iPhone layout.
private struct TaskActivityContentView: View {
    @Environment(\.activityFamily) private var activityFamily
    let state: CodexTaskActivityAttributes.ContentState

    var body: some View {
        if activityFamily == .small {
            HStack(alignment: .center, spacing: 8) {
                TaskActivityStatusIcon(state: state)
                    .font(.body)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(TaskLiveActivityPolicy.title(state.title))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    HStack(spacing: 4) {
                        Text(state.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        TaskActivityProgressText(state: state)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 12) {
                TaskActivityStatusIcon(state: state)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(TaskLiveActivityPolicy.title(state.title))
                        .font(.headline)
                        .lineLimit(2)
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let progress = TaskLiveActivityPolicy.progress(state.progress) {
                        ProgressView(value: progress)
                            .tint(.cyan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if state.pendingApprovalCount > 0 {
                    Label("\(state.pendingApprovalCount)", systemImage: "checkmark.shield.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
        }
    }
}

private struct TaskActivityStatusIcon: View {
    let state: CodexTaskActivityAttributes.ContentState
    var body: some View {
        Image(systemName: state.pendingApprovalCount > 0 ? "exclamationmark.shield.fill" : "sparkles")
            .foregroundStyle(state.pendingApprovalCount > 0 ? .orange : .cyan)
    }
}

private struct TaskActivityProgressText: View {
    let state: CodexTaskActivityAttributes.ContentState
    var body: some View {
        if let progress = TaskLiveActivityPolicy.progress(state.progress) {
            Text("\(Int(progress * 100))%")
                .font(.caption2.bold().monospacedDigit())
        } else {
            Image(systemName: "ellipsis")
        }
    }
}

#Preview("Task status", as: .content, using: CodexTaskActivityAttributes(taskID: "layout-preview")) {
    CodexTaskLiveActivity()
} contentStates: {
    CodexTaskActivityAttributes.ContentState(
        title: "控制 Apple Watch GPT · 实时活动布局验证",
        detail: "运行中", progress: nil, state: "running",
        pendingApprovalCount: 0, updatedAt: .now
    )
    CodexTaskActivityAttributes.ContentState(
        title: "A long task title that must stay inside the activity card",
        detail: "Running", progress: 0.68, state: "running",
        pendingApprovalCount: 0, updatedAt: .now
    )
    CodexTaskActivityAttributes.ContentState(
        title: "等待批准 · Review requested permissions",
        detail: "Waiting for approval", progress: nil, state: "waitingForApproval",
        pendingApprovalCount: 2, updatedAt: .now
    )
}
