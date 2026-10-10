import SwiftUI

/// New on a Harness page: the editor for its kind. Plans open as a new
/// plan's tab in the Claude Code window instead (`HarnessView.create`).
struct HarnessNewDocumentSheet: View {
    @Environment(HarnessStore.self) private var harness
    let kind: HarnessKind
    let org: String
    let setup: HarnessConfig

    var body: some View {
        switch kind {
        case .skills:
            HarnessSkillEditor(org: org, setup: setup, document: nil)
        case .prompts:
            HarnessPromptEditor(org: org, setup: setup, library: HarnessPromptLibrary(index: harness.index(for: org, setup)), prompt: nil)
        case .requirements, .findings:
            HarnessDocumentEditor(kind: kind, org: org, setup: setup)
        case .plans:
            // Plans open as a tab in the Claude Code window instead.
            EmptyView()
        case .learnings:
            HarnessLearningEditor(org: org, setup: setup, draft: HarnessLearningDraft())
        case .research:
            // Committed from an Ask's Files instead.
            EmptyView()
        case .refines:
            // Committed when a Design and Refine session is agreed instead.
            EmptyView()
        }
    }

    /// What the button's called on the page.
    static func title(_ kind: HarnessKind) -> String {
        kind == .plans ? "Plan with Claude" : "New \(kind.singular.capitalized)"
    }
}

