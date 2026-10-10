import SwiftUI

/// Agreeing a planning session: who was in the room, the parent issue (the
/// one planned, or a new one), the tasks as sub-issues to edit or
/// untick, and the plan and requirement for the harness. Nothing's written
/// until Agree and Write; then the issues are made and ticked off, and
/// both documents go in one commit. Claude is told what was written.
struct PlanningAgreeSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(IssueStore.self) private var issueStore
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession

    struct Draft: Identifiable {
        let id = UUID()
        var include = true
        var repo: String
        var title: String
        var body: String
        var labels: String
        /// The acceptance criteria it satisfies, by id.
        var satisfies: [String] = []
        /// `owner/name#123` and its page, once made.
        var made: (reference: String, url: URL)?
        var failed: String?
    }

    @State private var drafts: [Draft] = []
    @State private var present: Set<String> = []
    @State private var search = ""
    @State private var parentTitle = ""
    @State private var parentRepo = ""
    /// The parent's node ID, reference and page, once known or made.
    @State private var parent: (id: String, reference: String, url: URL)?
    @State private var writesRequirement = true
    @State private var working = false
    @State private var status: String?

    private var org: String { session.org }
    private var planning: PlanningInfo? { session.planning }
    private var state: PlanningState? { planning?.state }
    private var harnessRepo: String { session.harnessRepo ?? session.repo }
    /// The settings of the project the session plans in (its harness's),
    /// not the home project's this window would otherwise read: its repos,
    /// what it leaves out, and its workflow board.
    private var projectConfig: OrgConfig { configs.scoped(harnessRepo).config(for: org) }
    private var title: String { state?.title ?? planning?.topic ?? session.title }
    private var planPath: String { "plans/\(HarnessAuthoring.today)-\(planning?.slug ?? "plan").md" }
    private var requirementPath: String { "requirements/\(planning?.slug ?? "plan").md" }
    /// Started from a requirement, which is linked rather than rewritten.
    private var startedFromRequirement: Bool { planning?.documentPath?.hasPrefix("requirements/") == true }

    /// Repos to pick from: those the plan names, the project's, then the
    /// busiest in the snapshot and issue history (which this window may not
    /// have loaded), and the harness itself so there's always one.
    private var repos: [String] {
        let config = projectConfig
        let named = (state?.tasks ?? []).compactMap(\.repo) + (state?.scouting ?? []).compactMap(\.repo) + [planning?.issue?.repo].compactMap { $0 }
        let ownRepos = config.repoProjects.first { $0.id == harnessRepo }?.repos ?? config.harness(repo: harnessRepo)?.repos ?? []
        let project = ownRepos.map { $0.contains("/") ? $0 : "\(org)/\($0)" }
        let snapshot = orgs.snapshot(for: org)
        let active = (snapshot?.issues.map(\.repo) ?? []) + (snapshot?.openPullRequests.map(\.repo) ?? []) + (snapshot?.mergedPullRequests.map(\.repo) ?? [])
            + (issueStore.history(for: org)?.issues.values.map(\.repo) ?? [])
        let busiest = Dictionary(grouping: active, by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }.map(\.key)
        var seen: Set<String> = []
        let found = (named + project + busiest).filter { seen.insert($0).inserted && !config.repoExclusion.contains($0) }
        return found.isEmpty ? [harnessRepo] : found
    }

    private var members: [Person] {
        let all = (orgs.snapshot(for: org)?.members ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.login.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query) || present.contains($0.login) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agree \(title)").font(.headline).lineLimit(1)
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            Form {
                readiness
                people
                parentSection
                Section("\(drafts.filter(\.include).count) of \(drafts.count) sub-issues") {
                    if drafts.isEmpty {
                        Text("No tasks yet: the plan is written with no sub-issues.").foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $draft in
                        editor($draft)
                    }
                    Button("Add Issue") { drafts.append(Draft(repo: repos.first ?? "", title: "", body: "", labels: "")) }
                }
                Section {
                    LabeledContent("Plan", value: planPath)
                    if startedFromRequirement, let path = planning?.documentPath {
                        LabeledContent("Requirement", value: "\(path), linked")
                    } else {
                        Toggle("Write the requirement as \(requirementPath)", isOn: $writesRequirement)
                            .checkboxToggle()
                    }
                } header: {
                    Text("Harness")
                } footer: {
                    Text("Both go to \(harnessRepo) in one commit, after the issues are made, so the plan links them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Writing" : "Agree and Write") { Task { await agree() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || state == nil || present.isEmpty || (planning?.issue == nil && (parentTitle.trimmingCharacters(in: .whitespaces).isEmpty || parentRepo.isEmpty)) || drafts.contains { $0.include && ($0.repo.isEmpty || $0.title.trimmingCharacters(in: .whitespaces).isEmpty) })
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 620, idealHeight: 760)
        .onAppear(perform: fill)
    }

    // MARK: Sections

    /// What isn't settled: stages not approved (or reopened since) and
    /// acceptance criteria no task covers. Agreeing anyway is allowed.
    @ViewBuilder
    private var readiness: some View {
        let unapproved = PlanningStep.allCases.filter { step in step.isLoop && !(planning?.isApproved(step) ?? false) }
        let uncovered = state?.uncovered ?? []
        if !unapproved.isEmpty || !uncovered.isEmpty {
            Section {
                if !unapproved.isEmpty {
                    Label("Not approved: \(unapproved.map(\.rawValue).joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(uncovered) { criterion in
                    Label("\(criterion.id) has no task: \(criterion.text)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Before you agree")
            } footer: {
                Text("You can agree anyway; the plan records what was approved.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var people: some View {
        Section {
            TextField("Search the org", text: $search)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(members) { person in
                    Toggle(person.displayName, isOn: Binding(
                        get: { present.contains(person.login) },
                        set: { on in if on { present.insert(person.login) } else { present.remove(person.login) } }
                    ))
                    .checkboxToggle()
                    .help(person.login)
                }
            }
        } header: {
            Text("Who was here")
        } footer: {
            Text("They go in the plan's agreed_by.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var parentSection: some View {
        Section("Parent") {
            if let issue = planning?.issue {
                LabeledContent("Under", value: "\(issue.reference), \(issue.title)")
            } else if let parent {
                LabeledContent("Made", value: parent.reference)
            } else {
                TextField("Title", text: $parentTitle, prompt: Text("Parent issue title"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                Picker("Repository", selection: $parentRepo) {
                    ForEach(repos, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private func editor(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: draft.include).labelsHidden().checkboxToggle()
                TextField("Title", text: draft.title, prompt: Text("Title"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .fontWeight(.medium)
                Picker("", selection: draft.repo) {
                    ForEach(repos.contains(draft.wrappedValue.repo) || draft.wrappedValue.repo.isEmpty ? repos : [draft.wrappedValue.repo] + repos, id: \.self) {
                        Text($0.split(separator: "/").last.map(String.init) ?? $0).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let made = draft.wrappedValue.made {
                    Link(destination: made.url) { Image(systemName: "checkmark.circle.fill").foregroundStyle(ChartPalette.good) }
                        .help(made.reference)
                } else {
                    let id = draft.wrappedValue.id
                    Button {
                        drafts.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this issue")
                    .accessibilityLabel("Remove \(draft.wrappedValue.title.isEmpty ? "this issue" : draft.wrappedValue.title)")
                }
            }
            TextField("Description", text: draft.body, prompt: Text("Description"), axis: .vertical)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .lineLimit(2...8)
                .foregroundStyle(.secondary)
            TextField("Labels", text: draft.labels, prompt: Text("Labels, comma separated"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .font(.caption)
            if let failed = draft.wrappedValue.failed {
                Text(failed).font(.caption).foregroundStyle(.red)
            }
        }
        .opacity(draft.wrappedValue.include ? 1 : 0.5)
        .disabled(draft.wrappedValue.made != nil)
    }

    private var summary: String {
        let count = drafts.filter { $0.include && $0.made == nil }.count
        var parts: [String] = []
        if planning?.issue == nil && parent == nil { parts.append("a parent issue") }
        if count > 0 { parts.append(count == 1 ? "1 sub-issue" : "\(count) sub-issues") }
        parts.append(writesRequirement && !startedFromRequirement ? "the plan and requirement" : "the plan")
        return "Writes " + parts.joined(separator: ", ")
    }

    private func fill() {
        guard drafts.isEmpty else { return }
        drafts = (state?.tasks ?? []).map {
            Draft(repo: $0.repo.flatMap { repos.contains($0) ? $0 : nil } ?? repos.first ?? "", title: $0.title, body: $0.body ?? "", labels: $0.labels.joined(separator: ", "), satisfies: $0.satisfies)
        }
        parentTitle = title
        parentRepo = repos.first ?? ""
        writesRequirement = !startedFromRequirement
        if let login = auth.viewer?.login { present.insert(login) }
    }

    // MARK: Writing

    private func agree() async {
        guard let api = auth.api, let planning, let state else { return }
        working = true
        defer { working = false }
        status = nil
        let planURL = URL(string: "https://github.com/\(harnessRepo)/blob/HEAD/\(planPath)")
        let planText = planURL.map { "Planned in [\(title)](\($0.absoluteString))." }
        let planLink = planText.map { "\n\n\($0)" } ?? ""

        if parent == nil {
            if let issue = planning.issue {
                parent = (issue.id, issue.reference, issue.url)
            } else {
                do {
                    let made = try await api.createIssue(repo: parentRepo, title: parentTitle, body: (state.summary ?? "") + planLink)
                    parent = (made.id, "\(parentRepo)#\(made.number)", made.url)
                } catch {
                    status = "Couldn't make the parent issue: \(error.localizedDescription)"
                    return
                }
            }
        }
        guard let parent else { return }

        let config = projectConfig
        let boardID = config.workflow.projectNumber.flatMap { number in projects.boardLists[org]?.first { $0.number == number }?.id }
        for index in drafts.indices where drafts[index].include && drafts[index].made == nil {
            let draft = drafts[index]
            drafts[index].failed = nil
            do {
                let issue = try await api.createIssue(repo: draft.repo, title: draft.title, body: draft.body + satisfies(draft) + planLink, labels: labels(draft.labels))
                try await api.addSubIssue(parent: parent.id, child: issue.id)
                if let boardID { try? await api.addToProject(projectID: boardID, contentID: issue.id) }
                drafts[index].made = ("\(draft.repo)#\(issue.number)", issue.url)
            } catch {
                drafts[index].failed = error.localizedDescription
            }
        }
        if drafts.contains(where: { $0.include && $0.made == nil }) {
            status = "Some issues weren't made. Agree and Write again to try those, or untick them."
            return
        }

        let agreedBy = present.sorted()
        let made = drafts.compactMap(\.made)
        let tasks = drafts.compactMap { draft in draft.made.map { (reference: $0.reference, url: $0.url, title: draft.title, satisfies: draft.satisfies) } }
        let requirement = writesRequirement && !startedFromRequirement ? requirementPath : nil
        let linkedRequirement = requirement ?? (startedFromRequirement ? planning.documentPath : nil)
        var files: [String: String?] = [
            planPath: PlanningDocuments.plan(
                state: state, title: title, parent: parent.reference, tasks: tasks, owner: auth.viewer?.login, agreedBy: agreedBy,
                requirementPath: linkedRequirement, dismissed: planning.dismissed ?? [], startedFrom: planning.documentPath,
                comments: planning.comments ?? [], context: planning
            ),
        ]
        if let requirement {
            files[requirement] = PlanningDocuments.requirement(state: state, title: title, parent: parent.reference, planPath: planPath)
        }
        let setup = config.harness(repo: harnessRepo) ?? HarnessConfig(repo: harnessRepo)
        do {
            try await harness.commit(org: org, setup: setup) { _ in
                HarnessChange(message: "Plan: \(title)", files: files)
            }
        } catch {
            status = "The issues are made, but the plan couldn't be committed: \(error.localizedDescription) Agree and Write again to retry."
            return
        }
        if planning.issue != nil, let planText {
            try? await api.addComment(subjectID: parent.id, body: planText)
        }

        sessions.update(session.id) {
            $0.planning?.agreed = PlanningAgreement(
                at: .now, by: agreedBy, planPath: planPath, requirementPath: requirement,
                parent: parent.reference, parentURL: parent.url, issues: made.map(\.url)
            )
        }
        var message = "The room agreed. Gannin committed \(planPath)\(requirement.map { " and \($0)" } ?? "") to the harness"
        message += made.isEmpty ? " under \(parent.reference)." : ", and made \(made.map(\.reference).joined(separator: ", ")) as sub-issues of \(parent.reference)."
        message += " There's nothing more to write; answer questions about the plan if we ask."
        _ = sessions.submit(message, to: session.id)
        dismiss()
    }

    /// The criteria a task satisfies, as its issue says them.
    private func satisfies(_ draft: Draft) -> String {
        let criteria = state?.requirement.acceptance ?? []
        let lines = draft.satisfies.map { id in
            "- **\(id)**" + (criteria.first { $0.id.uppercased() == id.uppercased() }.map { ": \($0.text)" } ?? "")
        }
        return lines.isEmpty ? "" : "\n\nSatisfies:\n\n" + lines.joined(separator: "\n")
    }

    private func labels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The plan and requirement written from a planning session's state, with
/// front matter as the harness's STANDARDS.md has it.
enum PlanningDocuments {
    static func plan(state: PlanningState, title: String, parent: String, tasks: [(reference: String, url: URL, title: String, satisfies: [String])], owner: String?, agreedBy: [String], requirementPath: String?, dismissed: Set<String>, startedFrom: String?, comments: [PlanningComment] = [], context: PlanningInfo? = nil) -> String {
        let touches = Array(Set(state.tasks.compactMap(\.repo) + state.scouting.compactMap(\.repo))).sorted()
        var front = [
            "type: plan",
            "status: in-progress",
            "summary: \(yaml(state.summary ?? title))",
            "issues: [\(([parent] + tasks.map(\.reference)).joined(separator: ", "))]",
        ]
        if !touches.isEmpty { front.append("touches: [\(touches.joined(separator: ", "))]") }
        if let owner { front.append("owner: \(owner)") }
        front.append("agreed_by: [\(agreedBy.joined(separator: ", "))]")
        front.append("agreed_at: \(HarnessAuthoring.today)")
        if let requirementPath { front.append("requirement: \(requirementPath)") }

        var body = ["# \(title)"]
        if let summary = state.summary { body.append(summary) }
        if let startedFrom { body.append("Started from [\(startedFrom)](../\(startedFrom)).") }
        if let context, context.hasContext {
            var lines: [String] = []
            for link in context.links ?? [] {
                lines.append("- [\(link.note ?? link.url.absoluteString)](\(link.url.absoluteString))")
            }
            for document in context.documents {
                lines.append(document.commit ? "- [\(document.name)](assets/\(context.slug)/\(document.name))" : "- \(document.name) (shared in the session, not committed)")
            }
            if let sources = context.sources { lines.append("- Also looked at: \(sources)") }
            body.append("## Context\n\n" + lines.joined(separator: "\n"))
        }

        var requirement = ["## Requirement"]
        if let requirementPath { requirement.append("In full in [\(requirementPath)](../\(requirementPath)).") }
        let r = state.requirement
        if let problem = r.problem { requirement.append("**Problem:** \(problem)") }
        if let goal = r.goal { requirement.append("**Goal:** \(goal)") }
        if let users = r.users { requirement.append("**Who it's for:** \(users)") }
        if !r.scope.isEmpty { requirement.append("**Scope:**\n\n" + numbered(r.scope)) }
        if !r.nonGoals.isEmpty { requirement.append("**Out of scope:**\n\n" + bullets(r.nonGoals)) }
        if !r.acceptance.isEmpty { requirement.append("**Acceptance criteria:**\n\n" + criteria(r.acceptance)) }
        requirement += decisions(state, .requirements)
        body.append(requirement.joined(separator: "\n\n"))

        var design = ["## Design"]
        if let approach = state.design.approach { design.append(approach) }
        let findings = state.scouting.filter { !dismissed.contains($0.id) }
        for (kind, heading) in [("area", "Areas it touches"), ("pattern", "Patterns to follow"), ("risk", "Risks")] {
            let these = findings.filter { ($0.kind ?? "area").lowercased() == kind }
            guard !these.isEmpty else { continue }
            design.append("**\(heading):**\n\n" + these.map { finding in
                let place = [finding.repo.map { "`\($0)`" }, finding.path.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " ")
                return "- \(place.isEmpty ? "" : "\(place): ")\(finding.note)"
            }.joined(separator: "\n"))
        }
        design += decisions(state, .design)
        if design.count > 1 { body.append(design.joined(separator: "\n\n")) }

        var taskList = ["## Tasks"]
        if !tasks.isEmpty {
            taskList.append(tasks.enumerated().map { index, task in
                "\(index + 1). [\(task.reference)](\(task.url.absoluteString)) \(task.title)\(task.satisfies.isEmpty ? "" : " (satisfies \(task.satisfies.joined(separator: ", ")))")"
            }.joined(separator: "\n"))
        } else if !state.tasks.isEmpty {
            taskList.append(numbered(state.tasks.map(\.title)))
        }
        taskList += decisions(state, .tasks)
        if taskList.count > 1 { body.append(taskList.joined(separator: "\n\n")) }
        if !comments.isEmpty {
            body.append("## From the room\n\n" + bullets(comments.map { "\($0.text) (\($0.step.lowercased()))" }))
        }
        if !r.openQuestions.isEmpty {
            body.append("## Open questions\n\n" + bullets(r.openQuestions))
        }
        return "---\n" + front.joined(separator: "\n") + "\n---\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    static func requirement(state: PlanningState, title: String, parent: String, planPath: String) -> String {
        let r = state.requirement
        let front = [
            "type: requirement",
            "status: in-progress",
            "summary: \(yaml(r.goal ?? state.summary ?? title))",
            "issues: [\(parent)]",
            "plans: [\(planPath)]",
        ]
        var body = ["# \(title)"]
        if let problem = r.problem { body.append("## Problem\n\n\(problem)") }
        if let goal = r.goal { body.append("## Goal\n\n\(goal)") }
        if let users = r.users { body.append("## Who it's for\n\n\(users)") }
        if !r.scope.isEmpty { body.append("## Requirements\n\n" + numbered(r.scope)) }
        if !r.nonGoals.isEmpty { body.append("## Out of scope\n\n" + bullets(r.nonGoals)) }
        if !r.acceptance.isEmpty { body.append("## Acceptance criteria\n\n" + criteria(r.acceptance)) }
        if !r.openQuestions.isEmpty { body.append("## Open questions\n\n" + bullets(r.openQuestions)) }
        body.append("Planned in [\(planPath)](../\(planPath)).")
        return "---\n" + front.joined(separator: "\n") + "\n---\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    private static func criteria(_ criteria: [PlanningState.Criterion]) -> String {
        criteria.map { "- **\($0.id)** \($0.text)" }.joined(separator: "\n")
    }

    /// A stage's decisions, as a paragraph of the plan's section.
    private static func decisions(_ state: PlanningState, _ step: PlanningStep) -> [String] {
        let decisions = state.decisions(in: step)
        guard !decisions.isEmpty else { return [] }
        return ["**Decisions:**\n\n" + decisions.map { decision in
            decision.question.map { "- \($0) **\(decision.answer)**" } ?? "- \(decision.answer)"
        }.joined(separator: "\n")]
    }

    private static func bullets(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func numbered(_ items: [String]) -> String {
        items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// A double-quoted YAML string.
    private static func yaml(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
