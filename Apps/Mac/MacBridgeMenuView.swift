import SwiftUI
import CodexWatchCore

struct MacBridgeMenuView: View {
    @ObservedObject var model: MacBridgeViewModel
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @State private var showsSettings = false
    @State private var modelSelection = CodexModelSelection()
    @State private var pairingVisibilityID = UUID()

    var body: some View {
        NavigationStack {
            ZStack {
                CodexBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        bridgeHero
                        if model.isPhonePaired {
                            pairedDeviceCard
                        } else {
                            pairingCard
                        }
                        if !model.snapshot.pendingApprovals.isEmpty { approvalsCard }
                        tasksCard
                        launchCard
                    }
                    .padding(14)
                }
            }
            .toolbar {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help(AppLocalizer.text("设置"))
            }
        }
        .id(languageRaw)
        .sheet(isPresented: $showsSettings) {
            MacSettingsView(model: model)
        }
        .alert(AppLocalizer.text("发生错误"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(AppLocalizer.text("好")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? AppLocalizer.text("未知错误"))
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppLocalizer.text("配对 iPhone"), systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text(AppLocalizer.format("有效期 %@", model.pairingCodeRemaining))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(model.pairingCode)
                    .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                    .tracking(3)
                Spacer()
                Button(AppLocalizer.text("更新验证码")) { model.rotatePairingCode() }
                    .codexGlassButton()
            }
            Button(AppLocalizer.text("重置 iPhone 配对")) { model.resetPhonePairing() }
                .font(.caption)
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
            Text(AppLocalizer.text("在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .purple)
        .onAppear { model.setPairingVisible(true, observerID: pairingVisibilityID) }
        .onDisappear { model.setPairingVisible(false, observerID: pairingVisibilityID) }
    }

    private var pairedDeviceCard: some View {
        HStack(spacing: 11) {
            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalizer.text("iPhone 已配对"))
                    .font(.subheadline.weight(.semibold))
                Text(AppLocalizer.text("配对二维码已移至设置的设备连接中"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .green)
    }

    private var bridgeHero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Codex Control", systemImage: "sparkles.rectangle.stack")
                        .font(.title3.bold())
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(AppLocalizer.text(model.statusText)).font(.caption).foregroundStyle(.secondary)
                    }
                    Label(
                        AppLocalizer.text(model.remoteRelayAvailable ? "远程中继在线" : "远程中继正在恢复"),
                        systemImage: model.remoteRelayAvailable ? "network" : "network.slash"
                    )
                    .font(.caption2)
                    .foregroundStyle(model.remoteRelayAvailable ? .green : .orange)
                    Label(
                        AppLocalizer.text(
                            model.isConnectedToExternalPower
                                ? "已接通电源，本地控制可用"
                                : "电池供电，不保持唤醒"
                        ),
                        systemImage: model.isConnectedToExternalPower ? "powerplug.fill" : "battery.100"
                    )
                    .font(.caption2)
                    .foregroundStyle(model.isConnectedToExternalPower ? .green : .secondary)
                }
                Spacer()
                quotaRing
            }

            Divider().overlay(.primary.opacity(0.08))

            Label(AppLocalizer.text("自动可信连接"), systemImage: "link.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)

            Text(AppLocalizer.text("首次连接后记住这台 iPhone，无需验证码；断线后自动恢复"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .cyan)
    }

    private var quotaRing: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.10), lineWidth: 6)
            Circle()
                .trim(from: 0, to: remainingFraction)
                .stroke(
                    AngularGradient(colors: [.cyan, .blue, .purple, .cyan], center: .center),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text(UsagePresentation.remainingText(model.snapshot.usage?.primary))
                    .font(.system(.caption, design: .rounded, weight: .bold))
                Text(AppLocalizer.text("Token 余额")).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 62, height: 62)
    }

    private var approvalsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalizer.text("等待批准"), systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(Array(model.snapshot.pendingApprovals.enumerated()), id: \.element.id) { index, request in
                if index > 0 { Divider().overlay(.primary.opacity(0.08)) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalizer.localizedRemote(request.title)).font(.subheadline.weight(.semibold))
                    Text(AppLocalizer.localizedRemote(request.summary)).font(.caption).foregroundStyle(.secondary)
                    if let command = request.command {
                        Text(command)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if request.questions != nil {
                        UserInputResponseForm(request: request, isSending: model.pendingAnswerIDs.contains(request.id)) {
                            model.answer(request, answers: $0)
                        }.id(request.id)
                    } else { HStack {
                        Button(AppLocalizer.text("拒绝"), role: .destructive) { model.deny(request) }
                            .codexGlassButton()
                        Spacer()
                        Button { model.approveWithAppleWatch(request) } label: {
                            Label(AppLocalizer.text("Watch 批准"), systemImage: "applewatch")
                        }
                        .codexPrimaryButton()
                        .tint(.green)
                    }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .orange)
    }

    private var tasksCard: some View {
        let codexTasks = model.snapshot.tasks.filter { !$0.isChat && !$0.isNativeChat }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppLocalizer.text("Codex 任务"), systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("\(codexTasks.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.08), in: Capsule())
            }

            if codexTasks.isEmpty {
                Text(AppLocalizer.text("还没有任务")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array((codexTasks.filter(\.isInProgress) + codexTasks.filter { !$0.isInProgress }.prefix(8)).enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider().overlay(.primary.opacity(0.08)) }
                    NavigationLink {
                        MacTaskDetailView(task: task, model: model)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(color(for: task.state).gradient).frame(width: 8, height: 8).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: task.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(AppLocalizer.text(task.awaitingUserInput == true ? "等待你的回复" : label(for: task.state))).font(.caption2).foregroundStyle(color(for: task.state))
                                }
                                if let progress = task.progress {
                                    ProgressView(value: progress).tint(color(for: task.state))
                                }
                                if let detail = AgentTaskPresentation.detail(task.detail) {
                                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .purple)
    }

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(AppLocalizer.text("启动新任务"), systemImage: "play.circle.fill")
                .font(.headline)
            CodexModelPicker(models: model.snapshot.models, selection: $modelSelection)
            TextField(AppLocalizer.text("让 Codex 做什么？"), text: $model.prompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField(AppLocalizer.text("工作目录"), text: $model.workingDirectory)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Button { model.startTask(options: modelSelection.options(in: model.snapshot.models)) } label: {
                Label(AppLocalizer.text("启动受控任务"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .codexPrimaryButton()
            .tint(.cyan)
            .disabled(model.isStartingTask || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexGlassCard(tint: .blue)
    }

    private var remainingFraction: Double {
        UsagePresentation.remainingFraction(model.snapshot.usage?.primary)
    }

    private var statusColor: Color {
        model.snapshot.bridgeConnected ? .green : .orange
    }

    private func color(for state: AgentTask.State) -> Color {
        switch state {
        case .running: .green
        case .waitingForApproval: .orange
        case .failed: .red
        case .completed: .cyan
        case .idle, .unknown: .secondary
        }
    }

    private func label(for state: AgentTask.State) -> String {
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

private struct MacTaskDetailView: View {
    let task: AgentTask
    @ObservedObject var model: MacBridgeViewModel
    @State private var prompt = ""
    @State private var modelSelection = CodexModelSelection()
    private var currentTask: AgentTask { model.snapshot.tasks.first { $0.id == task.id } ?? task }

    var body: some View {
        ZStack {
            CodexBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(verbatim: currentTask.title)
                        } icon: {
                            Image(systemName: "text.bubble.fill")
                        }
                            .font(.title3.bold())
                        Text(AppLocalizer.text(stateLabel))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stateColor)
                        if let progress = currentTask.progress {
                            ProgressView(value: progress).tint(stateColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .codexGlassCard(tint: stateColor)

                    VStack(alignment: .leading, spacing: 9) {
                        Label(AppLocalizer.text("任务详情"), systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                        if let detail = AgentTaskPresentation.detail(currentTask.detail) {
                            Text(detail).font(.subheadline)
                        }
                        if let modelName = currentTask.model, !modelName.isEmpty {
                            LabeledContent(AppLocalizer.text("模型"), value: modelName)
                        }
                        if let workspace = AgentTaskPresentation.workspace(currentTask.workspace) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(AppLocalizer.text("工作目录")).font(.caption).foregroundStyle(.secondary)
                                Text(workspace).font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .codexGlassCard(tint: .purple)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(AppLocalizer.text("发送指令"), systemImage: "arrow.up.message.fill")
                            .font(.headline)
                        CodexModelPicker(models: model.snapshot.models, selection: $modelSelection, preferredModel: currentTask.model, preferredEffort: currentTask.reasoningEffort, preservesCurrentSettings: true, isRunning: currentTask.isInProgress)
                        TextField(AppLocalizer.text("告诉 Codex 接下来做什么"), text: $prompt, axis: .vertical)
                            .lineLimit(3...7)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let submittedPrompt = prompt
                            model.sendCommand(submittedPrompt, to: currentTask, options: currentTask.isInProgress ? nil : modelSelection.options(in: model.snapshot.models, onlyWhenSelected: true)) {
                                if prompt == submittedPrompt { prompt = "" }
                            }
                        } label: {
                            Label(AppLocalizer.text("发送"), systemImage: "arrow.up.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .codexPrimaryButton()
                        .disabled(model.pendingCommandTaskIDs.contains(currentTask.id) || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .codexGlassCard(tint: .cyan)
                }
                .padding(14)
            }
        }
        .navigationTitle(AppLocalizer.text("任务详情"))
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
