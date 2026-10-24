import SwiftUI

/// A model, picked from what its provider offers (`ModelCatalog`) or typed
/// under Other. Empty is `inherited`: whatever the step, specialist or
/// session falls back to. A provider that picks its own model says so
/// instead.
struct ModelPicker: View {
    let provider: ProviderID
    @Binding var model: String
    /// The empty choice, such as "Claude Code's default".
    let inherited: String
    /// Typing a model ID of your own, rather than picking one.
    @State private var typing = false

    private static let custom = "\u{0}custom"

    var body: some View {
        let source = AgentProviders.provider(provider)
        if source.models.isEmpty, source.latest.isEmpty {
            LabeledContent("Model", value: "\(provider.title) picks its own")
        } else {
            let found = ModelCatalog.shared.found(for: provider)
            let offered = Set((source.models + source.latest + found).map(\.id))
            let isCustom = typing || (!model.isEmpty && !offered.contains(model))
            Picker("Model", selection: Binding(
                get: { isCustom ? Self.custom : model },
                set: { picked in
                    typing = picked == Self.custom
                    if !typing { model = picked }
                }
            )) {
                Text(inherited).tag("")
                Divider()
                ForEach(source.models) { Text($0.name).tag($0.id) }
                if !found.isEmpty {
                    Section("Used on this Mac") {
                        ForEach(found) { Text($0.name).tag($0.id) }
                    }
                }
                if !source.latest.isEmpty {
                    Section("Always the newest") {
                        ForEach(source.latest) { Text($0.name).tag($0.id) }
                    }
                }
                Divider()
                Text("Other").tag(Self.custom)
            }
            .task(id: provider) { await ModelCatalog.shared.detect(provider) }
            if isCustom {
                TextField("Model ID", text: $model, prompt: Text(source.models.first?.id ?? ""))
                    .leadingTextBox("Model ID")
            }
        }
    }
}
