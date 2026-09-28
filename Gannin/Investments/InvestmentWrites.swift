import SwiftUI

// Setting an issue's investment category, as the org tracks it. In Gannin
// it's a choice kept here; in GitHub it's the category's label (the other
// categories' labels removed) or its option on the tracked board field, and
// every such write is shown and confirmed first.

/// One issue's category change, as it would reach GitHub.
struct InvestmentChange: Identifiable, Hashable {
    let issue: IssueRecord
    /// Nil takes the issue out of every category.
    let category: InvestmentCategory?
    /// Labels mode.
    var addLabel: String?
    var removeLabels: [String] = []
    /// Field mode: the option to set, or nil to clear it.
    var setOption: String?
    var clearsField = false
    /// Field mode, when the issue isn't on the board yet.
    var addsToBoard = false

    var id: String { issue.id }

    /// "add ktlo, remove bug" or "set Bucket to Keeping the lights on".
    func summary(_ tracking: InvestmentTracking) -> String {
        switch tracking {
        case .gannin:
            return category.map { "choose \($0.name)" } ?? "back to the rules"
        case .labels:
            var parts: [String] = []
            if let addLabel { parts.append("add label \(addLabel)") }
            if !removeLabels.isEmpty { parts.append("remove \(removeLabels.joined(separator: ", "))") }
            return parts.joined(separator: ", ")
        case .projectField(_, let project, let field):
            var text = setOption.map { "set \(field) to \($0)" } ?? "clear \(field)"
            if addsToBoard { text = "add to \(project), " + text }
            return text
        }
    }