/// A skill's name, description, repos and instructions. Saving commits
/// `skills/<name>.md` (or the skill's own file) to the harness.
struct HarnessSkillEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig
    /// Nil for a new one.
    let document: HarnessDocument?

    @State private var name = ""
    @State private var summary = ""
    @State private var repos = ""
    @State private var text = """
        # Skill name

        ## Context

        When and why to use it, and any arguments.

        ## Steps

        1.

        ## Rules

        -
        """
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    private static let knownFields: Set<String> = ["type", "name", "description", "summary", "repos"]

    var body: some View {
        Form {
            DraftWithClaudeSection(kind: .skills, org: org, setup: setup, current: { name.isEmpty && summary.isEmpty ? nil : fileText }) { reply in
                if let value = reply.name { name = HarnessPrompt.fileName(for: value) }
                if let value = reply.description ?? reply.summary { summary = value }
                if let value = reply.repos { repos = value.joined(separator: ", ") }
                if let value = reply.body { text = value }
            }
            Section {
                if let document {
                    LabeledContent("File", value: document.path)
                    TextField("Name", text: $name)
                } else {
                    TextField("Name", text: $name, prompt: Text("add-feature-flag"))
                    Text("Saved as \(path). Lowercase, with hyphens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Description", text: $summary, prompt: Text("What it does and when to use it"), axis: .vertical)
                    .lineLimit(1...4)
                TextField("Repos", text: $repos, prompt: Text("All, or api, web"))
            } footer: {
                Text("The description is how an agent decides to use it, so say when it applies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Instructions") {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 560, maxHeight: 860)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if document != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Commits \(path) to \(setup.repo)")
            }
        }
        .confirmationDialog("Delete \(document?.title ?? "this skill")?", isPresented: $confirmingDelete) {
            Button("Delete from Harness", role: .destructive) {
                guard let document else { return }
                HarnessCommitting.commit(harness, org: org, setup: setup, HarnessChange(message: "Gannin: remove the \(name) skill", files: [document.path: nil]), saving: $saving, error: $error, dismiss: dismiss)
            }
        } message: {
            Text("Gannin commits \(path)'s removal to \(setup.repo). Prompts that bring it by name stop finding it.")
        }
        .onAppear(perform: load)
    }

    private var path: String {
        document?.path ?? "skills/\(HarnessPrompt.fileName(for: name.isEmpty ? "skill" : name)).md"
    }

    private var fileText: String {
        let front = document?.frontMatter ?? [:]
        let repoList = repos.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.lowercased() != "all" }
        var lines = ["---", "type: skill", "name: \(HarnessPrompt.fileName(for: name))"]
        let description = summary.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !description.isEmpty { lines += ["description: >", "  \(description)"] }
        lines.append("repos: \(repoList.isEmpty ? "all" : "[\(repoList.joined(separator: ", "))]")")
        for (key, values) in front.filter({ !Self.knownFields.contains($0.key) }).sorted(by: { $0.key < $1.key }) {
            lines.append(values.count == 1 ? "\(key): \(values[0])" : "\(key): [\(values.joined(separator: ", "))]")
        }
        lines += ["---", "", text.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    private func load() {
        guard let document, let skill = HarnessSkill(document: document) else { return }
        name = skill.name
        summary = document.frontMatter?["description"]?.joined(separator: " ") ?? skill.summary ?? ""
        repos = (document.frontMatter?["repos"] ?? []).joined(separator: ", ")
        text = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        if document == nil, harness.index(for: org, setup)?.document(at: path) != nil {
            error = "There's already a \(path). Pick another name."
            return
        }
        let change = HarnessChange(message: "Gannin: \(document == nil ? "add" : "update") the \(HarnessPrompt.fileName(for: name)) skill", files: [path: fileText])
        HarnessCommitting.commit(harness, org: org, setup: setup, change, saving: $saving, error: $error, dismiss: dismiss)
    }
}

/// A new requirement or finding: its title, where it goes, its front
/// matter facts as STANDARDS.md has them, and the body, starting from the
/// harness's template for the kind.
struct HarnessDocumentEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let kind: HarnessKind
    let org: String
    let setup: HarnessConfig

    @State private var draft: HarnessDocumentDraft
    @State private var module = ""
    @State private var fileName = ""
    @State private var domains = ""
    @State private var issues = ""
    @State private var saving = false
    @State private var error: String?

    init(kind: HarnessKind, org: String, setup: HarnessConfig) {
        self.kind = kind
        self.org = org
        self.setup = setup
        var draft = HarnessDocumentDraft(kind: kind)
        draft.status = HarnessDocumentDraft.statuses(kind).first ?? ""
        if kind == .findings { draft.severity = "medium" }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let modules = Array(Set((harness.index(for: org, setup)?.documents(.requirements) ?? []).compactMap(\.module))).sorted()
        Form {
            DraftWithClaudeSection(kind: kind, org: org, setup: setup, current: { draft.title.isEmpty ? nil : draft.fileText }) { reply in
                if let value = reply.title { draft.title = value }
                if let value = reply.summary { draft.summary = value }
                if let value = reply.status, HarnessDocumentDraft.statuses(kind).contains(value) { draft.status = value }
                if let value = reply.severity, HarnessDocumentDraft.severities.contains(value) { draft.severity = value }
                if let value = reply.domains { domains = value.joined(separator: ", ") }
                if let value = reply.issues { issues = value.joined(separator: ", ") }
                if let value = reply.body { draft.body = value }
            }
            Section {
                TextField("Title", text: $draft.title)
                if kind == .requirements {
                    TextField("Module", text: $module, prompt: Text(modules.first ?? "billing"))
                    if !modules.isEmpty {
                        Text("Modules so far: \(modules.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("File name", text: $fileName, prompt: Text(HarnessDocumentDraft.slug(draft.title)))
                Text("Saved as \(path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Summary", text: $draft.summary, prompt: Text("A sentence or two for deciding whether to open it"), axis: .vertical)
                    .lineLimit(1...4)
            }
            Section {
                Picker("Status", selection: $draft.status) {
                    ForEach(HarnessDocumentDraft.statuses(kind), id: \.self) { Text(HarnessDocumentDraft.statusTitle($0)).tag($0) }
                }
                if kind == .findings {
                    Picker("Severity", selection: $draft.severity) {
                        ForEach(HarnessDocumentDraft.severities, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Domains", text: $domains, prompt: Text("billing, data-capture"))
                TextField("Issues", text: $issues, prompt: Text("\(org)/repo#123"))
            } header: {
                Text("Front matter")
            } footer: {
                Text("As the harness's STANDARDS.md sets out. Issues link it to them in Gannin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Body") {
                TextEditor(text: $draft.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 260)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 560, maxHeight: 860)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .requirements && moduleName.isEmpty))
                    .help("Commits \(path) to \(setup.repo)")
            }
        }
        .task {
            // The template, once, for a body that's still empty.
            let guides = await harness.guides(for: kind, org: org, setup: setup)
            let folder = kind == .plans ? "plans" : kind.rawValue.lowercased()
            if draft.body.isEmpty, let body = HarnessDocumentDraft.templateBody(guides["\(folder)/_template.md"]) {
                draft.body = body
            }
        }
    }

    private var moduleName: String { HarnessDocumentDraft.slug(module) == "untitled" ? "" : HarnessDocumentDraft.slug(module) }

    private var path: String {
        let name = HarnessDocumentDraft.slug(fileName.isEmpty ? draft.title : fileName)
        switch kind {
        case .requirements: return "requirements/\(moduleName.isEmpty ? "<module>" : moduleName)/\(name).md"
        default: return "\(kind == .plans ? "plans" : kind.rawValue.lowercased())/\(HarnessAuthoring.today)-\(name).md"
        }
    }

    private func save() {
        if harness.index(for: org, setup)?.document(at: path) != nil {
            error = "There's already a \(path). Pick another name."
            return
        }
        var draft = draft
        draft.domains = list(domains)
        draft.issues = list(issues)
        let change = HarnessChange(message: "Gannin: add the \(kind.singular) \(draft.title)", files: [path: draft.fileText])
        HarnessCommitting.commit(harness, org: org, setup: setup, change, saving: $saving, error: $error, dismiss: dismiss)
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One editor's commit: the button shows it's working, an error stays on
/// the form, and the sheet closes when it's in.
enum HarnessCommitting {
    static func commit(_ harness: HarnessStore, org: String, setup: HarnessConfig, _ change: HarnessChange, saving: Binding<Bool>, error: Binding<String?>, dismiss: DismissAction) {
        saving.wrappedValue = true
        error.wrappedValue = nil
        Task {
            do {
                try await harness.commit(org: org, setup: setup) { _ in change }
                dismiss()
            } catch let failure {
                error.wrappedValue = failure.localizedDescription
            }
            saving.wrappedValue = false
        }
    }
}

/// Drafting with Claude as a conversation: say what it's for, and Claude
/// asks what it needs to know or drafts it (from the harness's guides, the
/// ones already there and the org's guidance for the kind, Settings ›
/// Harness), saying what it did; answer or ask for changes and it carries
/// on, working from what's in the editor. One claude conversation per
/// sheet (`--resume` in the same folder). Run through your own claude,
/// only when you send something; nothing's committed until you do.
struct DraftWithClaudeSection: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    let kind: HarnessKind
    let org: String
    let setup: HarnessConfig
    /// What's written so far, to improve on; nil for nothing yet.
    let current: () -> String?
    let apply: (HarnessAuthoring.Reply) -> Void

    struct Turn: Identifiable {
        let id = UUID()
        let fromClaude: Bool
        let text: String
    }

    @State private var message = ""
    @State private var turns: [Turn] = []
    @State private var working = false
    @State private var conversation = UUID()
    /// Claude has answered once, so there's a conversation to go on with.
    @State private var started = false

    var body: some View {
        Section {
            if !turns.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(turns) { turn in
                                bubble(turn).id(turn.id)
                            }
                            if working {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Claude is thinking").foregroundStyle(.secondary)
                                }
                                .id("working")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 80, maxHeight: 300)
                    .onChange(of: turns.count) {
                        withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: working) {
                        if working { withAnimation { proxy.scrollTo("working", anchor: .bottom) } }
                    }
                }
            }
            TextField("Message", text: $message, prompt: Text(turns.isEmpty ? placeholder : "Answer, or say what to change"), axis: .vertical)
                .lineLimit(2...6)
                .onSubmit(send)
            HStack {
                Button(turns.isEmpty ? "Start with Claude" : "Send") { send() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(working || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if working && turns.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                if !turns.isEmpty {
                    Button("Start Over") {
                        turns = []
                        conversation = UUID()
                        started = false
                    }
                    .disabled(working)
                    .help("Forget this conversation; what's in the editor stays")
                }
            }
        } header: {
            Text("Draft with Claude")
        } footer: {
            Text("A conversation: Claude asks what it needs to know, drafts into the fields below and says what it did, and carries on from there. It reads the harness's guides and the \(kind.rawValue.lowercased()) already there, follows the org's guidance for \(kind.rawValue.lowercased()) (Settings under Harness), and sees your edits each time. Nothing's committed until you do.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bubble(_ turn: Turn) -> some View {
        HStack {
            if !turn.fromClaude { Spacer(minLength: 40) }
            Text(turn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(turn.fromClaude ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            if turn.fromClaude { Spacer(minLength: 40) }
        }
    }

    private var placeholder: String {
        switch kind {
        case .skills: "Rotate a tenant's API keys and check nothing breaks"
        case .prompts: "Reviews of the billing service should check money handling and idempotency"
        case .findings: "Exports time out for orgs with over 10k jobs; it's the N+1 in job_exports"
        case .learnings: "Sync writes go through the actor in SyncStore because two windows can refresh at once"
        default: "What it should cover"
        }
    }

    private static let conversational = """
        This is a conversation with me, not a one-off. Put what you say to me in `message`. If something that matters is unclear, ask me (a few short questions at most) in `message` and leave the other fields out until I've answered. Once you can, draft it, and use `message` to say briefly what you did and anything I should check. Later messages from me are answers or changes: work from what's in the editor then, since I may have edited it. Always reply with only the JSON, `message` included.
        """

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        message = ""
        let isFirst = !started
        turns.append(Turn(fromClaude: false, text: text))
        working = true
        Task {
            defer { working = false }
            let prompt: String
            var files: [String: Data] = [:]
            if isFirst {
                let guides = await harness.guides(for: kind, org: org, setup: setup)
                files = guides.mapValues { Data($0.utf8) }
                prompt = HarnessAuthoring.request(
                    kind: kind,
                    guidance: HarnessAuthoring.guidance(for: kind, config: configs.config(for: org), org: org),
                    ask: turns.filter { !$0.fromClaude }.map(\.text).joined(separator: "\n\n"), current: current(), guides: guides.keys.sorted(),
                    existing: (harness.index(for: org, setup)?.documents(kind) ?? []).filter { $0.summary != nil }
                ) + "\n\n" + Self.conversational
            } else {
                let editor = current().map { "\n\nWhat's in the editor now:\n\n\($0)" } ?? ""
                prompt = "\(text)\(editor)\n\nReply with only the JSON, as before."
            }
            do {
                let reply = try await ClaudeRunner.ask(
                    prompt, org: org, files: files, folder: "gannin-draft-\(conversation.uuidString)",
                    tools: ["Read", "Glob", "Grep"], session: (conversation.uuidString.lowercased(), !isFirst)
                )
                started = true
                guard let parsed = ClaudeRunner.json(HarnessAuthoring.Reply.self, in: reply) else {
                    // Not the JSON: it's talking, so show it as said.
                    turns.append(Turn(fromClaude: true, text: reply))
                    return
                }
                if parsed.hasDraft { apply(parsed) }
                turns.append(Turn(fromClaude: true, text: parsed.message ?? (parsed.hasDraft ? "Drafted. Check it over below." : "No changes.")))
            } catch {
                turns.append(Turn(fromClaude: true, text: error.localizedDescription))
                // A first message that failed starts afresh next time.
                if isFirst { conversation = UUID() }
            }
        }
    }
}

/// Settings › Harness: what Claude is asked when it drafts each kind of
/// document (a planning session's first prompt, for plans), Gannin's
/// default until it's changed. Kept with the team's settings, so in the
/// harness once the org keeps them there.
struct HarnessAuthoringSection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    @State private var kind: HarnessKind = .skills
    @State private var text = ""

    var body: some View {
        let config = configs.config(for: org)
        let saved = config.authoring?[kind.singular] ?? HarnessAuthoring.defaultGuidance(kind)
        Section {
            Picker("For", selection: $kind) {
                ForEach(HarnessKind.allCases.filter { !$0.isRecord }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 200)
            HStack {
                Text(HarnessAuthoring.isCustom(kind, config: config) ? "The org's own" : "Gannin's default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                WriteWithClaudeButton(purpose: .authoring(kind), text: text) { draft, _ in
                    text = draft
                    save()
                }
                Button("Restore Default") {
                    configs.update(org) { config in
                        config.authoring?[kind.singular] = nil
                        if config.authoring?.isEmpty == true { config.authoring = nil }
                    }
                    text = HarnessAuthoring.defaultGuidance(kind)
                }
                .disabled(!HarnessAuthoring.isCustom(kind, config: config))
                Button("Save", action: save)
                    .disabled(text == saved)
            }
        } header: {
            Text("Drafting with Claude")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { text = saved }
        .onChange(of: kind) { text = configs.config(for: org).authoring?[kind.singular] ?? HarnessAuthoring.defaultGuidance(kind) }
    }

    /// The editor's text as the org's guidance for the kind; Gannin's
    /// default, or nothing, clears it.
    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        configs.update(org) { config in
            if value.isEmpty || value == HarnessAuthoring.defaultGuidance(kind) {
                config.authoring?[kind.singular] = nil
                if config.authoring?.isEmpty == true { config.authoring = nil }
            } else {
                config.authoring = (config.authoring ?? [:]).merging([kind.singular: value]) { $1 }
            }
        }
    }

    private var footer: String {
        let placeholders = HarnessAuthoring.placeholders(kind).joined(separator: ", ")
        if kind == .plans {
            return "A planning session's first prompt, from Plan with Claude. \(placeholders) are filled in. Prompts picked from the library are added after it."
        }
        return "What Claude is told when it drafts a new \(kind.singular) from the Harness page. Gannin adds what you asked for, what's written so far, the harness's CLAUDE.md, STANDARDS.md and the folder's README and template, the \(kind.rawValue.lowercased()) already there, and the JSON reply it reads, so leave the format out. \(placeholders) are filled in."
    }
}

/// A document's details: its status, owner and domains, written into its
/// front matter and committed, leaving the rest of the file as it is.
struct HarnessDetailsEditor: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgStore.self) private var orgs
    @Environment(\.dismiss) private var dismiss
    let org: String
    let setup: HarnessConfig
    let document: HarnessDocument
    /// Its path in its own harness.
    let path: String

    @State private var status: String
    @State private var owner: String
    @State private var domains: String
    @State private var saving = false
    @State private var error: String?

    init(org: String, setup: HarnessConfig, document: HarnessDocument, path: String) {
        self.org = org
        self.setup = setup
        self.document = document
        self.path = path
        _status = State(initialValue: document.status ?? "")
        _owner = State(initialValue: document.owner ?? "")
        _domains = State(initialValue: (document.domains ?? []).joined(separator: ", "))
    }

    var body: some View {
        let members = (orgs.snapshot(for: org)?.members ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        // What it has now stays a choice even when it's not one of these.
        let statuses = HarnessDocumentDraft.statuses(document.kind)
        Form {
            Section {
                Picker("Status", selection: $status) {
                    Text("None").tag("")
                    if !status.isEmpty && !statuses.contains(status) { Text(document.statusLabel ?? status).tag(status) }
                    ForEach(statuses, id: \.self) { Text(HarnessDocumentDraft.statusTitle($0)).tag($0) }
                }
                Picker("Owner", selection: $owner) {
                    Text("Nobody").tag("")
                    if !owner.isEmpty && !members.contains(where: { $0.login == owner }) { Text(owner).tag(owner) }
                    ForEach(members) { Text("\($0.displayName) (\($0.login))").tag($0.login) }
                }
                TextField("Domains", text: $domains, prompt: Text("billing, data-capture"))
            } footer: {
                Text("Written into \(path)'s front matter and committed to \(setup.repo). The rest of the file is left as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("\(document.title) Details")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Committing" : "Commit to Harness") { save() }
                    .disabled(saving)
                    .help("Commits the change to \(path) in \(setup.repo)")
            }
        }
    }

    private func save() {
        let updates: [(key: String, value: HarnessFrontMatter.Value?)] = [
            ("status", status.isEmpty ? nil : .text(status)),
            ("owner", owner.isEmpty ? nil : .text(owner)),
            ("domains", .list(domains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })),
        ]
        let message = "Gannin: details of \(path)"
        saving = true
        error = nil
        Task {
            do {
                // Against the file at the head, so changes since survive.
                try await harness.commit(org: org, setup: setup) { head in
                    guard case let text?? = try await harness.files(setup: setup, at: head, paths: [path])[path] else {
                        throw HarnessDetailsError.missing(path)
                    }
                    let changed = HarnessFrontMatter.setting(updates, in: text)
                    return changed == text ? nil : HarnessChange(message: message, files: [path: changed])
                }
                dismiss()
            } catch let failure {
                error = failure.localizedDescription
            }
            saving = false
        }
    }
}

enum HarnessDetailsError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): "\(path) isn't in the harness any more."
        }
    }
}
