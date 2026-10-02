#if os(macOS)
import SwiftUI

/// Requirement to Issues: Claude reads a plan or requirement from the
/// harness and proposes the issues to build it (each with a repo, title,
/// description and labels), under the issue the document is about or a
/// new parent. Every one is yours to edit, untick or keep; Create makes them
/// on GitHub as sub-issues of the parent and puts them on the workflow
/// board for triage, confirmed first and ticked off as they're made.
struct DraftIssuesSheet: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    let document: HarnessDocument
    let index: HarnessIndex

    struct Draft: Identifiable {
        let id = UUID()
        var include = true
        var repo: String
        var title: String
        var body: String
        var labels: String
        var made: URL?
        var failed: String?
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let title: String
            let body: String
            let repo: String?
            let labels: [String]?
        }
        let parent: Item?
        let issues: [Item]
    }

    @State private var drafts: [Draft] = []
    @State private var newParent: Draft?
    /// Under the issue the document is about, when it's about one.
    @State private var useExistingParent = true
    @State private var working = true
    @State private var creating = false
    @State private var confirming = false
    @State private var status: String?

    private var existingParent: HarnessReference? { document.subjects.first }

    private var repos: [String] {
        let issues = issueStore.history(for: org).map { Array($0.issues.values) } ?? []
        return Dictionary(grouping: issues, by: \.repo).mapValues(\.count).sorted { $0.value > $1.value }.map(\.key)
            .filter { !configs.config(for: org).excludedRepos.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Issues for \(document.title)").font(.headline).lineLimit(1)
                Spacer()
                if working { ProgressView().controlSize(.small); Text("Claude is reading the \(document.kind.singular)").foregroundStyle(.secondary) }
            }
            .padding(12)
            Divider()
            Form {
                Section("Parent") {
                    if let existing = existingParent {
                        Toggle("Under \(existing.repo ?? index.issuesRepo ?? "")#\(existing.number), the issue it's about", isOn: $useExistingParent)
                    }
                    if !useExistingParent || existingParent == nil, let parent = Binding($newParent) {
                        editor(parent, isParent: true)
                    } else if existingParent == nil {
                        Text("No parent: the issues are made on their own.").foregroundStyle(.secondary)
                    }
                }
                Section("\(drafts.filter(\.include).count) of \(drafts.count) issues") {
                    ForEach($drafts) { $draft in
                        editor($draft, isParent: false)
                    }
                    Button("Add Issue") { drafts.append(Draft(repo: repos.first ?? "", title: "", body: "", labels: "")) }
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(drafts.contains { $0.made != nil } ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? "Creating" : "Create \(drafts.filter { $0.include && $0.made == nil }.count) Issues") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || creating || drafts.filter { $0.include && $0.made == nil }.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 600, idealHeight: 760)
        .task { await draft() }
        .confirmationDialog("Create these issues on GitHub?", isPresented: $confirming) {
            Button("Create Issues") { Task { await create() } }
        } message: {
            Text("\(drafts.filter { $0.include && $0.made == nil }.count) issues are made\(useExistingParent && existingParent != nil ? " as sub-issues of \(existingParent!.repo ?? index.issuesRepo ?? "")#\(existingParent!.number)" : newParent != nil ? ", under a new parent issue" : "")\(configs.config(for: org).workflow.projectNumber != nil ? ", and added to the board for triage" : "").")
        }
    }

    private func editor(_ draft: Binding<Draft>, isParent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !isParent {
                    Toggle("", isOn: draft.include).labelsHidden().checkboxToggle()
                }
                TextField("Title", text: draft.title)
                    .fontWeight(.medium)
                Picker("", selection: draft.repo) {
                    ForEach(repos.contains(draft.wrappedValue.repo) ? repos : [draft.wrappedValue.repo] + repos, id: \.self) {
                        Text($0.split(separator: "/").last.map(String.init) ?? $0).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let made = draft.wrappedValue.made {
                    Link(destination: made) { Image(systemName: "checkmark.circle.fill").foregroundStyle(ChartPalette.good) }
                }
            }
            TextField("Description", text: draft.body, axis: .vertical)
                .lineLimit(2...8)
                .foregroundStyle(.secondary)
            TextField("Labels", text: draft.labels)
                .font(.caption)
            if let failed = draft.wrappedValue.failed {
                Text(failed).font(.caption).foregroundStyle(.red)
            }
        }
        .opacity(draft.wrappedValue.include || isParent ? 1 : 0.5)
        .disabled(draft.wrappedValue.made != nil)
    }

    private func draft() async {
        let prompt = """
            This is a \(document.kind.singular) from our team's harness repo (\(document.path)). Break it into GitHub issues an engineer, or an AI coding agent, could each pick up and finish: one deliverable each, in the order they'd be done, with a description that says what to do, how it'll be checked, and links back to the \(document.kind.singular). Pick each one's repo from: \(repos.prefix(15).joined(separator: ", ")). \(existingParent == nil ? "Also propose a parent issue for them all." : "They'll go under the issue the document is about.")

            Reply with only JSON: {"parent": {"title": "...", "body": "..."} or null, "issues": [{"title": "...", "body": "<Markdown>", "repo": "owner/name", "labels": ["..."]}]}

            The \(document.kind.singular):

            \(document.text.prefix(40_000))
            """
        do {
            let reply = try await ClaudeRunner.ask(prompt, org: org)
            guard let parsed = ClaudeRunner.json(Reply.self, in: reply) else {
                status = "Claude's reply wasn't a list of issues. Add them by hand, or close and try again."
                working = false
                return
            }
            let link = index.url(for: document).map { "\n\nFrom [\(document.title)](\($0.absoluteString))." } ?? ""
            drafts = parsed.issues.map {
                Draft(repo: $0.repo.flatMap { repos.contains($0) ? $0 : nil } ?? repos.first ?? "", title: $0.title, body: $0.body + link, labels: ($0.labels ?? []).joined(separator: ", "))
            }
            if let parent = parsed.parent {
                newParent = Draft(repo: repos.first ?? "", title: parent.title, body: parent.body + link, labels: "")
            }
            if existingParent == nil && newParent == nil {
                newParent = Draft(repo: repos.first ?? "", title: document.title, body: (document.summary ?? "") + link, labels: "")
            }
        } catch {
            status = error.localizedDescription
        }
        working = false
    }

    private func create() async {
        guard let api = auth.api else { return }
        creating = true
        defer { creating = false }
        // The parent: the issue the document is about, or a new one.
        var parentID: String?
        if useExistingParent, let existing = existingParent {
            let repo = existing.repo ?? index.issuesRepo ?? ""
            if let record = issueStore.history(for: org)?.issues.values.first(where: { $0.repo == repo && $0.number == existing.number }) {
                parentID = record.id
            } else {
                parentID = try? await api.issueOrPullRequest(repo: repo, number: existing.number)?.id
            }
        } else if let parent = newParent {
            do {
                parentID = try await api.createIssue(repo: parent.repo, title: parent.title, body: parent.body, labels: labels(parent.labels)).id
            } catch {
                status = "Couldn't make the parent: \(error.localizedDescription)"
                return
            }
        }
        let boardID = configs.config(for: org).workflow.projectNumber.flatMap { number in projects.boardLists[org]?.first { $0.number == number }?.id }
        for index in drafts.indices where drafts[index].include && drafts[index].made == nil {
            let draft = drafts[index]
            do {
                let issue = try await api.createIssue(repo: draft.repo, title: draft.title, body: draft.body, labels: labels(draft.labels))
                if let parentID { try await api.addSubIssue(parent: parentID, child: issue.id) }
                if let boardID { try? await api.addToProject(projectID: boardID, contentID: issue.id) }
                drafts[index].made = issue.url
            } catch {
                drafts[index].failed = error.localizedDescription
            }
        }
        status = "Made \(drafts.filter { $0.made != nil }.count). They show in the issue history at the next refresh."
    }

    private func labels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
#endif
