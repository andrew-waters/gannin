import SwiftUI

extension SessionStore {
    /// The org's prompts and skills, from its harness as last indexed
    /// (whichever branch: a session knows its repo, not the branch read).
    func promptLibrary(org: String, setup: HarnessConfig) -> HarnessPromptLibrary {
        HarnessPromptLibrary(index: harnessStore.index(for: org, setup) ?? harnessStore.anyIndex(org: org, repo: setup.repo))
    }

    /// The placeholders for a prompt sent to a running session.
    func promptValues(for session: CodeSession) -> [String: String] {
        if let planning = session.planning {
            return Self.planningValues(topic: planning.topic, harness: session.repo, branch: session.branch)
        }
        return session.issueValues
    }

    /// What a session adds to its first prompt: what was picked, else the
    /// defaults for its use and repos.
    func launchInstructions(org: String, setup: HarnessConfig, use: PromptUse, repos: [String], choice: PromptChoice?, values: [String: String]) -> String? {
        let library = promptLibrary(org: org, setup: setup)
        return library.instructions(for: choice ?? library.defaults(for: use, repos: repos), values: values)
    }
}

/// Before a session starts: the team's prompts offered for it (the
/// defaults ticked), the harness's skills, and a note for this one, with
/// what claude will be told, and which harness it runs in when the org has
/// several. `extra` is the starter's own options.
struct SessionLaunchSheet<Extra: View>: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let title: String
    let org: String
    /// The org's harnesses, and the one the work's repos point to.
    let harnesses: [HarnessConfig]
    let initial: HarnessConfig
    let use: PromptUse
    let repos: [String]
    let values: [String: String]
    var startTitle = "Start"
    let start: (PromptChoice, HarnessConfig) -> Void
    @ViewBuilder var extra: () -> Extra
    @State private var choice = PromptChoice()
    @State private var harness: HarnessConfig?

    var body: some View {
        let setup = harness ?? initial
        let library = sessions.promptLibrary(org: org, setup: setup)
        Form {
            Section {
                Text(title).font(.headline)
                if harnesses.count > 1 {
                    Picker("Harness", selection: Binding(get: { setup.repo }, set: { repo in
                        harness = harnesses.first { $0.repo == repo }
                        choice = sessions.promptLibrary(org: org, setup: harness ?? initial).defaults(for: use, repos: repos)
                    })) {
                        ForEach(harnesses, id: \.repo) { Text($0.repo).tag($0.repo) }
                    }
                }
            } footer: {
                if harnesses.count > 1 {
                    Text(setup.repo == initial.repo ? "The harness for \(repos.first ?? "its repo")." : "Not the harness its repos point to, which is \(initial.repo).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            PromptPickerSections(library: library, use: use, values: values, choice: $choice)
            extra()
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 360, maxHeight: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(startTitle) {
                    start(choice, setup)
                    dismiss()
                }
                .disabled(SessionStore.unavailable(org: org, harness: setup) != nil)
                .help(SessionStore.unavailable(org: org, harness: setup) ?? "")
            }
        }
        .onAppear { choice = library.defaults(for: use, repos: repos) }
    }

    /// Whether there's anything to ask before starting.
    static func hasChoices(_ library: HarnessPromptLibrary, use: PromptUse, harnesses: [HarnessConfig]) -> Bool {
        harnesses.count > 1 || library.hasChoices(for: use)
    }
}

extension SessionLaunchSheet where Extra == EmptyView {
    init(title: String, org: String, harnesses: [HarnessConfig], initial: HarnessConfig, use: PromptUse, repos: [String], values: [String: String], startTitle: String = "Start", start: @escaping (PromptChoice, HarnessConfig) -> Void) {
        self.init(title: title, org: org, harnesses: harnesses, initial: initial, use: use, repos: repos, values: values, startTitle: startTitle, start: start) { EmptyView() }
    }
}

/// The prompts offered for a use and every skill, as checkboxes, a note,
/// and what claude is told from them.
struct PromptPickerSections: View {
    let library: HarnessPromptLibrary
    let use: PromptUse
    let values: [String: String]
    @Binding var choice: PromptChoice
    @State private var skillSearch = ""

    var body: some View {
        let offered = library.offered(for: use)
        if !offered.isEmpty {
            Section {
                ForEach(offered) { prompt in
                    Toggle(isOn: binding(prompt)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.title)
                            if let caption = caption(prompt) {
                                Text(caption).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .checkboxToggle()
                }
            } header: {
                Text("Prompts")
            } footer: {
                Text("The team's prompts, from the harness's prompts folder, edited in the org's Settings under Harness. Defaults are ticked; a default for this repo takes the place of the general ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if !library.skills.isEmpty {
            Section("Skills") {
                if library.skills.count > 8 {
                    TextField("Search skills", text: $skillSearch)
                }
                ForEach(skills) { skill in
                    Toggle(isOn: Binding(
                        get: { choice.skills.contains(skill.path) },
                        set: { on in if on { choice.skills.insert(skill.path) } else { choice.skills.remove(skill.path) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            if let summary = skill.summary {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .checkboxToggle()
                    .help(skill.path)
                }
            }
        }
        Section {
            TextField("Anything else, for this one", text: $choice.note, axis: .vertical)
                .lineLimit(2...6)
            DisclosureGroup("What Claude is told besides Gannin's prompt") {
                Text(library.instructions(for: choice, values: values) ?? "Nothing more.")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Instructions")
        }
    }

    /// Every skill, narrowed by the search.
    private var skills: [HarnessSkill] {
        let query = skillSearch.trimmingCharacters(in: .whitespaces)
        return library.skills.filter { skill in
            query.isEmpty || skill.name.localizedCaseInsensitiveContains(query) || (skill.summary ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func caption(_ prompt: HarnessPrompt) -> String? {
        var parts: [String] = []
        if let summary = prompt.summary { parts.append(summary) }
        if prompt.isDefault { parts.append(prompt.repos.isEmpty ? "Default" : "Default for \(prompt.repos.joined(separator: ", "))") }
        if !prompt.skills.isEmpty { parts.append("Skills: \(prompt.skills.joined(separator: ", "))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Ticking a prompt ticks its skills; unticking it unticks those no
    /// other ticked prompt brings.
    private func binding(_ prompt: HarnessPrompt) -> Binding<Bool> {
        Binding(
            get: { choice.prompts.contains(prompt.path) },
            set: { on in
                let brought = Set(prompt.skills.compactMap { library.skill(named: $0)?.path })
                if on {
                    choice.prompts.insert(prompt.path)
                    choice.skills.formUnion(brought)
                } else {
                    choice.prompts.remove(prompt.path)
                    let kept = Set(library.prompts.filter { choice.prompts.contains($0.path) }.flatMap(\.skills).compactMap { library.skill(named: $0)?.path })
                    choice.skills.subtract(brought.subtracting(kept))
                }
            }
        )
    }
}
