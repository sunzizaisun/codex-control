import SwiftUI
import VisionKit
import CodexWatchCore

struct PhoneDashboardView: View {
    @ObservedObject var relay: PhoneRelayController
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @State private var showsSettings = false
    @State private var showsNewCodex = false
    @State private var showsPairing = false
    @State private var selectedTab = 0

    var body: some View {
        let _ = languageRaw
        TabView(selection: $selectedTab) {
            dashboard
                .tag(0)
                .tabItem { Label(AppLocalizer.text("状态"), systemImage: "sparkles.rectangle.stack") }

            approvals
                .tag(1)
                .badge(relay.unexpiredApprovals.count)
                .tabItem { Label(AppLocalizer.text("审批"), systemImage: "checkmark.shield") }

        }
        .tint(.cyan)
        .onReceive(relay.$selectedNotificationRequestID) { if $0 != nil { selectedTab = 1 } }
        .sheet(isPresented: Binding(get: { relay.selectedNotificationRequestID != nil }, set: { if !$0 { relay.selectedNotificationRequestID = nil } })) {
            NavigationStack {
                ScrollView {
                    switch InteractionDestination.resolve(requestID: relay.selectedNotificationRequestID,
                        pending: relay.snapshot.pendingApprovals,
                        receipt: relay.decisionReceipts.result(for: relay.selectedNotificationRequestID)) {
                    case .request(let request):
                        ApprovalSummaryRow(request: request, relay: relay).id(request.id).padding(16)
                    case .receipt(let receipt):
                        InteractionReceiptView(receipt: receipt, pending: false).padding(16)
                    case .unavailable:
                        Text(AppLocalizer.text("审批请求已不再等待处理。")).padding()
                    }
                }
                .navigationTitle(AppLocalizer.text("待处理"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalizer.text("完成")) { relay.selectedNotificationRequestID = nil } } }
            }
        }
        // AppLocalizer reads the shared preference synchronously. The
        // explicit dependency below makes the whole tab tree rebuild when
        // language changes in Settings, including views already mounted.
        .sheet(isPresented: $showsSettings) {
            PhoneSettingsView()
        }
        .sheet(isPresented: $showsNewCodex) {
            NavigationStack {
                PhoneNewCodexView(relay: relay)
            }
        }
        .sheet(isPresented: $showsPairing) {
            PhonePairingView(relay: relay)
        }
    }

    private var dashboard: some View {
        NavigationStack {
            ZStack {
                CodexBackdrop()
                ScrollView {
                    VStack(spacing: 16) {
                        NavigationLink {
                            PhoneUsageResetView(relay: relay)
                        } label: {
                            heroCard
                        }
                        .buttonStyle(.plain)
                        connectionCard
                        NavigationLink { DotsConversationView(resumeLastConversation: true) } label: {
                            HStack {
                                Label("dot", systemImage: "circle.inset.filled").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .codexGlassCard(tint: .cyan)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        tasksCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .refreshable { relay.requestLatestSnapshot() }
            }
            .navigationTitle(AppLocalizer.text("Codex 控制"))
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsNewCodex = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    private var approvals: some View {
        NavigationStack {
            ZStack {
                CodexBackdrop()
                if relay.unexpiredApprovals.isEmpty {
                    ContentUnavailableView(
                        AppLocalizer.text("全部处理完了"),
                        systemImage: "checkmark.shield.fill"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(relay.unexpiredApprovals) { request in
                                ApprovalSummaryRow(request: request, relay: relay)
                                    .codexGlassCard(tint: .orange)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(AppLocalizer.text("待审批"))
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var visibleRecentTasks: [AgentTask] {
        relay.snapshot.tasks
            .filter { !$0.isChat && !$0.isNativeChat && AgentTaskPresentation.isVisible($0) }
    }

    private var heroCard: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(.primary.opacity(0.10), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: remainingFraction)
                    .stroke(
                        AngularGradient(colors: [.cyan, .blue, .purple, .cyan], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(UsagePresentation.remainingText(relay.snapshot.usage?.primary))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(AppLocalizer.text("剩余"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 7) {
                Label(AppLocalizer.text("Token 余额"), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.title3.bold())
                Text(relay.snapshot.usage?.plan?.uppercased() ?? "CODEX")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                if let reset = verifiedResetDate {
                    HStack(spacing: 4) {
                        Text(AppLocalizer.text("下次重置"))
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(AppLocalizer.relativeTime(to: reset, from: context.date))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(AppLocalizer.text("等待额度同步"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let credits = relay.snapshot.usage?.resetCreditsAvailable {
                    Label(AppLocalizer.format("可重置 %@ 次", String(credits)), systemImage: "arrow.counterclockwise.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Label(AppLocalizer.text("额度与重置"), systemImage: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .codexGlassCard(tint: .cyan)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(AppLocalizer.text("设备连接"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                connectionPill
            }

            HStack(spacing: 12) {
                deviceStatus(icon: "desktopcomputer", title: "Mac", connected: relay.isMacConnected)
                    .frame(maxWidth: .infinity)
                deviceStatus(icon: "applewatch", title: AppLocalizer.text("手表"), connected: relay.watchReachable)
                    .frame(maxWidth: .infinity)
            }

            if !relay.isMacConnected {
                Picker(AppLocalizer.text("选择 Mac"), selection: $relay.selectedMacName) {
                    if relay.discoveredMacNames.isEmpty {
                        Text(AppLocalizer.text("正在搜索…")).tag("")
                    }
                    ForEach(relay.discoveredMacNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)

                TextField(AppLocalizer.text("Mac 动态配对码（首次连接）"), text: $relay.pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .fontDesign(.monospaced)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                Button { relay.connectToSelectedMac() } label: {
                    Label(AppLocalizer.text("立即连接"), systemImage: "bolt.horizontal.circle")
                        .frame(maxWidth: .infinity)
                }
                .codexPrimaryButton()
                .tint(.cyan)
                .disabled(relay.selectedMacName.isEmpty)

                Label(AppLocalizer.text("首次输入 Mac 显示的动态码；以后会自动重连"), systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if let received = relay.lastSnapshotReceivedAt {
                            Text(AppLocalizer.format(
                                "同步时间 %@",
                                AppLocalizer.relativeTime(to: received, from: context.date)
                            ))
                            .font(.caption)
                            .foregroundStyle(relay.isSnapshotStale ? .orange : .secondary)
                        }
                    }
                    Label(AppLocalizer.text("自动保持连接"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Button { showsPairing = true } label: {
                Label(AppLocalizer.text("选择 Mac"), systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .codexGlassButton()

            if let error = relay.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .codexGlassCard(tint: relay.isMacConnected ? .green : .orange)
    }

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(AppLocalizer.text("最近任务"), systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("\(visibleRecentTasks.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.08), in: Capsule())
            }

            if visibleRecentTasks.isEmpty {
                Label(AppLocalizer.text("暂无受控任务"), systemImage: "moon.stars")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array((visibleRecentTasks.filter(\.isInProgress) + visibleRecentTasks.filter { !$0.isInProgress }.prefix(8)).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider().overlay(.primary.opacity(0.08)) }
                    NavigationLink {
                        PhoneTaskDetailView(task: task, relay: relay)
                    } label: {
                        taskRow(task)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Make the entire visual task row an obvious, generous hit target.
                    // Without an explicit full-width label, SwiftUI can reduce the
                    // tappable area to whichever subview reports an intrinsic size.
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("task.row.\(task.id)")
                }
            }
        }
        .codexGlassCard(tint: .purple)
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(taskColor(task.state).gradient)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(verbatim: task.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Spacer()
                    Text(AppLocalizer.text(task.awaitingUserInput == true ? "等待你的回复" : taskLabel(task.state))).font(.caption2).foregroundStyle(taskColor(task.state))
                }
                if let progress = task.progress {
                    ProgressView(value: progress).tint(taskColor(task.state))
                }
                if let detail = AgentTaskPresentation.detail(task.detail) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(relay.isMacConnected ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(relay.connectionTitle)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.08), in: Capsule())
    }

    private func deviceStatus(icon: String, title: String, connected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(connected ? .cyan : .secondary)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(connected ? .green : .secondary)
        }
        .padding(11)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var remainingFraction: Double {
        UsagePresentation.remainingFraction(relay.snapshot.usage?.primary)
    }

    private var verifiedResetDate: Date? {
        guard let usage = relay.snapshot.usage,
              Date().timeIntervalSince(usage.capturedAt) < 15 * 60,
              let reset = usage.primary?.resetsAt,
              reset > Date(),
              reset.timeIntervalSinceNow < 8 * 24 * 60 * 60 else {
            return nil
        }
        return reset
    }

    private func taskColor(_ state: AgentTask.State) -> Color {
        switch state {
        case .running: .green
        case .waitingForApproval: .orange
        case .failed: .red
        case .completed: .cyan
        case .idle, .unknown: .secondary
        }
    }

    private func taskLabel(_ state: AgentTask.State) -> String {
        switch state {
        case .running: "运行中"
        case .waitingForApproval: "等待批准"
        case .idle: "空闲"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "未知"
        }
    }
}

private struct PhonePairingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: PhoneRelayController
    @State private var isConnecting = false
    @State private var showsQRScanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                CodexBackdrop()
                VStack(alignment: .leading, spacing: 16) {
                    Label(AppLocalizer.text("配对 iPhone"), systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.title3.bold())

                    Picker(AppLocalizer.text("选择 Mac"), selection: $relay.selectedMacName) {
                        if relay.discoveredMacNames.isEmpty {
                            Text(AppLocalizer.text("正在搜索…")).tag("")
                        }
                        ForEach(relay.discoveredMacNames, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)

                    TextField(AppLocalizer.text("Mac 动态配对码（首次连接）"), text: $relay.pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .fontDesign(.monospaced)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                    if DataScannerViewController.isSupported {
                        Button {
                            showsQRScanner = true
                        } label: {
                            Label(AppLocalizer.text("扫描二维码"), systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .codexGlassButton()
                    }

                    Button {
                        isConnecting = relay.connectToSelectedMac()
                    } label: {
                        Label(
                            AppLocalizer.text(isConnecting ? "正在连接…" : "立即连接"),
                            systemImage: "bolt.horizontal.circle"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .codexPrimaryButton()
                    .tint(.cyan)
                    .disabled(isConnecting || relay.selectedMacName.isEmpty || relay.pairingCode.count != 6)

                    if isConnecting {
                        Label(relay.macConnectionState.title, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let error = relay.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text(AppLocalizer.text("首次输入 Mac 显示的动态码；以后会自动重连"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle(AppLocalizer.text("配对 iPhone"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalizer.text("取消")) { dismiss() }
                }
            }
        }
        .onAppear { relay.beginPairing() }
        .sheet(isPresented: $showsQRScanner) {
            PhonePairingQRCodeScanner { payload in
                relay.applyPairingQRCode(payload)
                showsQRScanner = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: relay.macConnectionState) { _, state in
            if state.isConnected { dismiss() }
            if case .disconnected = state { isConnecting = false }
        }
    }
}

private struct PhonePairingQRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var handled = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !handled,
                  let code = addedItems.compactMap({ item -> String? in
                      guard case let .barcode(barcode) = item else { return nil }
                      return barcode.payloadStringValue
                  }).first else { return }
            handled = true
            dataScanner.stopScanning()
            onCode(code)
        }
    }
}

struct PhoneTaskDetailView: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    let task: AgentTask
    @ObservedObject var relay: PhoneRelayController
    @State private var draft = MessageDraft()
    @State private var modelSelection = CodexModelSelection()
    @State private var reviewedOriginal: RecoverableCommandDraft?

    private var currentTask: AgentTask { relay.task(id: task.id) ?? task }
    private var history: TaskHistoryState? { relay.taskHistories[task.id] }
    private var messages: [ChatMessage] { history?.hasLoaded == true ? history!.messages : currentTask.messages }

    init(task: AgentTask, relay: PhoneRelayController) {
        self.task = task; self.relay = relay
        _draft = State(initialValue: relay.initialCommandDraft(for: task.id))
    }

    var body: some View {
        let recoverable = relay.recoverableCommand(for: task.id)
        let separateReview = recoverable.map(draft.needsSeparateReview) ?? false
        ZStack {
            CodexBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: stateSymbol)
                                .font(.title2)
                                .foregroundStyle(stateColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: currentTask.title)
                                    .font(.title3.bold())
                                Text(AppLocalizer.text(stateLabel))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(stateColor)
                            }
                            Spacer()
                        }
                        if let progress = currentTask.progress {
                            ProgressView(value: progress)
                                .tint(stateColor)
                        }
                        Label {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(AppLocalizer.relativeTime(to: currentTask.updatedAt, from: context.date))
                            }
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .codexGlassCard(tint: stateColor)

                    VStack(alignment: .leading, spacing: 10) {
                        if history?.isLoading == true {
                            ProgressView(AppLocalizer.text("正在加载…"))
                        } else if let error = history?.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button(AppLocalizer.text("重试")) { relay.loadHistory(for: task.id, refresh: true) }
                        } else if history?.hasMore == true {
                            Button(AppLocalizer.text("加载较早的消息")) { relay.loadHistory(for: task.id, older: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !messages.isEmpty {
                        ChatTranscriptView(messages: messages)
                            .codexGlassCard(tint: .indigo)
                    }

                    if currentTask.detail != nil || currentTask.model != nil || currentTask.workspace != nil {
                        VStack(alignment: .leading, spacing: 12) {
                        Label(AppLocalizer.text("任务详情"), systemImage: "doc.text.magnifyingglass")
                                .font(.headline)
                            if let detail = AgentTaskPresentation.detail(currentTask.detail) {
                                detailRow(title: AppLocalizer.text("当前进度"), value: detail, monospaced: false)
                            }
                            if let model = currentTask.model, !model.isEmpty {
                                detailRow(title: AppLocalizer.text("模型"), value: model, monospaced: true)
                            }
                            if let workspace = AgentTaskPresentation.workspace(currentTask.workspace) {
                                detailRow(title: AppLocalizer.text("工作目录"), value: workspace, monospaced: true)
                            }
                        }
                        .codexGlassCard(tint: .purple)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label(AppLocalizer.text("继续对话"), systemImage: "text.bubble.fill")
                            .font(.headline)
                        CodexModelPicker(models: relay.snapshot.models, selection: $modelSelection, preferredModel: currentTask.model, preferredEffort: currentTask.reasoningEffort, preservesCurrentSettings: true, isRunning: currentTask.isInProgress)
                        TextField(AppLocalizer.text("输入消息"), text: $draft.text, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("task.messageInput")
                            .padding(12)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

                        Button {
                            draft.submitted(relay.sendCommand(draft.text, to: currentTask, options: currentTask.isInProgress ? nil : modelSelection.options(in: relay.snapshot.models, onlyWhenSelected: true)))
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                Text(AppLocalizer.text(
                                    relay.pendingCommandTaskIDs.contains(currentTask.id) ? "正在发送…" : "发送"
                                ))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .codexPrimaryButton()
                        .accessibilityIdentifier("task.send")
                        .disabled(
                            !relay.commandStorageAvailable
                            || recoverable != nil
                            || relay.pendingCommandTaskIDs.contains(currentTask.id)
                            || draft.submissionID != nil
                            || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        if let error = draft.displayedError(language: AppLanguage(rawValue: languageRaw) ?? .system) {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                        if !relay.commandStorageAvailable, draft.errorMessage == nil {
                            Text(AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !relay.commandStorageAvailable {
                            Button(AppLocalizer.text("重试")) { relay.retryCommandStorage() }
                                .frame(minHeight: 44).accessibilityIdentifier("command.storage.retry")
                        }
                        CommandStorageRepairControls(canRepair: relay.commandStorageRepairNeeded,
                            recoveredCommands: relay.commandStorageRepairReceipt?.recoveredCommands, repair: { relay.repairCommandStorage() })
                        if let recoverable, separateReview {
                            CommandRecoveryReviewButton { reviewedOriginal = recoverable }
                        }
                        if draft.isUnconfirmed && !separateReview {
                            CommandRecoveryControls(isChecking: draft.submissionID.map(relay.checkingCommandIDs.contains) ?? false,
                                check: { relay.checkCommandStatus(draft.submissionID) },
                                discard: {
                                    guard relay.discardUnconfirmedCommand(draft.submissionID) else { return }
                                    draft.discardPendingOriginal()
                                    if let next = relay.recoverableCommand(for: task.id) { draft.restore(next) }
                                })
                        }
                    }
                    .codexGlassCard(tint: .cyan)
                }
                .padding(16)
            }
        }
        .navigationTitle(AppLocalizer.text(currentTask.messages.isEmpty ? "任务详情" : "对话"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reviewedOriginal) { original in
            CommandRecoveryReviewView(source: relay, original: original,
                status: { $0.commandReviewState(for: $1) }, check: { $0.checkCommandStatus($1) },
                discard: { source, id in
                    guard source.discardUnconfirmedCommand(id) else { return false }
                    if draft.submissionID == id { draft.discardPendingOriginal() }
                    return true
                })
        }
        .task {
            if let saved = relay.recoverableCommand(for: task.id) { draft.restore(saved) }
            relay.loadHistory(for: task.id)
        }
        .refreshable { relay.loadHistory(for: task.id, refresh: true) }
        .onChange(of: currentTask.state) { _, state in
            if !state.isActive { relay.loadHistory(for: task.id, refresh: true) }
        }
        .onChange(of: relay.commandReceipts.result(for: draft.submissionID)) { _, receipt in
            draft.apply(receipt)
            if receipt == .accepted {
                if let next = relay.recoverableCommand(for: task.id) { draft.restore(next) }
                relay.loadHistory(for: task.id, refresh: true)
            }
        }
        .onChange(of: relay.recoverableCommand(for: task.id)) { _, next in
            if draft.errorMessage == nil, let next { draft.restore(next) }
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateSymbol: String {
        switch currentTask.state {
        case .running: "play.circle.fill"
        case .waitingForApproval: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle: "pause.circle"
        case .unknown: "circle.dotted"
        }
    }

    private var stateColor: Color {
        switch currentTask.state {
        case .running: .green
        case .waitingForApproval: .orange
        case .failed: .red
        case .completed: .cyan
        case .idle, .unknown: .secondary
        }
    }

    private var stateLabel: String {
        if currentTask.awaitingUserInput == true { return "等待你的回复" }
        return switch currentTask.state {
        case .running: "运行中"
        case .waitingForApproval: "等待批准"
        case .idle: "空闲"
        case .completed: "已完成"
        case .failed: "失败"
        case .unknown: "未知"
        }
    }
}

struct PhoneNewCodexView: View {
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: PhoneRelayController
    @State private var draft = MessageDraft()
    @State private var modelSelection = CodexModelSelection()
    @State private var reviewedOriginal: RecoverableCommandDraft?

    init(relay: PhoneRelayController) {
        self.relay = relay
        _draft = State(initialValue: relay.initialCommandDraft(for: TaskCommand.newChatTaskID))
    }

    var body: some View {
        let recoverable = relay.recoverableCommand(for: TaskCommand.newChatTaskID)
        let separateReview = recoverable.map(draft.needsSeparateReview) ?? false
        ZStack {
            CodexBackdrop()
            VStack(alignment: .leading, spacing: 16) {
                CodexModelPicker(models: relay.snapshot.models, selection: $modelSelection)
                TextField(AppLocalizer.text("输入消息"), text: $draft.text, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("codex.messageInput")
                    .padding(14)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                Button {
                    draft.submitted(relay.startCodexChat(draft.text, options: modelSelection.options(in: relay.snapshot.models)))
                } label: {
                    Label(AppLocalizer.text(draft.submissionID == nil || draft.isUnconfirmed ? "发送" : "正在发送…"), systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .codexPrimaryButton()
                .accessibilityIdentifier("codex.send")
                .disabled(!relay.commandStorageAvailable || recoverable != nil || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.submissionID != nil)
                if let error = draft.displayedError(language: AppLanguage(rawValue: languageRaw) ?? .system) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable, draft.errorMessage == nil {
                    Text(AppLocalizer.text("本机存储不可用，发送已暂停。请保留草稿并重试。"))
                        .font(.caption).foregroundStyle(.orange)
                }
                if !relay.commandStorageAvailable {
                    Button(AppLocalizer.text("重试")) { relay.retryCommandStorage() }
                        .frame(minHeight: 44).accessibilityIdentifier("command.storage.retry")
                }
                CommandStorageRepairControls(canRepair: relay.commandStorageRepairNeeded,
                    recoveredCommands: relay.commandStorageRepairReceipt?.recoveredCommands, repair: { relay.repairCommandStorage() })
                if let recoverable, separateReview {
                    CommandRecoveryReviewButton { reviewedOriginal = recoverable }
                }
                if draft.isUnconfirmed && !separateReview {
                    CommandRecoveryControls(isChecking: draft.submissionID.map(relay.checkingCommandIDs.contains) ?? false,
                        check: { relay.checkCommandStatus(draft.submissionID) },
                        discard: {
                            guard relay.discardUnconfirmedCommand(draft.submissionID) else { return }
                            draft.discardPendingOriginal()
                            if let next = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(next) }
                        })
                }
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(AppLocalizer.text("新建 Codex"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reviewedOriginal) { original in
            CommandRecoveryReviewView(source: relay, original: original,
                status: { $0.commandReviewState(for: $1) }, check: { $0.checkCommandStatus($1) },
                discard: { source, id in
                    guard source.discardUnconfirmedCommand(id) else { return false }
                    if draft.submissionID == id { draft.discardPendingOriginal() }
                    return true
                })
        }
        .task {
            if let saved = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(saved) }
        }
        .onChange(of: relay.commandReceipts.result(for: draft.submissionID)) { _, receipt in
            draft.apply(receipt)
            if receipt == .accepted {
                if let next = relay.recoverableCommand(for: TaskCommand.newChatTaskID) { draft.restore(next) }
                else if draft.text.isEmpty { dismiss() }
            }
        }
        .onChange(of: relay.recoverableCommand(for: TaskCommand.newChatTaskID)) { _, next in
            if draft.errorMessage == nil, let next { draft.restore(next) }
        }
    }
}

private struct ChatTranscriptView: View {
    let messages: [ChatMessage]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Label(AppLocalizer.text("对话"), systemImage: "message")
                .font(.headline)
            ForEach(messages) { message in
                HStack {
                    if message.role == .assistant { bubble(message); Spacer(minLength: 34) }
                    else { Spacer(minLength: 34); bubble(message) }
                }
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        Text(message.text + (message.isStreaming ? "▍" : ""))
            .font(.subheadline)
            .textSelection(.enabled)
            .padding(11)
            .background(message.role == .user ? Color.cyan.opacity(0.22) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct ApprovalSummaryRow: View {
    let request: ApprovalRequest
    @ObservedObject var relay: PhoneRelayController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text(AppLocalizer.localizedRemote(request.title)).font(.headline)
                Spacer()
                if relay.decisionReceipts.result(for: request.id) != .accepted {
                    Text(AppLocalizer.text("待处理")).font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(AppLocalizer.localizedRemote(request.summary)).font(.subheadline).foregroundStyle(.secondary)
            if let command = request.command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
            }
            if let directory = request.workingDirectory, !directory.isEmpty {
                Text(AppLocalizer.text("工作目录")).font(.caption).foregroundStyle(.secondary)
                Text(directory).font(.system(.caption, design: .monospaced))
            }
            if request.requestsNetwork || !request.requestedPaths.isEmpty {
                Text(AppLocalizer.text("访问范围")).font(.caption).foregroundStyle(.secondary)
                if request.requestsNetwork {
                    Label(AppLocalizer.text("网络访问"), systemImage: "network").font(.caption)
                }
                ForEach(Array(request.requestedPaths.enumerated()), id: \.offset) { _, path in
                    Text(path).font(.system(.caption, design: .monospaced))
                }
            }
            InteractionReceiptView(receipt: relay.decisionReceipts.result(for: request.id), pending: relay.isDecisionPending(for: request.id))
            if relay.decisionReceipts.result(for: request.id) == .accepted {
                EmptyView()
            } else if request.questions != nil {
                UserInputResponseForm(request: request, isSending: relay.isDecisionPending(for: request.id)) {
                    relay.decide(.allowOnce, request: request, answers: $0)
                }.id(request.id)
            } else {
            Label(AppLocalizer.text("iPhone 批准会先要求 Face ID"), systemImage: "faceid")
                .font(.caption)
                .foregroundStyle(.orange)

            Divider().overlay(.primary.opacity(0.10))

            HStack(spacing: 10) {
                Button(AppLocalizer.text("拒绝"), role: .destructive) {
                    relay.decide(.deny, request: request)
                }
                .codexGlassButton()
                .disabled(relay.isDecisionPending(for: request.id) || request.isExpired)

                Button {
                    relay.decide(.allowOnce, request: request)
                } label: {
                    Label(AppLocalizer.text("批准一次"), systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .codexPrimaryButton()
                .tint(.green)
                .disabled(relay.isDecisionPending(for: request.id) || request.isExpired)
            }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhoneUsageResetView: View {
    @ObservedObject var relay: PhoneRelayController
    @State private var selectedCard: ResetCredit?

    private var usage: UsageSnapshot? { relay.snapshot.usage }
    private var resetCards: [ResetCredit] {
        (usage?.resetCredits ?? []).filter { $0.status == .available && ($0.expiresAt.map { $0 > Date() } ?? true) }
    }

    var body: some View {
        ZStack {
            CodexBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    overview
                    if !resetCards.isEmpty {
                        resetCardsSection
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(AppLocalizer.text("额度与重置"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            AppLocalizer.text("确认使用重置卡？"),
            isPresented: Binding(get: { selectedCard != nil }, set: { if !$0 { selectedCard = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppLocalizer.text("确认"), role: .destructive) {
                if let selectedCard {
                    relay.consumeResetCredit(selectedCard.id)
                }
                selectedCard = nil
            }
            Button(AppLocalizer.text("取消"), role: .cancel) { selectedCard = nil }
        } message: {
            Text(AppLocalizer.text("这会消耗一张重置卡，并立即重置符合条件的额度窗口。"))
        }
        .alert(AppLocalizer.text("提示"), isPresented: Binding(
            get: { relay.usageResetResult != nil },
            set: { if !$0 { relay.usageResetResult = nil } }
        )) {
            Button(AppLocalizer.text("好")) { relay.usageResetResult = nil }
        } message: {
            Text(resultText(relay.usageResetResult))
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AppLocalizer.text("Token 余额"), systemImage: "gauge.with.dots.needle.33percent")
                .font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(UsagePresentation.remainingText(usage?.primary))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.cyan)
                Text(AppLocalizer.text("剩余")).foregroundStyle(.secondary)
                Spacer()
            }
            Divider().overlay(.primary.opacity(0.10))
            metric(AppLocalizer.text("重置日期"), value: usage?.primary?.resetsAt.map(AppLocalizer.dateTime) ?? AppLocalizer.text("用量不可用"))
        }
        .codexGlassCard(tint: .cyan)
    }

    private var resetCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalizer.text("重置卡"), systemImage: "arrow.counterclockwise.circle.fill")
                .font(.headline)
            ForEach(resetCards) { card in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(card.title ?? AppLocalizer.text("重置卡"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(AppLocalizer.text("使用")) { selectedCard = card }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                    }
                    if let detail = card.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(card.expiresAt.map { AppLocalizer.format("到期 %@", AppLocalizer.dateTime($0)) } ?? AppLocalizer.text("无到期日"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
        .codexGlassCard(tint: .purple)
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func tokenText(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func resultText(_ result: String?) -> String {
        switch result {
        case "reset": AppLocalizer.text("重置完成")
        case "nothingToReset": AppLocalizer.text("当前没有可重置的额度窗口")
        case "noCredit": AppLocalizer.text("没有可用重置卡")
        case "alreadyRedeemed": AppLocalizer.text("此重置请求已完成")
        default: result ?? ""
        }
    }
}
