import Foundation

/// Populated by model/list on the signed-in Mac, never a guessed model menu.
public struct CodexModelOption: Codable, Identifiable, Equatable, Sendable {
    public var id: String { model }
    public let model: String
    public let displayName: String
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [String]
    public let isDefault: Bool
    public init(model: String, displayName: String, defaultReasoningEffort: String, supportedReasoningEfforts: [String], isDefault: Bool = false) {
        self.model = model; self.displayName = displayName
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts; self.isDefault = isDefault
    }
}

public struct CodexExecutionOptions: Codable, Equatable, Sendable {
    public let model: String
    public let effort: String
    public init(model: String, effort: String) { self.model = model; self.effort = effort }
    public func isSupported(by models: [CodexModelOption]) -> Bool {
        models.contains { $0.model == model && $0.supportedReasoningEfforts.contains(effort) }
    }
}

public struct CodexModelSelection: Equatable, Sendable {
    public var model = ""
    public var effort = ""
    public var isExplicit = false
    public init() {}
    /// Resolve asynchronous catalogs without requiring a view lifecycle callback
    /// to have already written the default into its parent binding.
    public func reconciled(_ models: [CodexModelOption], preferredModel: String? = nil, preferredEffort: String? = nil) -> Self {
        var result = self
        result.reconcile(models, preferredModel: preferredModel, preferredEffort: preferredEffort)
        return result
    }
    public mutating func reconcile(_ models: [CodexModelOption], preferredModel: String? = nil, preferredEffort: String? = nil) {
        let inherited = !isExplicit ? models.first(where: { $0.model == preferredModel }) : nil
        guard let selected = inherited ?? models.first(where: { $0.model == model })
            ?? models.first(where: { $0.model == preferredModel })
            ?? models.first(where: \.isDefault) ?? models.first else { return }
        model = selected.model
        if !isExplicit, let preferredEffort, selected.supportedReasoningEfforts.contains(preferredEffort) { effort = preferredEffort }
        if !selected.supportedReasoningEfforts.contains(effort) { effort = selected.defaultReasoningEffort }
    }
    public func options(in models: [CodexModelOption], onlyWhenSelected: Bool = false) -> CodexExecutionOptions? {
        guard !onlyWhenSelected || isExplicit else { return nil }
        let options = CodexExecutionOptions(model: model, effort: effort)
        return options.isSupported(by: models) ? options : nil
    }
}
