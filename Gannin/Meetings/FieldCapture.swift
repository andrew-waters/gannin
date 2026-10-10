import SwiftUI

/// Beside Prioritisation's lists: find and add. What CS raises goes in one
/// box, which searches open issues' titles, descriptions and comments as
/// it's typed; a match is added with the point linked to it, else the point
/// is added on its own or raised as a new issue (Claude's draft). Who raised
/// it and the customer are remembered; kind and urgency go with it. Below,
/// the open points by urgency, each linked to an issue, raised as one, or
/// ticked off; today's ticked ones after.
struct FieldCapturePanel: View {
    @Environment(FieldNotesStore.self) private var fieldNotes
    @Environment(IssueStore.self) private var issueStore
    let org: String
    let workload: Workload
    @Binding var selection: DetailSelection?

    @AppStorage("fieldNoteFrom") private var from = "Sam"
    @State private var text = ""
    @State private var customer = ""
    @State private var kind: FieldNote.Kind?
    @State private var urgency: FieldNote.Urgency = .soon
    @State private var linking: FieldNote?
    @State private var raising: FieldNote?
    /// Matches for what's typed, from the search index.
    @State private var hits: [IssueTextHit] = []
    @FocusState private var focused: Bool

    /// What's typed, once it's enough to search on.
    private var query: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 ? trimmed : ""
    }

    /// Open issues matching what's typed: the index's best first, then
    /// any matching by number, label or person it didn't find.
    private var matches: [(record: IssueRecord, snippet: String?)] {
        guard !query.isEmpty, let history = issueStore.history(for: org) else { return [] }
        var seen: Set<String> = []
        var found: [(record: IssueRecord, snippet: String?)] = []
        for hit in hits {
            guard let record = history.issues[hit.id], record.isOpen, seen.insert(record.id).inserted else { continue }
            found.append((record, hit.snippet))
        }
        if found.count < 8 {
            let local = history.issues.values
                .filter { $0.isOpen && !seen.contains($0.id) && IssueSearch.matches(query, record: $0) }
                .sorted { $0.createdAt > $1.createdAt }
            found += local.prefix(8 - found.count).map { ($0, nil) }
        }
        return Array(found.prefix(8))
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let all = fieldNotes.notes(for: org)
        let open = all.filter { $0.doneAt == nil }.sorted { ($0.urgency ?? .soon, $1.raisedAt) < ($1.urgency ?? .soon, $0.raisedAt) }
        let doneToday = all.filter { ($0.doneAt ?? .distantPast) >= today }
        VStack(spacing: 0) {
            capture
            Divider()
            List {
                Section(header: SectionHeader(title: "From the field", count: open.count)) {
                    if open.isEmpty {
                        Text("Nothing open. What's heard goes above, and stays until it's dealt with.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(open) { note in row(note) }
                }
                if !doneToday.isEmpty {
                    Section(header: SectionHeader(title: "Dealt with today", count: doneToday.count)) {
                        ForEach(doneToday) { note in row(note) }
                    }
                }
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            guard !query.isEmpty else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hits = await IssueTextIndex.shared.search(org: org, text: query, limit: 20)
        }
        .popover(item: $linking) { note in
            LinkIssuePopover(org: org) { issue in
                fieldNotes.update(note.id, in: org) { $0.issue = issue }
                linking = nil
            }
        }
        .sheet(item: $raising) { note in
            WriteIssueSheet(org: org, note: note) { issue in
                if fieldNotes.notes(for: org).contains(where: { $0.id == note.id }) {
                    fieldNotes.update(note.id, in: org) { $0.issue = issue }
                } else {
                    // Raised straight from the box: the point goes in with it.
                    var added = note
                    added.issue = issue
                    fieldNotes.add(added, in: org)
                    clear()
                }
            }
        }
    }

    // MARK: Capture

    private var capture: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Find and add", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
                TextField("From", text: $from)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 110)
                    .help("Who's raising it; kept for the next note")
            }
            TextField("What's being raised? Matching issues show as you type", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...6)
                .focused($focused)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(add)
            if !query.isEmpty {
                foundList
            }
            // Two rows, so it fits the panel at its narrowest.
            HStack(spacing: 8) {
                TextField("Customer", text: $customer)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        let known = fieldNotes.customers(in: org)
                        if !known.isEmpty {
                            Menu {
                                ForEach(known.prefix(20), id: \.self) { name in
                                    Button(name) { customer = name }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(.trailing, 4)
                        }
                    }
                Picker("Kind", selection: $kind) {
                    Text("Kind").tag(FieldNote.Kind?.none)
                    ForEach(FieldNote.Kind.allCases, id: \.self) { kind in
                        Label(kind.rawValue, systemImage: kind.systemImage).tag(FieldNote.Kind?.some(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 8) {
                Picker("Urgency", selection: $urgency) {
                    ForEach(FieldNote.Urgency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button("Raise as Issue") { raising = draftNote() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Write it up as a new issue, with Claude's draft")
                Button("Add as New Point", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add it to the points from the field, linked to nothing yet (⌘↩)")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// The issues that match, each with Add: the point, linked to it.
    private var foundList: some View {
        let found = matches
        return VStack(alignment: .leading, spacing: 6) {
            Text(found.isEmpty ? "No open issue matches. Add it as a new point, or raise it as an issue." : "Already raised? Add the point to one of these")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(found, id: \.record.id) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        selection = .issueReference(IssueReference(org: org, record: item.record))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.record.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                            HStack(spacing: 4) {
                                Text("\(item.record.repo.split(separator: "/").last ?? "")#\(String(item.record.number))")
                                if let status = item.record.statusChanges.last?.status { Text("· \(status)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let snippet = item.snippet, !snippet.isEmpty {
                                Text(PrioritisationSearchHighlight.highlighted(snippet))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open it")
                    Button("Add") { addLinked(item.record) }
                        .controlSize(.small)
                        .help("Add the point, linked to this issue")
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// The point as typed, with who, customer, kind and urgency.
    private func draftNote(linkedTo issue: FieldNote.LinkedIssue? = nil) -> FieldNote {
        FieldNote(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), raisedAt: .now,
            from: from.isEmpty ? nil : from,
            customer: customer.trimmingCharacters(in: .whitespaces).isEmpty ? nil : customer.trimmingCharacters(in: .whitespaces),
            kind: kind, urgency: urgency, issue: issue
        )
    }

    private func addLinked(_ record: IssueRecord) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        fieldNotes.add(draftNote(linkedTo: .init(id: record.id, repo: record.repo, number: record.number, title: record.title, url: record.url)), in: org)
        clear()
    }

    private func clear() {
        text = ""
        kind = nil
        urgency = .soon
        hits = []
        focused = true
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        fieldNotes.add(draftNote(), in: org)
        clear()
    }


    // MARK: Notes

    private func row(_ note: FieldNote) -> some View {
        let done = note.doneAt != nil
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill((note.urgency ?? .soon).color)
                .frame(width: 3)
            Toggle("", isOn: Binding(get: { done }, set: { fieldNotes.setDone(note.id, $0, in: org) }))
                .labelsHidden()
                .checkboxToggle()
            VStack(alignment: .leading, spacing: 4) {
                Text(note.text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let kind = note.kind { Label(kind.rawValue, systemImage: kind.systemImage) }
                    if let customer = note.customer { Text(customer).fontWeight(.medium) }
                    if let from = note.from { Text("from \(from)") }
                    Text(Calendar.current.isDateInToday(note.raisedAt) ? note.raisedAt.formatted(date: .omitted, time: .shortened) : note.raisedAt.formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let issue = note.issue {
                    Button {
                        selection = .issueReference(IssueReference(org: org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url))
                    } label: {
                        Label("\(issue.repo.split(separator: "/").last ?? "")#\(String(issue.number)) \(issue.title)", systemImage: "link")
                            .lineLimit(1)
                    }
                    .linkButton()
                    .font(.caption)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Link to Issue") { linking = note }
                Button("Raise as Issue") { raising = note }
                    .disabled(note.issue != nil)
                if note.issue != nil {
                    Button("Unlink Issue") { fieldNotes.update(note.id, in: org) { $0.issue = nil } }
                }
                Divider()
                Menu("Urgency") {
                    ForEach(FieldNote.Urgency.allCases, id: \.self) { value in
                        Button(value.rawValue) { fieldNotes.update(note.id, in: org) { $0.urgency = value } }
                    }
                }
                Divider()
                Button("Remove", role: .destructive) { fieldNotes.remove(note.id, in: org) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}

/// Picks an open issue to link a note to, by search.
private struct LinkIssuePopover: View {
    @Environment(IssueStore.self) private var issueStore
    let org: String
    let pick: (FieldNote.LinkedIssue) -> Void
    @State private var search = ""

    var body: some View {
        let issues = (issueStore.history(for: org).map { Array($0.issues.values) } ?? [])
            .filter { $0.isOpen && IssueSearch.matches(search, record: $0) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(30)
        VStack(alignment: .leading, spacing: 8) {
            FilterSearchField(text: $search, prompt: "Find an issue")
            List(Array(issues)) { issue in
                Button {
                    pick(.init(id: issue.id, repo: issue.repo, number: issue.number, title: issue.title, url: issue.url))
                } label: {
                    HStack {
                        Text("#\(String(issue.number))").foregroundStyle(.secondary).monospacedDigit()
                        Text(issue.title).lineLimit(1)
                        Spacer()
                        Text(issue.repo.split(separator: "/").last.map(String.init) ?? "").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 460, height: 320)
        }
        .padding(12)
    }
}

/// An issue written from a note: Claude drafts the repo, title, body and
/// labels from what was heard and the org's repos and labels, then it's
/// yours to edit, with any images (committed to the project's harness and
/// shown in it, `IssueImages`). Create makes it on GitHub (a write) and puts
/// it on the workflow board with no Status, so it lands in Triage.
struct WriteIssueSheet: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    let note: FieldNote
    let created: (FieldNote.LinkedIssue) -> Void

    @State private var repo = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var labels = ""
    @State private var addToBoard = true
    @State private var drafting = false
    @State private var creating = false
    @State private var status: String?
    @State private var images = IssueImageSet()

    private struct Draft: Decodable {
        let repo: String?
        let title: String
        let body: String
        let labels: [String]?
    }

    var body: some View {
        let repos = knownRepos
        Form {
            Section {
                Text(note.text).foregroundStyle(.secondary)
            } header: {
                Text("Heard\(note.customer.map { " from \($0)" } ?? "")")
            }
            Section {
                Picker("Repository", selection: $repo) {
                    ForEach(repos.contains(repo) || repo.isEmpty ? repos : [repo] + repos, id: \.self) { Text($0).tag($0) }
                }
                TextField("Title", text: $title)
                TextField("Description", text: $bodyText, axis: .vertical)
                    .lineLimit(6...16)
                TextField("Labels", text: $labels, prompt: Text("bug, customer"))
                if configs.config(for: org).workflow.projectNumber != nil {
                    Toggle("Add to the board, for triage", isOn: $addToBoard)
                }
            } footer: {
                if drafting {
                    HStack { ProgressView().controlSize(.small); Text("Claude is drafting it") }
                } else if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            IssueImagesSection(images: images, harness: imageHarness, repo: repo)
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 720)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem {
                Button("Draft Again") { draft() }.disabled(drafting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(creating ? "Creating" : IssueImages.createTitle("Create Issue", count: images.count)) { create() }
                    .disabled(creating || repo.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || (!images.isEmpty && imageHarness == nil))
            }
        }
        .onAppear {
            repo = repos.first ?? ""
            title = String(note.text.prefix(80))
            bodyText = note.text
            draft()
        }
    }

    /// The harness images are committed to: the one work in the repo runs in.
    private var imageHarness: HarnessConfig? {
        configs.config(for: org).harness(covering: repo.isEmpty ? [] : [repo])
    }

    /// Repos with the most issues first.
    private var knownRepos: [String] {
        let issues = issueStore.history(for: org).map { Array($0.issues.values) } ?? []
        let counts = Dictionary(grouping: issues, by: \.repo).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.map(\.key).filter { !configs.config(for: org).repoExclusion.contains($0) }
    }

    private func draft() {
        drafting = true
        let issues = issueStore.history(for: org).map { Array($0.issues.values) } ?? []
        let labelsSeen = Dictionary(grouping: issues.flatMap(\.labels), by: { $0 }).sorted { $0.value.count > $1.value.count }.prefix(40).map(\.key)
        let examples = issues.filter { $0.isOpen }.sorted { $0.createdAt > $1.createdAt }.prefix(8).map { "- \($0.repo): \($0.title)" }
        let prompt = """
            Customer success raised this in our prioritisation meeting. Write it up as a GitHub issue an engineer can pick up: a clear title, and a description with what was reported, who it affects, what's expected, and open questions. Don't invent details; say what's unknown.

            Heard\(note.from.map { " from \($0)" } ?? "")\(note.customer.map { ", about the customer \($0)" } ?? "")\(note.kind.map { ", a \($0.rawValue.lowercased())" } ?? "")\(note.urgency.map { ", urgency \($0.rawValue.lowercased())" } ?? ""):
            \(note.text)

            Pick the repo from these (the first ones hold most issues): \(knownRepos.prefix(15).joined(separator: ", "))
            Labels in use: \(labelsSeen.joined(separator: ", "))
            Recent issues, for the house style:
            \(examples.joined(separator: "\n"))

            Reply with only JSON: {"repo": "owner/name", "title": "...", "body": "<Markdown>", "labels": ["..."]}
            """
        Task {
            do {
                let reply = try await ClaudeRunner.ask(prompt, org: org)
                if let draft = ClaudeRunner.json(Draft.self, in: reply) {
                    if let suggested = draft.repo, knownRepos.contains(suggested) { repo = suggested }
                    title = draft.title
                    bodyText = draft.body
                    labels = (draft.labels ?? []).joined(separator: ", ")
                    status = "Claude's draft: check it over."
                } else {
                    status = "Claude's reply wasn't a draft; write it yourself or draft again."
                }
            } catch {
                status = error.localizedDescription
            }
            drafting = false
        }
    }

    private func create() {
        guard let api = auth.api else { return }
        creating = true
        let labelList = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            do {
                var links: [(name: String, url: URL)] = []
                if !images.isEmpty, let setup = imageHarness {
                    links = try await images.commit(org: org, repo: repo, setup: setup, harness: harness)
                }
                let issue = try await api.createIssue(repo: repo, title: title, body: IssueImages.body(bodyText, links: links), labels: labelList)
                if addToBoard, let number = configs.config(for: org).workflow.projectNumber,
                   let boardID = projects.boardLists[org]?.first(where: { $0.number == number })?.id {
                    try? await api.addToProject(projectID: boardID, contentID: issue.id)
                }
                created(.init(id: issue.id, repo: repo, number: issue.number, title: title, url: issue.url))
                dismiss()
            } catch {
                status = "GitHub didn't take it: \(error.localizedDescription)"
            }
            creating = false
        }
    }
}
