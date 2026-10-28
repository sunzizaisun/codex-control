import Foundation

public extension DashboardSnapshot {
    /// Relay snapshots are intentionally compact and can briefly omit a
    /// recently visible task while the Mac is refreshing or while a second
    /// device publishes a smaller projection. Keep a bounded recent window
    /// stable so companion lists do not make rows disappear and reappear
    /// during a crown/scroll gesture. The incoming snapshot remains
    /// authoritative for task fields that are present.
    func mergingRecentTasks(
        from previous: DashboardSnapshot,
        now: Date = Date(),
        retention: TimeInterval = 20 * 60,
        maximumRetainedTasks: Int = 12
    ) -> DashboardSnapshot {
        let incomingByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, next in
            next.updatedAt >= first.updatedAt ? next : first
        })
        var merged: [AgentTask] = []
        var seen = Set<String>()

        // Preserve the order already on screen. This prevents a compact
        // heartbeat from reordering rows simply because its task array was
        // serialized in a different order.
        for oldTask in previous.tasks {
            guard !seen.contains(oldTask.id), let incoming = incomingByID[oldTask.id] else { continue }
            merged.append(mergeTask(incoming, with: oldTask))
            seen.insert(incoming.id)
        }

        for incoming in tasks where !seen.contains(incoming.id) {
            merged.append(normalizedTask(incomingByID[incoming.id] ?? incoming))
            seen.insert(incoming.id)
        }

        let retained = previous.tasks.filter { oldTask in
            !seen.contains(oldTask.id)
                && now.timeIntervalSince(oldTask.updatedAt) >= -60
                && now.timeIntervalSince(oldTask.updatedAt) < retention
        }
        var retainedCount = 0
        for var oldTask in retained where !seen.contains(oldTask.id) {
            guard retainedCount < max(0, maximumRetainedTasks) else { break }
            // Keep the row/history stable, but a missing current projection
            // cannot establish that an old turn is still running or waiting.
            if oldTask.isInProgress {
                oldTask.state = .unknown
                oldTask.awaitingUserInput = nil
                oldTask.activeTurnID = nil
                oldTask.progress = nil
            }
            merged.append(normalizedTask(oldTask))
            seen.insert(oldTask.id)
            retainedCount += 1
        }

        var result = self
        result.tasks = merged
        return result
    }

    /// Transport heartbeats update `capturedAt` and message timestamps even
    /// when nothing visible changed. Companion lists should compare the
    /// rendered fields instead of replacing their data source on every poll;
    /// otherwise SwiftUI/watchOS can restart row animations while the user is
    /// scrolling with the Digital Crown.
    func isVisuallyEquivalent(to other: DashboardSnapshot) -> Bool {
        guard bridgeConnected == other.bridgeConnected,
              models == other.models,
              sameUsage(usage, other.usage),
              pendingApprovals == other.pendingApprovals,
              tasks.count == other.tasks.count else {
            return false
        }
        return zip(tasks, other.tasks).allSatisfy { sameTask($0, $1) }
    }

    private func sameUsage(_ lhs: UsageSnapshot?, _ rhs: UsageSnapshot?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(left), .some(right)):
            return left.plan == right.plan
                && left.primary == right.primary
                && left.secondary == right.secondary
                && left.creditsBalance == right.creditsBalance
                && left.resetCreditsAvailable == right.resetCreditsAvailable
                && left.resetCredits == right.resetCredits
                && left.todayTokens == right.todayTokens
                && left.monthlyLimit == right.monthlyLimit
                && left.spendControlReached == right.spendControlReached
        default:
            return false
        }
    }

    private func sameTask(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.state == rhs.state
            && lhs.model == rhs.model
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.awaitingUserInput == rhs.awaitingUserInput
            && lhs.workspace == rhs.workspace
            && lhs.progress == rhs.progress
            && lhs.activeTurnID == rhs.activeTurnID
            && lhs.isNativeChat == rhs.isNativeChat
            && lhs.isChat == rhs.isChat
            && lhs.isBridgeManaged == rhs.isBridgeManaged
            && lhs.messages.count == rhs.messages.count
            && zip(lhs.messages, rhs.messages).allSatisfy {
                $0.0.id == $0.1.id
                    && $0.0.role == $0.1.role
                    && $0.0.text == $0.1.text
                    && $0.0.isStreaming == $0.1.isStreaming
            }
    }

    private func mergeTask(_ incoming: AgentTask, with previous: AgentTask) -> AgentTask {
        var task = incoming
        // Native Chat projections are complete ordered transcripts. A local
        // queued draft may use a command UUID instead of the desktop message
        // IDs, so only use it when the incoming projection has no messages.
        if incoming.isNativeChat {
            task.messages = incoming.messages.isEmpty ? previous.messages : incoming.messages
            return normalizedTask(task)
        }

        var messagesByID = Dictionary(previous.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var known = Set<String>()
        var orderedIDs = previous.messages.map(\.id).filter { known.insert($0).inserted }
        for message in incoming.messages {
            if messagesByID[message.id] == nil { orderedIDs.append(message.id) }
            messagesByID[message.id] = message
        }
        task.messages = orderedIDs.compactMap { messagesByID[$0] }.suffix(30).map { $0 }
        return task
    }

    private func normalizedTask(_ original: AgentTask) -> AgentTask {
        var task = original
        let byID = Dictionary(task.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        task.messages = task.messages.compactMap { seen.insert($0.id).inserted ? byID[$0.id] : nil }
        return task
    }
}
