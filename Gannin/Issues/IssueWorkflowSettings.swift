import SwiftUI

/// Settings section: where the org files its issues, read by planning's
/// Agree. Org-wide, so it's kept in the home harness whichever project the
/// window is in.
struct IssueStrategySection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    let org: String

    /// The org's repos, once listed, for the central repo's picker.
    @State private var repos: [String] = []
    /// The picked central repo has issues turned off.
    @State private var centralClosed = false

    var body: some View {
        let strategy = configs.config(for: org).filing
        Section {
            Picker("Strategy", selection: binding(\.kind)) {
                ForEach(IssueStrategy.Kind.allCases) { Text($0.name).tag($0) }
            }
            switch strategy.kind {
            case .central:
                Picker("Repository", selection: binding(\.repo)) {
                    Text("None picked").tag(String?.none)
                    ForEach(repoChoices(strategy), id: \.self) { Text($0).tag(Optional($0)) }
                }
                if centralClosed, let repo = strategy.centralRepo {
                    Text("\(repo) has issues turned off or is archived, so issues can't be filed there. Turn issues on in its settings on GitHub, or pick another repo.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .perRepo:
                Picker("Project", selection: binding(\.projectNumber)) {
                    Text("The Issue workflow board").tag(Int?.none)
                    ForEach(boards(strategy), id: \.number) { Text($0.title).tag(Optional($0.number)) }
                }
            }
        } header: {
            Text("Where issues go")
        } footer: {
            Text(strategy.kind == .central
                 ? "Planning files every issue in this repo, whichever repo the work is in."
                 : "Planning files each issue in the repo the work is in, leaving out repos with issues turned off, and adds it to this project.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: strategy.kind) {
            if strategy.kind == .central, repos.isEmpty { repos = (try? await auth.api?.repositoryNames(org: org)) ?? [] }
            if strategy.kind == .perRepo { await projects.loadBoards(org: org) }
        }
        .task(id: strategy.centralRepo) {
            centralClosed = false
            guard let repo = strategy.centralRepo, let api = auth.api else { return }
            centralClosed = await api.reposWithIssuesOff([repo]).contains(repo.lowercased())
        }
    }

    /// The org's repos, with the saved one kept so it always has a row.
    private func repoChoices(_ strategy: IssueStrategy) -> [String] {
        guard let saved = strategy.repo, !repos.contains(saved) else { return repos }
        return [saved] + repos
    }

    /// The org's boards, with the saved one kept so it always has a name.
    private func boards(_ strategy: IssueStrategy) -> [(number: Int, title: String)] {
        var titles: [Int: String] = [:]
        for board in projects.boardLists[org] ?? [] { titles[board.number] = board.title }
        if let number = strategy.projectNumber, titles[number] == nil { titles[number] = "Project \(number)" }
        return titles.map { ($0.key, $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<IssueStrategy, Value>) -> Binding<Value> {
        Binding {
            configs.config(for: org).filing[keyPath: keyPath]
        } set: { value in
            configs.update(org) { config in
                var strategy = config.filing
                strategy[keyPath: keyPath] = value
                config.issueStrategy = strategy
            }
        }
    }
}

/// Settings sections: which project board and statuses mark an issue as in
/// progress, for issue cycle time. With a board picked, its Status options
/// are the choices, in board order; otherwise the statuses issues have
/// passed through, plus any added by hand.
struct IssueWorkflowSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String

    @State private var newStatus = ""

    var body: some View {
        let workflow = configs.config(for: org).workflow
        let metrics = store.history(for: org).map { IssueMetrics(history: $0, window: MetricsWindow(code: windowDays), team: nil, config: configs.config(for: org)) }
        let seen = metrics?.statusesSeen ?? []
        let options = workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board.field(named: "Status")?.options } ?? []
        let statuses = statuses(options: options, seen: seen, workflow: workflow)

        Section {
            Picker("Board", selection: binding(\.projectNumber)) {
                Text("Any board").tag(Int?.none)
                ForEach(boards(metrics: metrics, workflow: workflow), id: \.number) { board in
                    Text(board.title).tag(Optional(board.number))
                }
            }
            Toggle("Otherwise, start at the first linked PR", isOn: binding(\.fallBackToPullRequests))
        } header: {
            Text("Issue workflow")
        } footer: {
            Text("Cycle time is the time an issue spends in the statuses below on the board. The clock stops when it moves to any other status (Done, or back to Backlog) or is closed, and starts again if it comes back. Issues that never reach one fall back to their first linked PR, if that's on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            if statuses.isEmpty {
                Text("Statuses appear here once issues have synced (open the Issues page), or pick a board. Reading boards needs the project permission, so sign out and back in once if none show up.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(statuses, id: \.name) { status in
                Toggle(isOn: statusBinding(status.name)) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(status.color ?? .secondary.opacity(0.4))
                            .frame(width: 9, height: 9)
                        Text(status.name)
                    }
                    if let moves = seen.first(where: { $0.status.caseInsensitiveCompare(status.name) == .orderedSame })?.count {
                        Text("\(moves) moves")
                    }
                }
            }
            // A board's own options are the whole list; without one, any
            // status can be added by name.
            if workflow.projectNumber == nil {
                HStack {
                    TextField("Status", text: $newStatus, prompt: Text("Add a status by name"))
                        .labelsHidden()
                        .onSubmit(addStatus)
                    Button("Add", action: addStatus)
                        .disabled(newStatus.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("In progress when the status is")
        }
        .task(id: workflow.projectNumber) {
            await projects.loadBoards(org: org)
            if let number = workflow.projectNumber { await projects.loadDefinition(org: org, number: number) }
        }
    }

    /// The org's boards, plus any the issue history has seen and the saved
    /// one, so the picked board always has a name to show.
    private func boards(metrics: IssueMetrics?, workflow: IssueWorkflow) -> [(number: Int, title: String)] {
        var titles: [Int: String] = [:]
        for project in metrics?.projectsSeen ?? [] { titles[project.number] = project.title }
        for board in projects.boardLists[org] ?? [] { titles[board.number] = board.title }
        if let number = workflow.projectNumber, titles[number] == nil { titles[number] = "Project \(number)" }
        return titles.map { ($0.key, $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The board's options with their colours, else the statuses seen; then
    /// anything saved that neither has.
    private func statuses(options: [BoardOption], seen: [(status: String, count: Int)], workflow: IssueWorkflow) -> [(name: String, color: Color?)] {
        var result: [(name: String, color: Color?)] = options.isEmpty
            ? seen.map { ($0.status, nil) }
            : options.map { ($0.name, BoardLayout.color($0.color)) }
        for saved in workflow.inProgressStatuses.sorted() where !result.contains(where: { $0.name.caseInsensitiveCompare(saved) == .orderedSame }) {
            result.append((saved, nil))
        }
        return result
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<IssueWorkflow, Value>) -> Binding<Value> {
        Binding {
            configs.config(for: org).workflow[keyPath: keyPath]
        } set: { value in
            configs.update(org) { config in
                var workflow = config.workflow
                workflow[keyPath: keyPath] = value
                config.issueWorkflow = workflow
            }
        }
    }

    private func statusBinding(_ status: String) -> Binding<Bool> {
        Binding {
            configs.config(for: org).workflow.isInProgress(status)
        } set: { isOn in
            configs.update(org) { config in
                var workflow = config.workflow
                workflow.inProgressStatuses = workflow.inProgressStatuses.filter { $0.caseInsensitiveCompare(status) != .orderedSame }
                if isOn { workflow.inProgressStatuses.insert(status) }
                config.issueWorkflow = workflow
            }
        }
    }

    private func addStatus() {
        let status = newStatus.trimmingCharacters(in: .whitespaces)
        guard !status.isEmpty else { return }
        statusBinding(status).wrappedValue = true
        newStatus = ""
    }
}
