import SwiftUI

/// A specialist's name, summary, defaults (provider, model, focus) and soul.
/// A team one is committed to the harness as `specialists/<name>.md`; one
/// kept for just you is saved on this Mac (`PersonalAgentsStore`) and never
/// reaches the harness. Delete removes it, after asking.
struct HarnessSpecialistEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(PersonalAgentsStore.self) private var personalAgents
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig
    /// Nil for a new one.
    let specialist: HarnessSpecialist?
    /// Kept for just you rather than the team: fixed for one being edited,
    /// a choice for a new one.
    @State var personal = false

    @State private var title = ""
    @State private var name = ""
    @State private var summary = ""
    /// A `ProviderID` raw value, or empty for Claude Code.
    @State private var provider = ""
    @State private var model = ""
    @State private var focus = ""
    @State private var soul = ""
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        Form {
            DraftWithClaudeSection(kind: .specialists, org: org, setup: setup, current: { title.isEmpty && soul.isEmpty ? nil : edited.fileText }) { reply in
                if let value = reply.title { title = value }
                if let value = reply.name, specialist == nil { name = value }
                if let value = reply.summary ?? reply.description { summary = value }
                if let value = reply.focus { focus = value }
                if let value = reply.body { soul = value }
            }
            Section {
                if specialist == nil {
                    Picker("Kept for", selection: $personal) {
                        Text("The team").tag(false)
                        Text("Just me").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Text(personal
                     ? "Just yours: saved in Gannin on this Mac, never committed to the harness, and only your own workflows can use it. A review it takes part in calls it \"Reviewer\" on GitHub and in review records, so its name isn't shown to the person it's aimed at."
                     : "The team's: committed to \(setup.repo), for everyone's workflows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text(personal ? "Coaching for Alex" : "Security reviewer"))
                if let specialist, !personal {
                    LabeledContent("File", value: specialist.path)
                } else if specialist == nil {
                    TextField("Name", text: $name, prompt: Text(HarnessSpecialist.fileName(for: title)))
                    if !personal {
                        Text("Saved as \(path). Workflow steps name it by this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Summary", text: $summary, prompt: Text("What it's for, in a line"), axis: .vertical)
                    .lineLimit(1...3)
                    .leadingTextBox("Summary")
            }
            Section {
                Picker("Provider", selection: $provider) {
                    Text(ProviderID.claudeCode.title).tag("")
                    ForEach(ProviderID.allCases.filter { $0 != .claudeCode }) { Text($0.title).tag($0.rawValue) }
                    if !provider.isEmpty, ProviderID(name: provider) == nil {
                        Text(provider).tag(provider)
                    }
                }
                ModelPicker(provider: ProviderID(name: provider) ?? .claudeCode, model: $model, inherited: "Each person's, from Settings › General")
                TextField("Focus", text: $focus, prompt: Text("What it looks at when a step doesn't say"), axis: .vertical)
                    .lineLimit(1...4)
                    .leadingTextBox("Focus")
            } header: {
                Text("Defaults")
            } footer: {
                Text("A workflow step can set its own provider, model and focus, which win over these. A one-shot CLI such as Junie answers once in a throwaway copy of the code, so it can only review; it's skipped where it isn't installed and signed in on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $soul)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
            } header: {
                Text("Soul")
            } footer: {
                Text("Markdown, told to the agent before anything else: who it is, what it knows about the team's code, what it looks for and what it leaves to others. Gannin's own prompt still covers the PR or issue and how a review ends, and the team's prompts and review config still apply.")
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
            if specialist != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(personal ? "Save" : saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving || !isComplete)
                    .help(personal ? "Saves it on this Mac, for your own workflows" : "Commits \(path) to \(setup.repo)")
            }
        }
        .confirmationDialog("Delete \(specialist?.title ?? "this specialist")?", isPresented: $confirmingDelete) {
            Button(personal ? "Delete" : "Delete from Harness", role: .destructive) { delete() }
        } message: {
            Text(personal
                 ? "Your workflow steps that name it run Gannin's own prompt instead, and runs already started keep what they were told."
                 : "Gannin commits \(path)'s removal to \(setup.repo). Workflow steps that name it run Gannin's own prompt instead, and runs already started keep what they were told.")
        }
        .onAppear(perform: load)
    }

    private var fileStem: String {
        if let specialist { return PersonalSpecialist(specialist).name }
        let typed = name.trimmingCharacters(in: .whitespaces)
        return HarnessSpecialist.fileName(for: typed.isEmpty ? title : typed)
    }

    private var path: String {
        specialist?.path ?? "\(HarnessSpecialist.folder)/\(fileStem).md"
    }

    private var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard let specialist else { return }
        personal = specialist.isPersonal
        title = specialist.title
        name = specialist.name
        summary = specialist.summary ?? ""
        provider = specialist.provider.map { ProviderID(name: $0)?.rawValue ?? $0 } ?? ""
        if provider == ProviderID.claudeCode.rawValue { provider = "" }
        model = specialist.model ?? ""
        focus = specialist.focus ?? ""
        soul = specialist.soul
    }

    private var edited: HarnessSpecialist {
        func trimmed(_ text: String) -> String? {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return HarnessSpecialist(
            path: path, name: fileStem, title: title.trimmingCharacters(in: .whitespaces), summary: trimmed(summary),
            provider: trimmed(provider), model: trimmed(model), focus: trimmed(focus), soul: soul,
            otherFields: specialist?.otherFields ?? [:]
        )
    }

    private func save() {
        if personal {
            let saved = PersonalSpecialist(edited)
            if specialist == nil, personalAgents.specialists(org: org)[saved.specialist.name.lowercased()] != nil {
                error = "You already have a specialist called \(saved.name). Pick another name."
                return
            }
            personalAgents.change(org: org) { $0.save(saved) }
            dismiss()
            return
        }
        let path = path
        if specialist == nil, harness.index(for: org, setup)?.document(at: path) != nil {
            error = "There's already a \(path). Pick another name."
            return
        }
        let saved = edited
        commit(HarnessChange(message: "Gannin: \(specialist == nil ? "add" : "update") the \(saved.title) specialist", files: [path: saved.fileText]))
    }

    private func delete() {
        guard let specialist else { return }
        if personal {
            let name = PersonalSpecialist(specialist).name
            personalAgents.change(org: org) { $0.specialists.removeAll { $0.name == name } }
            dismiss()
            return
        }
        commit(HarnessChange(message: "Gannin: remove the \(specialist.title) specialist", files: [specialist.path: nil]))
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
