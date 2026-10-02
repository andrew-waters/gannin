import Foundation

/// Who runs a session's agent. Anthropic's Claude Code only, for now.
enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        }
    }

    /// The models offered, most capable first; any other ID can be typed.
    var models: [AIModel] {
        switch self {
        case .anthropic: [
            AIModel(id: "claude-fable-5-1", name: "Claude Fable 5.1"),
            AIModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
            AIModel(id: "claude-sonnet-5", name: "Claude Sonnet 5"),
            AIModel(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5"),
        ]
        }
    }
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
}

extension SessionStore {
    static let providerKey = "sessionsProvider"
    /// A model ID, or empty for Claude Code's own default.
    static let modelKey = "sessionsModel"

    static var provider: AIProvider {
        UserDefaults.standard.string(forKey: providerKey).flatMap(AIProvider.init(rawValue:)) ?? .anthropic
    }

    /// The model sessions start with, nil leaving it to Claude Code (its
    /// settings, or `/model` in the session).
    static var model: String? {
        let model = (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }
}
