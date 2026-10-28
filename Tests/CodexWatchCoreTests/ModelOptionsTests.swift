import Foundation
import Testing
@testable import CodexWatchCore

private let catalog = [
    CodexModelOption(model: "a", displayName: "A", defaultReasoningEffort: "medium", supportedReasoningEfforts: ["low", "medium"], isDefault: true),
    CodexModelOption(model: "b", displayName: "B", defaultReasoningEffort: "high", supportedReasoningEfforts: ["high", "ultra"]),
]
@Test func delayedCatalogResolvesBeforeBindingLifecycleAndPreservesInheritedSettings() {
    let initial = CodexModelSelection()
    #expect(initial.reconciled([]) == initial)
    let displayed = initial.reconciled(catalog)
    #expect(displayed.model == "a" && displayed.effort == "medium")
    #expect(initial.model.isEmpty)
    #expect(!displayed.isExplicit)
    #expect(displayed.options(in: catalog, onlyWhenSelected: true) == nil)
    let inherited = initial.reconciled(catalog, preferredModel: "b", preferredEffort: "ultra")
    #expect(inherited.model == "b" && inherited.effort == "ultra")
    var picked = displayed
    picked.effort = "low"; picked.isExplicit = true
    #expect(picked.reconciled(catalog, preferredModel: "b", preferredEffort: "ultra") == picked)
}
@Test func modelSelectionUsesActualCatalogAndResetsIncompatibleEffort() {
    var selection = CodexModelSelection()
    selection.reconcile(catalog, preferredModel: "b")
    #expect(selection.options(in: catalog) == CodexExecutionOptions(model: "b", effort: "high"))
    selection.effort = "ultra"; selection.model = "a"; selection.reconcile(catalog)
    #expect(selection.effort == "medium")
    #expect(!CodexExecutionOptions(model: "b", effort: "medium").isSupported(by: catalog))
    #expect(selection.options(in: []) == nil)
    #expect(selection.options(in: catalog, onlyWhenSelected: true) == nil)
    selection.reconcile(catalog, preferredModel: "b", preferredEffort: "ultra")
    #expect(selection.model == "b" && selection.effort == "ultra")
    selection.isExplicit = true
    selection.reconcile(catalog, preferredModel: "a", preferredEffort: "low")
    #expect(selection.options(in: catalog, onlyWhenSelected: true) == .init(model: "b", effort: "ultra"))
}
@Test func modelSettingsSurviveCommandEnvelopeAndOldCommandsDecode() throws {
    let command = TaskCommand(taskID: "test", prompt: "中文🙂", deviceID: "watch", options: .init(model: "b", effort: "high"))
    let data = try JSONEncoder().encode(command)
    #expect(try JSONDecoder().decode(TaskCommand.self, from: data) == command)
    var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    old.removeValue(forKey: "options")
    #expect(try JSONDecoder().decode(TaskCommand.self, from: JSONSerialization.data(withJSONObject: old)).options == nil)
}
@Test func catalogSnapshotIsBackwardCompatible() throws {
    let snapshot = DashboardSnapshot(models: catalog, bridgeConnected: true, capturedAt: Date())
    #expect(try JSONDecoder().decode(DashboardSnapshot.self, from: JSONEncoder().encode(snapshot)).models == catalog)
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
    old.removeValue(forKey: "models")
    #expect(try JSONDecoder().decode(DashboardSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).models.isEmpty)
}
@Test func blockedUserInputIsIncludedInProgressWithoutPretendingItIsExecuting() {
    var task = AgentTask(id: "waiting", title: "Question", state: .unknown, updatedAt: Date())
    task.awaitingUserInput = true
    #expect(task.isInProgress)
    #expect(!task.state.isActive)
    let snapshot = DashboardSnapshot(tasks: [task], bridgeConnected: true, capturedAt: Date())
    #expect(snapshot.activeTaskCount == 1)
}
@Test func compactWatchAndVisibleComparisonPreserveModelsAndEveryInProgressProject() {
    var tasks = (0..<9).map { AgentTask(id: "project-\($0)", title: "Project \($0)", state: .running, updatedAt: Date()) }
    tasks[8].state = .unknown; tasks[8].awaitingUserInput = true
    let snapshot = DashboardSnapshot(tasks: tasks, models: catalog, bridgeConnected: true, capturedAt: Date())
    let compact = snapshot.compactForWatch(maximumTasks: 4, messagesPerTask: 0, maximumTextLength: 60, maximumApprovals: 10)
    #expect(compact.tasks.count == 9)
    #expect(compact.models == catalog)
    #expect(compact.activeTaskCount == 9)
    var changed = snapshot
    changed.models = []
    #expect(!snapshot.isVisuallyEquivalent(to: changed))
    changed = snapshot; changed.tasks[8].awaitingUserInput = false
    #expect(!snapshot.isVisuallyEquivalent(to: changed))
    changed = snapshot; changed.tasks[0].reasoningEffort = "high"
    #expect(!snapshot.isVisuallyEquivalent(to: changed))
    #expect(TaskLiveActivityPolicy.task(in: snapshot, preferredTaskID: nil)?.id == "project-8")
}
@Test func modelUIHasTranslationsForEveryLanguage() {
    for language in AppLanguage.allCases where language != .system {
        for key in ["推理强度", "连接 Mac 后加载模型", "运行中不能切换模型，请等待当前回合结束", "模型选项已变化，请刷新后重新选择", "等待你的回复", "保持当前设置", "effort.none", "effort.minimal", "effort.low", "effort.medium", "effort.high", "effort.xhigh", "effort.max", "effort.ultra"] {
            #expect(ModelTranslations.text(key, language: language)?.isEmpty == false)
        }
    }
}
