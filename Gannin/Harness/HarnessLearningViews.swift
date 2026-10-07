import SwiftUI

/// A learning: the rule, where it applies, why, and the comment it came
/// from. Commit to Harness writes `learnings/<repo>/<date>-<slug>.md`; nothing
/// is written before that.
struct HarnessLearningEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig
    /// Editing a learning already in the harness: its file, rewritten.
    var existingPath: String? = nil

    @State private var draft: HarnessLearningDraft
    @State private var saving = false
    @State private var error: String?

    init(org: String, setup: HarnessConfig, draft: HarnessLearningDraft, existingPath: String? = nil) {
        self.org = org
        self.setup = setup
        self.existingPath = existingPath
        _draft = State(initialValue: draft)
    }

    private var path: String { existingPath ?? draft.path }

    var body: some View {
        Form {
            DraftWithClaudeSection(kind: .learnings, org: org, setup: setup, current: { draft.rule.isEmpty && draft.quote.isEmpty ? nil : draft.fileText }) { reply in
                if let value = reply.title { draft.title = value }
                if let value = reply.summary { draft.rule = value }
                if let value = reply.repos?.first { draft.repo = value }
                if let value = reply.paths { draft.paths = value.joined(separator: "\n") }
                if let value = reply.reason ?? reply.body { draft.reason = value }
                if let value = reply.status, HarnessDocumentDraft.statuses(.learnings).contains(value) { draft.status = value }
            }
            Section {
                TextField("Rule", text: $draft.rule, prompt: Text("Keep the sync writes on the store's actor"), axis: .vertical)
                    .lineLimit(1...4)
                TextField("Title", text: $draft.title, prompt: Text(draft.rule.isEmpty ? "Short, for lists" : String(draft.rule.prefix(60))))
                Picker("Status", selection: $draft.status) {
                    ForEach(HarnessDocumentDraft.statuses(.learnings), id: \.self) { Text(HarnessDocumentDraft.statusTitle($0)).tag($0) }
                }
            } footer: {
                Text("The rule in a sentence: what reviews should do, or leave alone, here. Retired learnings stay in the harness but aren't followed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Repository", text: $draft.repo, prompt: Text("\(org)/name"))
                TextField("Scope", text: $draft.paths, prompt: Text("Sources/Sync/\nSources/Sync/Store.swift#L40-L72"), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...6)
                TextField("Commit", text: $draft.commit, prompt: Text("The commit the line numbers are at"))
                    .font(.body.monospaced())
            } header: {
                Text("Where it applies")
            } footer: {
                Text("One a line: a folder ending in /, a file, or lines of a file as path#L10-L24. Left empty, the whole repo. Reviews of changes there are given it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reason") {
                TextEditor(text: $draft.reason)
                    .frame(minHeight: 90)
            }
            Section("Source") {
                TextField("Comment", text: $draft.source, prompt: Text("https://github.com/owner/name/pull/12#discussion_r1"))
                TextField("Given by", text: $draft.author, prompt: Text("Their GitHub login"))
                TextField("What they said", text: $draft.quote, axis: .vertical)
                    .lineLimit(2...8)
            }
            Section {
                Text("\(existingPath == nil ? "Saved as" : "Rewrites") \(path) in \(setup.repo).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 560, maxHeight: 860)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving || draft.rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.repo.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Commits \(path) to \(setup.repo)")
            }
        }
    }

    private func save() {
        draft.repo = draft.repo.trimmingCharacters(in: .whitespaces)
        if existingPath == nil, harness.index(for: org, setup)?.document(at: draft.path) != nil {
            error = "There's already a \(draft.path). Give it another title."
            return
        }
        let name = draft.title.isEmpty ? draft.rule : draft.title
        let change = HarnessChange(message: "Gannin: \(existingPath == nil ? "add" : "update") the learning \(name)", files: [path: draft.fileText])
        HarnessCommitting.commit(harness, org: org, setup: setup, change, saving: $saving, error: $error, dismiss: dismiss)
    }
}

/// Opens `HarnessLearningEditor` on a draft, in the harness covering its
/// repo: from a PR comment, a review thread or a reviewer's suggestion.
struct SaveAsLearningButton: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let draft: HarnessLearningDraft
    var title = "Save as Learning"
    var iconOnly = false
    @State private var editing = false

    var body: some View {
        let setup = configs.config(for: org).harness(covering: [draft.repo])
        Button { editing = true } label: {
            if iconOnly {
                Label(title, systemImage: "lightbulb").labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: "lightbulb")
            }
        }
        .disabled(setup == nil)
        .help(setup == nil ? "Set the org's harness in Settings to keep learnings" : "Keep this as a learning in the harness, so later reviews follow it")
        .sheet(isPresented: $editing) {
            if let setup {
                HarnessLearningEditor(org: org, setup: setup, draft: draft)
            }
        }
    }
}

/// Edit Learning: the editor on a learning in the harness, to change its
/// rule, scope or reason, or retire it. `harnessRepo` is the harness it's in
/// when its path doesn't say (a combined index names the others').
struct EditLearningButton: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let learning: HarnessLearning
    let harnessRepo: String?
    var iconOnly = false
    @State private var editing = false

    var body: some View {
        let (repo, path) = HarnessIndex.split(learning.document.path)
        let config = configs.config(for: org)
        let setup = (repo ?? harnessRepo).flatMap(config.harness(repo:)) ?? config.harnesses.first
        Button { editing = true } label: {
            if iconOnly {
                Label("Edit Learning", systemImage: "pencil").labelStyle(.iconOnly)
            } else {
                Label("Edit Learning", systemImage: "pencil")
            }
        }
        .disabled(setup == nil)
        .help("Change its rule, scope or reason, or retire it, committed to the harness")
        .sheet(isPresented: $editing) {
            if let setup {
                HarnessLearningEditor(org: org, setup: setup, draft: HarnessLearningDraft(learning: learning), existingPath: path)
            }
        }
    }
}

/// A learning as a row: its rule, where it applies, and who gave it, with
/// Edit Learning when `org` is given.
struct HarnessLearningRow: View {
    let learning: HarnessLearning
    let url: URL?
    var org: String? = nil
    var harnessRepo: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: HarnessKind.learnings.systemImage).foregroundStyle(.yellow)
                Text(learning.rule).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let org {
                    EditLearningButton(org: org, learning: learning, harnessRepo: harnessRepo, iconOnly: true)
                        .buttonStyle(.borderless)
                }
                if let url {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open the learning in the harness on GitHub")
                }
            }
            Text(learning.scopeText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let reason = learning.reason {
                Text(reason).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            }
            if let author = learning.author {
                Text("From @\(author)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
