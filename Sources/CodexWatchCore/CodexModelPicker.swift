import SwiftUI

public struct CodexModelPicker: View {
    public let models: [CodexModelOption]
    @Binding public var selection: CodexModelSelection
    public let preferredModel: String?
    public let preferredEffort: String?
    public let preservesCurrentSettings: Bool
    public let isRunning: Bool
    public init(models: [CodexModelOption], selection: Binding<CodexModelSelection>, preferredModel: String? = nil, preferredEffort: String? = nil, preservesCurrentSettings: Bool = false, isRunning: Bool = false) {
        self.models = models; _selection = selection; self.preferredModel = preferredModel; self.isRunning = isRunning
        self.preferredEffort = preferredEffort; self.preservesCurrentSettings = preservesCurrentSettings
    }
    public var body: some View {
        #if os(macOS)
        content.onChange(of: models) { _ in reconcile() }
            .onChange(of: preferredModel) { _ in reconcile() }
            .onChange(of: preferredEffort) { _ in reconcile() }
        #else
        content.onChange(of: models) { _, _ in reconcile() }
            .onChange(of: preferredModel) { _, _ in reconcile() }
            .onChange(of: preferredEffort) { _, _ in reconcile() }
        #endif
    }
    private var content: some View {
        Group {
            #if os(watchOS)
            // Keep each navigation-style picker in its own List row. A
            // VStack turns both into one row whose tap opens the first picker.
            if models.isEmpty {
                Text(AppLocalizer.text("连接 Mac 后加载模型")).font(.caption).foregroundStyle(.secondary)
            } else {
                modelPicker
                effortPicker
                if isRunning {
                    Text(AppLocalizer.text("运行中不能切换模型，请等待当前回合结束")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            #else
            VStack(alignment: .leading, spacing: 8) {
            if models.isEmpty {
                Text(AppLocalizer.text("连接 Mac 后加载模型")).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    HStack {
                        Text(AppLocalizer.text("模型")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        modelPicker.labelsHidden().pickerStyle(.menu)
                    }
                    HStack {
                        Text(AppLocalizer.text("推理强度")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        effortPicker.labelsHidden().pickerStyle(.menu)
                    }
                }.font(.subheadline)
                if isRunning {
                    Text(AppLocalizer.text("运行中不能切换模型，请等待当前回合结束")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            }
            #endif
        }
        .disabled(isRunning)
        .onAppear { reconcile() }
    }
    private var modelPicker: some View {
        Picker(AppLocalizer.text("模型"), selection: Binding(get: { resolvedSelection.model }, set: { value in
            var updated = resolvedSelection
            updated.model = value; updated.isExplicit = true
            updated.reconcile(models, preferredModel: preferredModel)
            selection = updated
        })) {
            ForEach(models) { model in Text(verbatim: model.displayName).tag(model.model) }
        }
        .accessibilityIdentifier("codex.model")
    }
    private var effortPicker: some View {
        Picker(AppLocalizer.text("推理强度"), selection: Binding(get: { inheritedEffortUnknown ? "" : resolvedSelection.effort }, set: { value in
            guard !value.isEmpty else { return }
            var updated = resolvedSelection
            updated.effort = value; updated.isExplicit = true
            selection = updated
        })) {
            if inheritedEffortUnknown { Text(AppLocalizer.text("保持当前设置")).tag("") }
            ForEach(selectedModel?.supportedReasoningEfforts ?? [], id: \.self) { effort in
                Text(AppLocalizer.text("effort.\(effort)")).tag(effort)
            }
        }
        .accessibilityIdentifier("codex.effort")
    }
    private var inheritedEffortUnknown: Bool { preservesCurrentSettings && !selection.isExplicit && preferredEffort == nil }
    private func reconcile() { selection.reconcile(models, preferredModel: preferredModel, preferredEffort: preferredEffort) }
    private var resolvedSelection: CodexModelSelection { selection.reconciled(models, preferredModel: preferredModel, preferredEffort: preferredEffort) }
    private var selectedModel: CodexModelOption? { models.first { $0.model == resolvedSelection.model } }
}
