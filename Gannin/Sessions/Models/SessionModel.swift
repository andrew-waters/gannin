import Foundation

extension SessionStore {
    static let providerKey = "sessionsProvider"
    /// A model ID, or empty for the provider's own default.
    static let modelKey = "sessionsModel"

    /// The provider sessions start on, picked in Settings: Claude Code,
    /// the only interactive one, for anything else stored (`anthropic`
    /// from before providers had their own IDs).
    static var provider: ProviderID {
        UserDefaults.standard.string(forKey: providerKey).flatMap(ProviderID.init(rawValue:)).flatMap { $0.isInteractive ? $0 : nil } ?? .claudeCode
    }

    /// The model sessions start with, nil leaving it to Claude Code (its
    /// settings, or `/model` in the session).
    static var model: String? {
        let model = (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? nil : model
    }
}
