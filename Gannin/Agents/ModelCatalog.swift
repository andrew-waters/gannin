import Foundation

extension AIModel {
    /// A model this build doesn't list, named from its ID: `claude-opus-4-7`
    /// is Claude Opus 4.7, with a snapshot's date left off. Anything else
    /// is shown as it's written.
    static func named(_ id: String) -> AIModel {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return AIModel(id: id, name: id) }
        let words = parts.dropFirst().filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        let family = words.prefix { !$0.allSatisfy(\.isNumber) }
        let version = words.dropFirst(family.count)
        guard !family.isEmpty, !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return AIModel(id: id, name: id) }
        return AIModel(id: id, name: (["Claude"] + family.map(\.capitalized)).joined(separator: " ") + " " + version.joined(separator: "."))
    }
}

/// What a model picker offers for each provider: the models this build
/// lists, those found on this Mac, and the aliases for the newest of a
/// family. Looked for once a launch, when a picker for the provider first
/// shows, since the lists in code go stale between releases.
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var detected: [ProviderID: [String]] = [:]
    @ObservationIgnored private var looking: Set<ProviderID> = []

    func detect(_ provider: ProviderID) async {
        guard looking.insert(provider).inserted else { return }
        detected[provider] = await AgentProviders.provider(provider).detectModels()
    }

    /// Found on this Mac and not already listed, newest first.
    func found(for provider: ProviderID) -> [AIModel] {
        let source = AgentProviders.provider(provider)
        let listed = Set((source.models + source.latest).map(\.id))
        return (detected[provider] ?? []).filter { !listed.contains($0) }.map(AIModel.named)
    }

    /// How a model is shown: its listed name, else one made from its ID.
    func name(of id: String, provider: ProviderID) -> String {
        let source = AgentProviders.provider(provider)
        return (source.models + source.latest).first { $0.id == id }?.name ?? AIModel.named(id).name
    }
}
