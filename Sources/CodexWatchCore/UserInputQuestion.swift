import Foundation

public struct UserInputOption: Codable, Equatable, Sendable {
    public let label: String
    public let description: String
    public init(label: String, description: String) {
        self.label = label; self.description = description
    }
}

public struct UserInputQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [UserInputOption]?
    public let isOther: Bool
    public let isSecret: Bool

    public init(id: String, header: String, question: String,
                options: [UserInputOption]? = nil, isOther: Bool = false, isSecret: Bool = false) {
        self.id = id; self.header = header; self.question = question
        self.options = options; self.isOther = isOther; self.isSecret = isSecret
    }

    public var permitsFreeText: Bool { isOther || options?.isEmpty != false }

    private enum CodingKeys: CodingKey { case id, header, question, options, isOther, isSecret }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        header = try c.decode(String.self, forKey: .header)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([UserInputOption].self, forKey: .options)
        isOther = try c.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }
}

/// An option and a typed answer are mutually exclusive for each question.
/// Keep this state separate from the view so switching either way is testable.
public struct UserInputFormState: Equatable, Sendable {
    public private(set) var selected: [String: String] = [:]
    public private(set) var typed: [String: String] = [:]

    public init() {}
    public mutating func select(_ label: String, for questionID: String) {
        selected[questionID] = label
        typed.removeValue(forKey: questionID)
    }
    public mutating func type(_ text: String, for questionID: String) {
        typed[questionID] = text
        selected.removeValue(forKey: questionID)
    }
    public func answers(for questions: [UserInputQuestion]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [selected[$0.id] ?? typed[$0.id] ?? ""]) })
    }
}

public enum UserInputValidation {
    public enum Failure: LocalizedError { case invalidQuestion, invalidAnswers
        public var errorDescription: String? { AppLocalizer.text("请完整回答当前问题") }
    }

    public static func questions(from params: JSONValue) throws -> [UserInputQuestion] {
        guard let value = params["questions"] else { throw Failure.invalidQuestion }
        let data = try CodexWatchCoding.makeEncoder().encode(value)
        let questions = try CodexWatchCoding.makeDecoder().decode([UserInputQuestion].self, from: data)
        guard (1...3).contains(questions.count), Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.id.isEmpty && !$0.question.isEmpty && ($0.options?.count ?? 0) <= 20 }) else {
            throw Failure.invalidQuestion
        }
        return questions
    }

    /// Return the exact answer, never an option index or translated label.
    public static func validate(_ answers: [String: [String]], questions: [UserInputQuestion]) throws {
        guard !questions.isEmpty, Set(answers.keys) == Set(questions.map(\.id)) else { throw Failure.invalidAnswers }
        for q in questions {
            guard let values = answers[q.id], values.count == 1, let value = values.first,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.unicodeScalars.count <= 4000,
                  q.permitsFreeText || q.options?.contains(where: { $0.label == value }) == true else {
                throw Failure.invalidAnswers
            }
        }
    }
}
