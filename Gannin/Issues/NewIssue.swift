import SwiftUI

// New Issue: an issue in a repo (or a draft item on a board), with its
// board fields, assignees, labels and parent, written in one go when
// Create is pressed. Claude can draft it with you, following the harness
// skills picked, and a repo's issue templates can start it.

// MARK: - Starting one

/// What a new issue starts with, from wherever it was asked for.
struct NewIssueContext: Identifiable {
    let id = UUID()
    let org: String
    var repo: String?
    /// The board it goes on, by number; nil for none.
    var board: Int?
    /// Board field values to start with, by field name (a column's Status).
    var fields: [String: String] = [:]
    var parent: IssueReference?
    /// The board view's filter, so its items can be fetched again after.
    var boardFilter: String?
}

/// Opens New Issue in this window.
struct NewIssueAction: Equatable {
    let window: UUID
    let perform: (NewIssueContext?) -> Void

    /// With nothing given, what the page it's asked from suggests.
    func callAsFunction(_ context: NewIssueContext? = nil) { perform(context) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.window == rhs.window }
}

extension EnvironmentValues {
    @Entry var newIssue: NewIssueAction?
}

extension FocusedValues {
    @Entry var newIssue: NewIssueAction?
}

/// File › New Issue, in the focused main window.
struct NewIssueCommand: View {
    @FocusedValue(\.newIssue) private var newIssue

    var body: some View {
        Button("New Issue") { newIssue?() }
            .keyboardShortcut("n")
            .disabled(newIssue == nil)
    }
}

/// File › New Window, which ⌘N had before New Issue took it (as Mail's
/// New Viewer Window is).
struct NewWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") { openWindow(id: "main") }
            .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

/// New Issue in a page's toolbar.
struct NewIssueButton: View {
    @Environment(\.newIssue) private var newIssue
    var context: NewIssueContext?

    var body: some View {
        if let newIssue {
            Button { newIssue(context) } label: {
                Label("New Issue", systemImage: "square.and.pencil")
            }
            .help("Write a new issue (⌘N)")
        }
    }
}

/// New Sub-issue, for an issue's context menu, where there's a window to
/// open it in.
struct NewSubIssueItem: View {
    @Environment(\.newIssue) private var newIssue
    let parent: IssueReference

    var body: some View {
        if let newIssue {
            Button("New Sub-issue") {
                newIssue(NewIssueContext(org: parent.org, repo: parent.repo, parent: parent))
            }
        }
    }
}

// MARK: - GitHub

/// A label a repo has.
struct RepoLabel: Hashable, Identifiable {
    let name: String
    let color: String

    var id: String { name }
}

/// One of a repo's issue templates (`.github/ISSUE_TEMPLATE`): Markdown,
/// or a form whose fields become headings.
struct IssueTemplate: Hashable, Identifiable {
    let file: String
    let name: String
    let about: String?
    let title: String
    let labels: [String]
    let assignees: [String]
    let body: String

    var id: String { file }

