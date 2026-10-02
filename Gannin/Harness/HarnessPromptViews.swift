import SwiftUI

/// Settings › Harness: the team's prompts, `prompts/*.md` in the harness,
/// each opening in an editor that commits it back.
struct HarnessPromptsSection: View {
    @Environment(HarnessStore.self) private var harness
    let org: String
    let setup: HarnessConfig
    /// Says which harness, when there are several.
    var showsName = false
    @State private var editing: HarnessPrompt?
    @State private var creating = false

    var body: some View {
        let index = harness.index(for: org, setup)
        let library = HarnessPromptLibrary(index: index)
        Section {
            if library.prompts.isEmpty {
                Text(index == nil ? "Reading the harness." : "No prompts in \(setup.repo) yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.prompts) { prompt in
                LabeledContent {
                    Button("Edit") { editing = prompt }
                } label: {
                    Text(prompt.title)
                    Text(Self.caption(prompt))
                }
            }
            Button("New Prompt") { creating = true }
                .disabled(index == nil)
        } header: {
            Text(showsName ? "Prompts in \(setup.name)" : "Prompts")
        } footer: {
            Text("What Claude Code sessions are told besides Gannin's own prompt, for everyone in \(org). Each is offered when work, a review or planning starts (defaults ticked, a repo's own default in place of the general ones), or from the menu under a session's terminal, and can bring skills from the harness's skills folder. Saving commits it to \(setup.repo).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { prompt in
            HarnessPromptEditor(org: org, setup: setup, library: library, prompt: prompt)
        }
        .sheet(isPresented: $creating) {
            HarnessPromptEditor(org: org, setup: setup, library: library, prompt: nil)
        }
    }

    static func caption(_ prompt: HarnessPrompt) -> String {
        var parts = [Set(prompt.uses) == Set(PromptUse.allCases) ? "Everywhere" : prompt.uses.map(\.label).joined(separator: ", ")]
        if prompt.isDefault { parts.append(prompt.repos.isEmpty ? "default" : "default for \(prompt.repos.joined(separator: ", "))") }
        if !prompt.skills.isEmpty { parts.append("skills: \(prompt.skills.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }
}

/// A prompt's title, summary, where it's offered, whether it's a default
/// (and for which repos), its skills and its text. Saving commits
/// `prompts/<name>.md` to the harness; Delete removes it, after asking.
struct HarnessPromptEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig
    let library: HarnessPromptLibrary
    /// Nil for a new one.
    let prompt: HarnessPrompt?

    @State private var title = ""
    @State private var fileName = ""
    @State private var summary = ""
    @State private var uses: Set<PromptUse> = Set(PromptUse.allCases)
    @State private var isDefault = false
    @State private var repos = ""
    @State private var skills: Set<String> = []
    @State private var text = ""
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        Form {
            DraftWithClaudeSection(kind: .prompts, org: org, setup: setup, current: { title.isEmpty && text.isEmpty ? nil : draftText }) { reply in
                if let value = reply.title { title = value }
                if let value = reply.summary ?? reply.description { summary = value }
                if let value = reply.uses {
                    let picked = Set(value.compactMap { PromptUse(rawValue: $0.lowercased()) })
                    if !picked.isEmpty { uses = picked }
                }
                if let value = reply.skills {
                    let known = Set(library.skills.map(\.name))
                    skills = Set(value.filter(known.contains))
                }
                if let value = reply.body { text = value }
            }
            Section {
                TextField("Title", text: $title, prompt: Text("Security review"))
                if let prompt {
                    LabeledContent("File", value: prompt.path)
                } else {
                    TextField("File name", text: $fileName, prompt: Text(HarnessPrompt.fileName(for: title)))
                    Text("Saved as \(path).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Summary", text: $summary, prompt: Text("What it's for, in a line"), axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                ForEach(PromptUse.allCases) { use in
                    Toggle(use.label, isOn: Binding(
                        get: { uses.contains(use) },
                        set: { on in if on { uses.insert(use) } else { uses.remove(use) } }
                    ))
                    .checkboxToggle()
                }
                Toggle("Ticked by default", isOn: $isDefault)
                if isDefault {
                    TextField("Only for repos", text: $repos, prompt: Text("Any repo, or api, web"))
                }
            } header: {
                Text("Offered")
            } footer: {
                Text("A default is ticked when a session starts. One for named repos (by the issue's repo, its PRs' or the PR reviewed) takes the place of the general defaults there. Planning has no repo, so only general defaults apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !library.skills.isEmpty {
                Section("Skills it brings") {
                    ForEach(library.skills) { skill in
                        Toggle(isOn: Binding(
                            get: { skills.contains(skill.name) },
                            set: { on in if on { skills.insert(skill.name) } else { skills.remove(skill.name) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                if let summary = skill.summary {
                                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .checkboxToggle()
                    }
                }
            }
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
            } header: {
                Text("Prompt")
            } footer: {
                Text("Markdown. {{issue}}, {{title}}, {{url}}, {{repo}}, {{number}} and {{branch}} are filled in ({{issue}} is the PR in a review, {{title}} the topic in planning).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .frame(minHeight: 520, maxHeight: 820)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if prompt != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving || !isComplete)
                    .help("Commits \(path) to \(setup.repo)")
            }
        }
        .confirmationDialog("Delete \(prompt?.title ?? "this prompt")?", isPresented: $confirmingDelete) {
            Button("Delete from Harness", role: .destructive) { delete() }
        } message: {
            Text("Gannin commits \(path)'s removal to \(setup.repo). Sessions already started keep what they were told.")
        }
        .onAppear(perform: load)
    }

    private var path: String {
        if let prompt { return prompt.path }
        let name = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? title : fileName
        return "\(HarnessPrompt.folder)/\(HarnessPrompt.fileName(for: name)).md"
    }

    private var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !uses.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard let prompt else { return }
        title = prompt.title
        summary = prompt.summary ?? ""
        uses = Set(prompt.uses)
        isDefault = prompt.isDefault
        repos = prompt.repos.joined(separator: ", ")
        skills = Set(prompt.skills)
        text = prompt.body
    }

    /// The prompt as it stands, for Claude to improve on.
    private var draftText: String { edited.fileText }

    private func save() {
        let path = path
        if prompt == nil, harness.index(for: org, setup)?.document(at: path) != nil {
            error = "There's already a \(path). Pick another name."
            return
        }
        let saved = edited
        commit(HarnessChange(message: "Gannin: \(prompt == nil ? "add" : "update") the \(saved.title) prompt", files: [path: saved.fileText]))
    }

    private var edited: HarnessPrompt {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return HarnessPrompt(
            path: path,
            title: title.trimmingCharacters(in: .whitespaces),
            summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
            uses: PromptUse.allCases.filter(uses.contains),
            isDefault: isDefault,
            repos: isDefault ? repos.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : [],
            // Kept in the harness's order, then any it names that aren't there.
            skills: library.skills.map(\.name).filter(skills.contains) + skills.subtracting(library.skills.map(\.name)).sorted(),
            body: text,
            otherFields: prompt?.otherFields ?? [:]
        )
    }

    private func delete() {
        guard let prompt else { return }
        commit(HarnessChange(message: "Gannin: remove the \(prompt.title) prompt", files: [prompt.path: nil]))
    }

    private func commit(_ change: HarnessChange) {
        saving = true
        error = nil
        Task {
            do {
                try await harness.commit(org: org, setup: setup) { _ in change }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