    /// What it would take to put the issue in `category` (nil: none), or nil
    /// when it's already there.
    static func plan(_ issue: IssueRecord, to category: InvestmentCategory?, config: InvestmentConfig) -> InvestmentChange? {
        switch config.trackedBy {
        case .gannin:
            return config.manual[issue.id] == category?.id ? nil : InvestmentChange(issue: issue, category: category)
        case .labels:
            let target = category?.githubValue.flatMap { $0.isEmpty ? nil : $0 }
            let has: (String) -> Bool = { name in issue.labels.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            let others = config.githubValues.filter { value in target.map { value.caseInsensitiveCompare($0) != .orderedSame } ?? true }
            let remove = issue.labels.filter { label in others.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
            let add = target.flatMap { has($0) ? nil : $0 }
            guard add != nil || !remove.isEmpty else { return nil }
            return InvestmentChange(issue: issue, category: category, addLabel: add, removeLabels: remove)
        case .projectField(let number, _, let field):
            let fields = issue.fields(onProject: number)
            let current = fields?.values.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value.display
            let target = category?.githubValue.flatMap { $0.isEmpty ? nil : $0 }
            if let target {
                if current?.caseInsensitiveCompare(target) == .orderedSame { return nil }
                return InvestmentChange(issue: issue, category: category, setOption: target, addsToBoard: fields == nil)
            }
            guard current != nil else { return nil }
            return InvestmentChange(issue: issue, category: nil, clearsField: true)
        }
    }
}

/// Carries out changes: chosen in Gannin at once, written to GitHub one
/// issue at a time, with the local issue history updated to match.
@MainActor
enum InvestmentWriter {
    struct Failure: Identifiable {
        let id = UUID()
        let issue: IssueRecord
        let message: String
    }

    static func applyInGannin(_ changes: [InvestmentChange], org: String, configs: OrgConfigStore) {
        configs.updateInvestments(org) { config in
            for change in changes { config.manual[change.issue.id] = change.category?.id }
        }
    }

    /// Writes to GitHub one issue at a time, reporting each as it starts
    /// and finishes (with its failure, if any); returns what failed.
    static func applyOnGitHub(_ changes: [InvestmentChange], org: String, tracking: InvestmentTracking, api: GitHubAPI, issues: IssueStore, started: (String) -> Void = { _ in }, progress: (Int, Failure?) -> Void) async -> [Failure] {
        var failures: [Failure] = []
        var labelIDs: [String: String] = [:]
        var projects: [OrgProject]?
        for (index, change) in changes.enumerated() {
            started(change.id)
            let failuresBefore = failures.count
            do {
                switch tracking {
                case .gannin:
                    break
                case .labels:
                    try await writeLabels(change, org: org, api: api, issues: issues, cache: &labelIDs)
                case .projectField(let number, let title, let field):
                    if projects == nil, change.addsToBoard { projects = try await api.orgProjects(org: org) }
                    try await writeField(change, org: org, number: number, title: title, field: field, projects: projects ?? [], api: api, issues: issues)
                }
            } catch {
                failures.append(Failure(issue: change.issue, message: error.localizedDescription))
            }
            progress(index + 1, failures.count > failuresBefore ? failures.last : nil)
        }
        return failures
    }

    private static func writeLabels(_ change: InvestmentChange, org: String, api: GitHubAPI, issues: IssueStore, cache: inout [String: String]) async throws {
        let parts = change.issue.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        var labels = change.issue.labels
        for name in change.removeLabels {
            let id = try await labelID(name, owner: parts[0], repo: parts[1], create: false, api: api, cache: &cache)
            if let id {
                try await api.removeLabel(id, from: change.issue.id)
            }
            labels.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let name = change.addLabel, let id = try await labelID(name, owner: parts[0], repo: parts[1], create: true, api: api, cache: &cache) {
            try await api.addLabel(id, to: change.issue.id)
            labels.append(name)
        }
        issues.recordLabels(org: org, issueID: change.issue.id, labels: labels)
    }

    /// A label's ID in the repo, created (grey) when asked and missing.
    private static func labelID(_ name: String, owner: String, repo: String, create: Bool, api: GitHubAPI, cache: inout [String: String]) async throws -> String? {
        let key = "\(owner)/\(repo)\u{1}\(name.lowercased())"
        if let id = cache[key] { return id }
        let found = try await api.repositoryLabel(owner: owner, repo: repo, name: name)
        var id = found.labelID
        if id == nil, create {
            id = try await api.createLabel(name, repositoryID: found.repositoryID)
        }
        if let id { cache[key] = id }
        return id
    }

    private static func writeField(_ change: InvestmentChange, org: String, number: Int, title: String, field name: String, projects: [OrgProject], api: GitHubAPI, issues: IssueStore) async throws {
        var items = try await api.projectItems(issueID: change.issue.id)
        if !items.contains(where: { $0.projectNumber == number }) {
            guard change.setOption != nil else { return }
            guard let project = projects.first(where: { $0.number == number }) else {
                throw InvestmentWriteError.message("\(title) isn't an open board in \(org)")
            }
            try await api.addToProject(projectID: project.id, contentID: change.issue.id)
            items = try await api.projectItems(issueID: change.issue.id)
        }
        guard let item = items.first(where: { $0.projectNumber == number }) else {
            throw InvestmentWriteError.message("Couldn't find the issue on \(title)")
        }
        guard let field = item.fields.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              case .singleSelect(let options) = field.kind else {
            throw InvestmentWriteError.message("\(title) has no single-select field called \(name)")
        }
        if let target = change.setOption {
            guard let index = options.firstIndex(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                throw InvestmentWriteError.message("\(name) on \(title) has no option \(target)")
            }
            try await api.setProjectField(projectID: item.projectID, itemID: item.id, field: field, value: .option(options[index].id))
            issues.recordFieldValue(org: org, issueID: change.issue.id, projectNumber: number, projectTitle: title, field: field.name, value: .option(name: options[index].name, position: index))
        } else {
            try await api.setProjectField(projectID: item.projectID, itemID: item.id, field: field, value: nil)
            issues.recordFieldValue(org: org, issueID: change.issue.id, projectNumber: number, projectTitle: title, field: field.name, value: nil)
        }
    }
}

enum InvestmentWriteError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

extension GitHubAPI {
    /// The repo's node ID, and the label's if it has one by that name.
    func repositoryLabel(owner: String, repo: String, name: String) async throws -> (repositoryID: String, labelID: String?) {
        struct Response: Decodable {
            struct Label: Decodable { let id: String }
            struct Repository: Decodable { let id: String; let label: Label? }
            let repository: Repository?
        }
        let response: Response = try await query("""
            query($owner: String!, $name: String!, $label: String!) {
              repository(owner: $owner, name: $name) { id label(name: $label) { id } }
            }
            """, variables: ["owner": owner, "name": repo, "label": name])
        guard let repository = response.repository else {
            throw InvestmentWriteError.message("Couldn't find \(owner)/\(repo)")
        }
        return (repository.id, repository.label?.id)
    }

    /// Creates a grey label in the repo. A write.
    func createLabel(_ name: String, repositoryID: String) async throws -> String? {
        struct Response: Decodable {
            struct Payload: Decodable { struct Label: Decodable { let id: String }; let label: Label? }
            let createLabel: Payload?
        }
        let response: Response = try await query("""
            mutation($repo: ID!, $name: String!) {
              createLabel(input: { repositoryId: $repo, name: $name, color: "ededed" }) { label { id } }
            }
            """, variables: ["repo": repositoryID, "name": name])
        return response.createLabel?.label?.id
    }

    /// Adds a label to an issue. A write.
    func addLabel(_ labelID: String, to issueID: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await query("""
            mutation($issue: ID!, $label: ID!) {
              addLabelsToLabelable(input: { labelableId: $issue, labelIds: [$label] }) { clientMutationId }
            }
            """, variables: ["issue": issueID, "label": labelID])
    }

    /// Takes a label off an issue. A write.
    func removeLabel(_ labelID: String, from issueID: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await query("""
            mutation($issue: ID!, $label: ID!) {
              removeLabelsFromLabelable(input: { labelableId: $issue, labelIds: [$label] }) { clientMutationId }
            }
            """, variables: ["issue": issueID, "label": labelID])
    }
}

// MARK: - Proposing and confirming

/// Per window: where views propose category changes. Changes tracked in
/// Gannin apply at once; GitHub ones wait in `pending` for the window's
/// confirmation sheet.
@Observable
final class InvestmentPrompt {
    struct Pending: Identifiable {
        let id = UUID()
        let org: String
        let tracking: InvestmentTracking
        let changes: [InvestmentChange]
    }

    var pending: Pending?

    /// Puts the issues in `category` (nil: none), as the org tracks it.
    func assign(_ issues: [IssueRecord], to category: InvestmentCategory?, org: String, configs: OrgConfigStore) {
        let config = configs.config(for: org).investmentConfig
        let changes = issues.compactMap { InvestmentChange.plan($0, to: category, config: config) }
        propose(changes, org: org, configs: configs)
    }

    func propose(_ changes: [InvestmentChange], org: String, configs: OrgConfigStore) {
        guard !changes.isEmpty else { return }
        let tracking = configs.config(for: org).investmentConfig.trackedBy
        if tracking.writesToGitHub {
            pending = Pending(org: org, tracking: tracking, changes: changes)
        } else {
            InvestmentWriter.applyInGannin(changes, org: org, configs: configs)
        }
    }
}

extension View {
    /// A window's `InvestmentPrompt` and the sheet confirming its GitHub
    /// writes.
    func investmentPrompt() -> some View {
        modifier(InvestmentPromptHost())
    }
}

private struct InvestmentPromptHost: ViewModifier {
    @State private var prompt = InvestmentPrompt()

    func body(content: Content) -> some View {
        content
            .environment(prompt)
            .sheet(item: $prompt.pending) { pending in
                InvestmentConfirmation(pending: pending) { prompt.pending = nil }
            }
    }
}

/// Lists the GitHub writes and makes them once confirmed, with progress and
/// anything that failed.
struct InvestmentConfirmation: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issues

    let pending: InvestmentPrompt.Pending
    let onClose: () -> Void

    @State private var done = 0
    @State private var isApplying = false
    @State private var failures: [InvestmentWriter.Failure]?
    /// Each change's progress, by issue ID, ticked off as it's written.
    @State private var states: [String: RowState] = [:]

    private enum RowState: Equatable {
        case writing
        case done
        case failed(String)
    }

    var body: some View {
        let count = pending.changes.count
        VStack(alignment: .leading, spacing: 14) {
            Text(count == 1 ? "Update 1 issue on GitHub?" : "Update \(count) issues on GitHub?")
                .font(.title3.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                List(pending.changes) { change in
                    HStack(alignment: .top, spacing: 10) {
                        stateIcon(states[change.id])
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.issue.title).lineLimit(1)
                            Text("\(change.issue.repo)#\(change.issue.number) · \(change.summary(pending.tracking))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if case .failed(let message) = states[change.id] {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .id(change.id)
                }
                // Follows the write in progress down the list.
                .onChange(of: done) {
                    if pending.changes.indices.contains(done) {
                        withAnimation { proxy.scrollTo(pending.changes[done].id, anchor: .center) }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            HStack {
                if isApplying {
                    ProgressView(value: Double(done), total: Double(count))
                        .frame(width: 160)
                    Text("\(done) of \(count)").monospacedDigit().foregroundStyle(.secondary)
                } else if let failures {
                    Text(failures.isEmpty
                         ? (count == 1 ? "Updated on GitHub." : "All \(count) updated on GitHub.")
                         : "\(count - failures.count) updated, \(failures.count) failed.")
                        .foregroundStyle(failures.isEmpty ? Color.secondary : .red)
                }
                Spacer()
                if failures == nil {
                    Button("Cancel", role: .cancel, action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isApplying)
                    Button(count == 1 ? "Update Issue" : "Update \(count) Issues") { Task { await apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isApplying || auth.api == nil)
                } else {
                    Button("Done", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isApplying)
    }

    private var explanation: String {
        switch pending.tracking {
        case .gannin:
            return ""
        case .labels:
            return "This org tracks investments with labels, so each issue gets its category's label and loses the other categories' labels. A label a repository doesn't have yet is created there."
        case .projectField(_, let project, let field):
            return "This org tracks investments with \(field) on \(project), so each issue's \(field) is set to its category. Issues not on the board are added to it."
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: RowState?) -> some View {
        switch state {
        case nil:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .writing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func apply() async {
        guard let api = auth.api else { return }
        isApplying = true
        let result = await InvestmentWriter.applyOnGitHub(
            pending.changes, org: pending.org, tracking: pending.tracking, api: api, issues: issues,
            started: { states[$0] = .writing }
        ) { count, failure in
            let id = pending.changes[count - 1].id
            states[id] = failure.map { .failed($0.message) } ?? .done
            done = count
        }
        isApplying = false
        // Stays open with every row ticked (or marked failed) until Done.
        failures = result
    }
}