    /// Nil for what isn't a template (`config.yml`, other files).
    init?(file: String, text: String) {
        self.file = file
        let lower = file.lowercased()
        if lower.hasSuffix(".md") {
            let lines = text.components(separatedBy: "\n")
            let front = HarnessFrontMatter.parse(lines) ?? [:]
            name = front["name"]?.text ?? String(file.dropLast(3))
            about = front["about"]?.text
            title = front["title"]?.text ?? ""
            labels = Self.list(front["labels"])
            assignees = Self.list(front["assignees"])
            if front.isEmpty {
                body = text
            } else {
                // Everything after the closing `---`.
                let end = lines.dropFirst().firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" } ?? 0
                body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if (lower.hasSuffix(".yml") || lower.hasSuffix(".yaml")) && !lower.hasPrefix("config.") {
            // An issue form: its top-level facts, and each field's label as
            // a heading to write under.
            var name: String?, about: String?, title = "", labels: [String] = [], headings: [String] = []
            var inLabels = false
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isTop = !line.hasPrefix(" ") && !line.hasPrefix("-")
                if inLabels, trimmed.hasPrefix("- "), line.hasPrefix(" ") || line.hasPrefix("-") {
                    labels.append(Self.unquoted(String(trimmed.dropFirst(2))))
                    continue
                }
                inLabels = false
                if isTop, let value = Self.value(trimmed, key: "name") { name = value }
                else if isTop, let value = Self.value(trimmed, key: "description") { about = value }
                else if isTop, let value = Self.value(trimmed, key: "title") { title = value }
                else if isTop, let value = Self.value(trimmed, key: "labels") {
                    if value.isEmpty { inLabels = true } else { labels = Self.list(.text(value)) }
                } else if !isTop, let value = Self.value(trimmed, key: "label"), !value.isEmpty {
                    headings.append(value)
                }
            }
            guard let name else { return nil }
            self.name = name
            self.about = about
            self.title = title
            self.labels = labels
            assignees = []
            body = headings.map { "### \($0)\n\n" }.joined(separator: "\n")
        } else {
            return nil
        }
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return unquoted(String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func list(_ value: HarnessFrontMatter.Value?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .list(let items): return items
        case .text(let text):
            let inner = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
            return inner.split(separator: ",").map { unquoted(String($0)) }.filter { !$0.isEmpty }
        }
    }

    private static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

extension GitHubAPI {
    func repoLabels(_ repo: String) async throws -> [RepoLabel] {
        struct Response: Decodable {
            struct Label: Decodable { let name: String; let color: String }
            struct Repo: Decodable { let labels: Connection<Label> }
            let repository: Repo?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        let response: Response = try await query("""
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) { labels(first: 100, orderBy: { field: NAME, direction: ASC }) { nodes { name color } } }
            }
            """, variables: ["owner": parts[0], "name": parts[1]])
        return (response.repository?.labels.nodes ?? []).map { RepoLabel(name: $0.name, color: $0.color) }
    }

    func issueTemplates(_ repo: String) async throws -> [IssueTemplate] {
        struct Response: Decodable {
            struct Blob: Decodable { let text: String? }
            struct Entry: Decodable { let name: String; let object: Blob? }
            struct Tree: Decodable { let entries: [Entry]? }
            struct Repo: Decodable { let object: Tree? }
            let repository: Repo?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        let response: Response = try await query("""
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                object(expression: "HEAD:.github/ISSUE_TEMPLATE") {
                  ... on Tree { entries { name object { ... on Blob { text } } } }
                }
              }
            }
            """, variables: ["owner": parts[0], "name": parts[1]])
        return (response.repository?.object?.entries ?? [])
            .compactMap { entry in entry.object?.text.flatMap { IssueTemplate(file: entry.name, text: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Node IDs by login, for assigning.
    func userIDs(_ logins: [String]) async throws -> [String: String] {
        guard !logins.isEmpty else { return [:] }
        /// Anything without an ID (the injected rate limit, a login that's
        /// gone) reads as nil rather than failing the lot.
        struct Node: Decodable {
            let id: String?
            enum CodingKeys: String, CodingKey { case id }
            init(from decoder: Decoder) throws {
                id = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
            }
        }
        var fields: [String] = []
        for (index, login) in logins.enumerated() {
            fields.append("u\(index): user(login: \"\(login.filter { $0.isLetter || $0.isNumber || $0 == "-" })\") { id }")
        }
        let response: [String: Node?] = try await query("query { \(fields.joined(separator: " ")) }")
        var ids: [String: String] = [:]
        for (index, login) in logins.enumerated() {
            if let node = response["u\(index)"], let id = node?.id { ids[login] = id }
        }
        return ids
    }

    /// Adds an issue to a board, returning the item's ID. A write.
    func addToBoard(projectID: String, contentID: String) async throws -> String {
        struct Response: Decodable {
            struct Item: Decodable { let id: String }
            struct Payload: Decodable { let item: Item }
            let addProjectV2ItemById: Payload
        }
        let response: Response = try await mutate("""
            mutation($project: ID!, $content: ID!) {
              addProjectV2ItemById(input: { projectId: $project, contentId: $content }) { item { id } }
            }
            """, variables: ["project": projectID, "content": contentID])
        return response.addProjectV2ItemById.item.id
    }

    /// A draft item on a board, which lives only there until it's made an
    /// issue. Returns the item's ID. A write.
    func addDraftItem(projectID: String, title: String, body: String, assigneeIDs: [String]) async throws -> String {
        struct Response: Decodable {
            struct Item: Decodable { let id: String }
            struct Payload: Decodable { let projectItem: Item }
            let addProjectV2DraftIssue: Payload
        }
        var input: [String: Any] = ["projectId": projectID, "title": title, "body": body]
        if !assigneeIDs.isEmpty { input["assigneeIds"] = assigneeIDs }
        let response: Response = try await mutate("""
            mutation($input: AddProjectV2DraftIssueInput!) {
              addProjectV2DraftIssue(input: $input) { projectItem { id } }
            }
            """, variables: ["input": input])
        return response.addProjectV2DraftIssue.projectItem.id
    }
}

extension BoardField {
    /// Fields set per item: options, iterations, text, numbers and dates,
    /// not GitHub's own (title, assignees, labels and the rest).
    var isSettable: Bool { ["SINGLE_SELECT", "ITERATION", "TEXT", "NUMBER", "DATE"].contains(dataType) }

    var projectField: ProjectField {
        let options = options.map { ProjectField.Option(id: $0.id, name: $0.name, start: $0.start) }
        let kind: ProjectField.Kind = switch dataType {
        case "SINGLE_SELECT": .singleSelect(options)
        case "ITERATION": .iteration(options)
        case "NUMBER": .number
        case "DATE": .date
        default: .text
        }
        return ProjectField(id: id, name: name, kind: kind)
    }

    /// A value as the sheet holds it (an option's name, text, a number, a
    /// `2026-10-03` day) as GitHub takes it; nil when it doesn't fit.
    func value(from text: String) -> ProjectField.Value? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        switch dataType {
        case "SINGLE_SELECT", "ITERATION":
            return options.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }.map { .option($0.id) }
        case "NUMBER":
            return Double(text).map { .number($0) }
        case "DATE":
            return NewIssueSheet.day(from: text).map { .date($0) }
        default:
            return .text(text)
        }
    }
}

// MARK: - The sheet

/// Two columns: what it says (kind, repo, template, title, description,
/// and Claude drafting it with you) and where it goes (board and its
/// fields, assignees, labels, parent). Create writes it all, step by step.
struct NewIssueSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let context: NewIssueContext
    /// The new issue, to open; nil for a draft item.
    let created: (IssueReference?) -> Void

    enum Kind: String, CaseIterable {
        case issue = "Issue"
        case draft = "Draft on the board"
    }

    @State private var kind: Kind = .issue
    @State private var repo = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var board: Int?
    /// Board field values by name: an option or iteration's name, text, a
    /// number, or a day as `2026-10-03`.
    @State private var fields: [String: String] = [:]
    @State private var assignees: Set<String> = []
    @State private var labels: Set<String> = []
    @State private var parent: IssueReference?
    @State private var createAnother = false

    @State private var repoLabels: [RepoLabel] = []
    @State private var templates: [IssueTemplate] = []
    @State private var template: String?

    // Claude
    @State private var ask = ""
    @State private var skills: Set<String> = []
    @State private var conversation: [(ask: String, reply: String)] = []
    @State private var drafting = false

    @State private var steps: [String] = []
    @State private var working = false
    @State private var error: String?

    private var org: String { context.org }

    var body: some View {
        let boardDefinition = board.flatMap { projects.cache(org: org, number: $0)?.board }
        HStack(spacing: 0) {
            Form {
                whatSection
                if kind == .issue, !templates.isEmpty { templateSection }
                textSection
                claudeSection(board: boardDefinition)
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, maxWidth: .infinity)
            Divider()
            Form {
                boardSection(boardDefinition)
                peopleSection
                if !steps.isEmpty || error != nil { progressSection }
            }
            .formStyle(.grouped)
            .frame(width: 380)
        }
        .frame(minWidth: 900, idealWidth: 960, minHeight: 640, idealHeight: 760)
        .navigationTitle(context.parent.map { "New Sub-issue of #\($0.number)" } ?? "New Issue")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem {
                Toggle("Create Another", isOn: $createAnother)
                    .toggleStyle(.checkbox)
                    .help("Keep the sheet open for the next one, with the repo, board and parent kept")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Creating" : (kind == .issue ? "Create Issue" : "Add Draft")) { create(board: boardDefinition) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCreate)
                    .help(kind == .issue ? "Creates it in \(repo.isEmpty ? "the repo" : repo) on GitHub, then sets what's picked (⌘↩)" : "Adds it to the board as a draft item (⌘↩)")
            }
        }
        .onAppear(perform: start)
        .task(id: repo) { await loadRepo() }
        .task(id: board) {
            if let board { await projects.loadDefinition(org: org, number: board) }
        }
        .task { await harness.loadRepositories(org: org) }
    }

    private var canCreate: Bool {
        guard !working, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return kind == .issue ? !repo.isEmpty : board != nil
    }

    // MARK: Left: what it says

    private var whatSection: some View {
        Section {
            Picker("Make", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind == .issue {
                LabeledContent("Repository") {
                    SearchablePicker(choices: repoChoices, selection: repo.isEmpty ? nil : repo, prompt: "Search repositories", isLoading: harness.repositories[org] == nil) { picked in
                        if let picked { repo = picked }
                    }
                }
            }
        } footer: {
            if kind == .draft {
                Text(board == nil
                     ? "A draft lives only on a board: pick one on the right."
                     : "A draft lives only on the board until it's converted to an issue there. Gannin's issue pages see it once it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var templateSection: some View {
        Section {
            Picker("Template", selection: Binding(get: { template }, set: { apply(template: $0) })) {
                Text("None").tag(String?.none)
                ForEach(templates) { Text($0.name).tag(Optional($0.id)) }
            }
            if let about = templates.first(where: { $0.id == template })?.about {
                Text(about).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("From \(repo)'s .github/ISSUE_TEMPLATE. Picking one fills in its description, labels and assignees.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        Section {
            TextField("Title", text: $title, prompt: Text("Title"))
                .font(.title3)
            TextEditor(text: $bodyText)
                .font(.body.monospaced())
                .frame(minHeight: 240)
                .overlay(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text("Description, in Markdown")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: Claude

    private func claudeSection(board: Board?) -> some View {
        let library = skillLibrary
        return Section {
            ForEach(Array(conversation.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.ask).frame(maxWidth: .infinity, alignment: .trailing).foregroundStyle(.secondary)
                    Text(turn.reply).font(.callout)
                }
            }
            TextField("Ask Claude", text: $ask, prompt: Text(conversation.isEmpty ? "What's it about? A rough line is enough." : "What to change"), axis: .vertical)
                .lineLimit(2...6)
            HStack {
                if !library.isEmpty {
                    Menu {
                        ForEach(library) { skill in
                            Toggle(isOn: Binding(get: { skills.contains(skill.path) }, set: { on in
                                if on { skills.insert(skill.path) } else { skills.remove(skill.path) }
                            })) {
                                Text(skill.name)
                                if let summary = skill.summary { Text(summary) }
                            }
                        }
                    } label: {
                        Label(skills.isEmpty ? "Skills" : "Skills: \(skills.count)", systemImage: "sparkles")
                    }
                    .fixedSize()
                    .help("Harness skills Claude follows while drafting")
                }
                Spacer()
                if drafting { ProgressView().controlSize(.small) }
                Button(conversation.isEmpty ? "Draft with Claude" : "Revise") { draft(board: board) }
                    .disabled(drafting || ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Draft with Claude")
        } footer: {
            Text("Claude writes the title, description and labels, and suggests board fields, from what you say, what's written so far, the template and the skills picked. Ask again to change it. Nothing's sent to GitHub until you create it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Right: where it goes

    private func boardSection(_ definition: Board?) -> some View {
        let boards = projects.boards(org: org, repo: configs.config(for: org).boardsRepo)
        return Section {
            Picker("Board", selection: $board) {
                Text("None").tag(Int?.none)
                ForEach(boards.contains { $0.number == board } || board == nil ? boards : boards + [OrgProject(id: "", number: board ?? 0, title: "Board \(board ?? 0)")]) {
                    Text($0.title).tag(Optional($0.number))
                }
            }
            if board != nil {
                if let definition {
                    ForEach(definition.fields.filter(\.isSettable)) { field in
                        fieldRow(field)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Loading its fields").foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Board")
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: BoardField) -> some View {
        let binding = Binding(get: { fields[field.name] ?? "" }, set: { fields[field.name] = $0.isEmpty ? nil : $0 })
        switch field.dataType {
        case "SINGLE_SELECT", "ITERATION":
            Picker(field.name, selection: binding) {
                Text("None").tag("")
                ForEach(field.options) { option in
                    Text(option.name).tag(option.name)
                }
            }
        case "DATE":
            LabeledContent(field.name) {
                HStack {
                    if let day = Self.day(from: binding.wrappedValue, in: .current) {
                        DatePicker(field.name, selection: Binding(get: { day }, set: { binding.wrappedValue = Self.dayText($0) }), displayedComponents: .date)
                            .labelsHidden()
                        Button { binding.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button("Set") { binding.wrappedValue = Self.dayText(.now) }
                    }
                }
            }
        default:
            TextField(field.name, text: binding, prompt: Text(field.dataType == "NUMBER" ? "0" : ""))
        }
    }

    private var peopleSection: some View {
        let members = (orgs.snapshot(for: org)?.members ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return Section {
            LabeledContent("Assignees") {
                Menu {
                    ForEach(members) { person in
                        Toggle("\(person.displayName) (\(person.login))", isOn: Binding(get: { assignees.contains(person.login) }, set: { on in
                            if on { assignees.insert(person.login) } else { assignees.remove(person.login) }
                        }))
                    }
                } label: {
                    Text(assignees.isEmpty ? "Nobody" : assignees.sorted().joined(separator: ", ")).lineLimit(1)
                }
                .fixedSize()
            }
            if kind == .issue {
                LabeledContent("Labels") {
                    Menu {
                        if repoLabels.isEmpty { Text(repo.isEmpty ? "Pick a repository first" : "\(repo) has no labels") }
                        ForEach(repoLabels) { label in
                            Toggle(label.name, isOn: Binding(get: { labels.contains(label.name) }, set: { on in
                                if on { labels.insert(label.name) } else { labels.remove(label.name) }
                            }))
                        }
                    } label: {
                        Text(labels.isEmpty ? "None" : labels.sorted().joined(separator: ", ")).lineLimit(1)
                    }
                    .fixedSize()
                }
                LabeledContent("Parent") {
                    SearchablePicker(choices: parentChoices, selection: parent?.id, prompt: "Search open issues") { id in
                        parent = id.flatMap(reference(for:))
                    }
                }
            }
        } header: {
            Text("Details")
        }
    }

    private var progressSection: some View {
        Section {
            ForEach(steps, id: \.self) { step in
                Label(step, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
    }

    // MARK: Choices

    /// With a project picked, its repos (and the one it was started with,
    /// a parent's say); else those with issues first, then the rest.
    private var repoChoices: [SearchableChoice] {
        let config = configs.config(for: org)
        let own = config.scope?.repos ?? []
        if !own.isEmpty {
            let started = [context.repo, context.parent?.repo].compactMap { $0 }.filter { !own.contains($0) }
            return (own + Array(Set(started))).map { SearchableChoice(value: $0, title: $0) }
        }
        let issues = issueStore.history(for: org).map { Array($0.issues.values) } ?? []
        let busy = Dictionary(grouping: issues, by: \.repo).mapValues(\.count)
            .sorted { $0.value > $1.value }.map(\.key)
            .filter { !own.contains($0) && !config.repoExclusion.contains($0) }
        let rest = Set(harness.repositories[org] ?? []).subtracting(own).subtracting(busy)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return own.map { SearchableChoice(value: $0, title: $0, section: config.scope?.name) }
            + busy.map { SearchableChoice(value: $0, title: $0, section: "With issues") }
            + rest.map { SearchableChoice(value: $0, title: $0, section: "Every other repo") }
    }

    private var openIssues: [IssueRecord] {
        let exclusion = configs.config(for: org).repoExclusion
        return (issueStore.history(for: org).map { Array($0.issues.values) } ?? [])
            .filter { $0.isOpen && !exclusion.contains($0.repo) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var parentChoices: [SearchableChoice] {
        [SearchableChoice(value: nil, title: "None")]
            + openIssues.map { SearchableChoice(value: $0.id, title: "\($0.repo.split(separator: "/").last ?? "")#\($0.number) \($0.title)") }
    }

    private func reference(for id: String) -> IssueReference? {
        if parent?.id == id { return parent }
        guard let issue = issueStore.history(for: org)?.issues[id] else { return nil }
        return IssueReference(org: org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url)
    }

    /// The harness's skills, from the harness work in the repo runs in.
    private var skillLibrary: [HarnessSkill] {
        let config = configs.config(for: org)
        guard let setup = config.harness(covering: repo.isEmpty ? [] : [repo]) else { return [] }
        return HarnessPromptLibrary(index: harness.index(for: org, setup)).skills
    }

    // MARK: Starting

    private func start() {
        let config = configs.config(for: org)
        repo = context.repo ?? context.parent?.repo ?? config.scope?.repos.first ?? repoChoices.first?.value ?? ""
        board = context.board ?? config.workflow.projectNumber
        fields = context.fields
        parent = context.parent
        // Skills about issues, ticked to start with.
        skills = Set(skillLibrary.filter { "\($0.name) \($0.summary ?? "")".localizedCaseInsensitiveContains("issue") }.map(\.path))
    }

    private func loadRepo() async {
        repoLabels = []
        templates = []
        template = nil
        guard let api = auth.api, !repo.isEmpty else { return }
        async let labelList = try? api.repoLabels(repo)
        async let templateList = try? api.issueTemplates(repo)
        repoLabels = await labelList ?? []
        templates = await templateList ?? []
        // Labels picked that this repo doesn't have go.
        labels = labels.filter { label in repoLabels.contains { $0.name == label } }
    }

    private func apply(template id: String?) {
        template = id
        guard let picked = templates.first(where: { $0.id == id }) else { return }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = picked.title }
        bodyText = picked.body
        labels.formUnion(picked.labels.filter { name in repoLabels.contains { $0.name == name } })
        assignees.formUnion(picked.assignees)
    }

    // MARK: Drafting

    private struct Draft: Decodable {
        let repo: String?
        let title: String?
        let body: String?
        let labels: [String]?
        let fields: [String: String]?
        let note: String?
    }

    private func draft(board: Board?) {
        let request = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        drafting = true
        let library = skillLibrary.filter { skills.contains($0.path) }
        let config = configs.config(for: org)
        let setup = config.harness(covering: repo.isEmpty ? [] : [repo])
        let index = setup.flatMap { harness.index(for: org, $0) }
        var files: [String: Data] = [:]
        for skill in library {
            if let text = index?.document(at: skill.path)?.text { files[skill.path] = Data(text.utf8) }
        }
        let settable = (board?.fields ?? []).filter(\.isSettable)
        var parts = ["Draft a GitHub issue with me, for \(org). What I want: \(request)"]
        if !conversation.isEmpty || !title.isEmpty || !bodyText.isEmpty {
            parts.append("What's written so far, to improve on rather than start over (keep what I wrote unless I ask otherwise):\n\nTitle: \(title)\n\n\(bodyText)")
        }
        if kind == .issue {
            parts.append("The repo is \(repo.isEmpty ? "not picked yet; pick one of: \(repoChoices.prefix(20).compactMap(\.value).joined(separator: ", "))" : repo).")
            if !repoLabels.isEmpty { parts.append("Labels the repo has (use only these): \(repoLabels.map(\.name).joined(separator: ", ")).") }
        }
        if let picked = templates.first(where: { $0.id == template }) {
            parts.append("Follow the repo's \(picked.name) template: keep its headings.\n\n\(picked.body)")
        }
        if let board, !settable.isEmpty {
            let lines = settable.map { field in
                field.options.isEmpty ? "- \(field.name) (\(field.dataType.lowercased()))" : "- \(field.name): \(field.options.map(\.name).joined(separator: ", "))"
            }
            parts.append("It goes on the board \(board.title). Suggest values only where you can tell, from these:\n\(lines.joined(separator: "\n"))")
        }
        if let parent {
            parts.append("It's a sub-issue of \(parent.repo)#\(parent.number): \(parent.title).")
        }
        if !files.isEmpty {
            parts.append("Follow these skills from the team's harness, in this folder at the same paths: \(files.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")). Read them first.")
        }
        parts.append(#"Don't invent details: say in the description what's unknown. Reply with only JSON: {"repo": "owner/name", "title": "...", "body": "<Markdown>", "labels": ["..."], "fields": {"Field": "value"}, "note": "one line to me: what you did or what you need to know"}"#)
        let prompt = parts.joined(separator: "\n\n")
        Task {
            defer { drafting = false }
            do {
                let reply = try await ClaudeRunner.ask(prompt, org: org, files: files, tools: files.isEmpty ? [] : ["Read", "Glob", "Grep"])
                guard let draft = ClaudeRunner.json(Draft.self, in: reply) else {
                    conversation.append((request, "That reply wasn't a draft. Say a little more and try again."))
                    return
                }
                if kind == .issue, let suggested = draft.repo, repo.isEmpty || conversation.isEmpty, repoChoices.contains(where: { $0.value == suggested }) {
                    repo = suggested
                }
                if let value = draft.title, !value.isEmpty { title = value }
                if let value = draft.body, !value.isEmpty { bodyText = value }
                if let value = draft.labels { labels = Set(value.filter { name in repoLabels.contains { $0.name == name } }) }
                for (name, value) in draft.fields ?? [:] {
                    if let field = settable.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }), field.value(from: value) != nil {
                        fields[field.name] = field.options.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.name ?? value
                    }
                }
                conversation.append((request, draft.note ?? "Drafted. Check it over."))
                ask = ""
            } catch {
                conversation.append((request, error.localizedDescription))
            }
        }
    }

    // MARK: Creating

    private func create(board definition: Board?) {
        guard let api = auth.api else { return }
        working = true
        steps = []
        error = nil
        let title = title.trimmingCharacters(in: .whitespaces)
        let boardID = board.flatMap { number in projects.allBoardLists[org]?.first { $0.number == number }?.id } ?? definition?.id
        Task {
            defer { working = false }
            do {
                let people = try await api.userIDs(assignees.sorted())
                var reference: IssueReference?
                var itemID: String?
                if kind == .issue {
                    let issue = try await api.createIssue(repo: repo, title: title, body: bodyText, labels: labels.sorted(), assigneeIDs: Array(people.values))
                    reference = IssueReference(org: org, id: issue.id, number: issue.number, title: title, repo: repo, url: issue.url)
                    steps.append("Created \(repo)#\(issue.number)")
                    if let parent {
                        try await api.addSubIssue(parent: parent.id, child: issue.id)
                        steps.append("Made it a sub-issue of #\(parent.number)")
                    }
                    if let boardID {
                        itemID = try await api.addToBoard(projectID: boardID, contentID: issue.id)
                        steps.append("Added it to \(definition?.title ?? "the board")")
                    }
                } else if let boardID {
                    itemID = try await api.addDraftItem(projectID: boardID, title: title, body: bodyText, assigneeIDs: Array(people.values))
                    steps.append("Added a draft to \(definition?.title ?? "the board")")
                }
                if let itemID, let boardID, let definition {
                    for field in definition.fields.filter(\.isSettable) {
                        guard let text = fields[field.name], let value = field.value(from: text) else { continue }
                        try await api.setProjectField(projectID: boardID, itemID: itemID, field: field.projectField, value: value)
                        steps.append("Set \(field.name) to \(text)")
                    }
                }
                if let number = board {
                    await projects.sync(org: org, number: number, filter: context.boardFilter ?? "", force: true)
                }
                if createAnother {
                    self.title = ""
                    bodyText = ""
                    template = nil
                    conversation = []
                } else {
                    dismiss()
                    created(reference)
                }
            } catch {
                self.error = "GitHub didn't take it: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Days

    /// A `2026-10-03` day as midnight in a time zone: UTC for GitHub, this
    /// Mac's for the date picker.
    static func day(from text: String, in zone: TimeZone = TimeZone(identifier: "UTC") ?? .gmt) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The day a date picker's date falls on here.
    static func dayText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
