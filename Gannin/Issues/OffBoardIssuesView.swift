import SwiftUI

/// Issues › Not on a board: issues on no project board (or not on a chosen
/// one), open, closed or both, from the stored issue history. Select some
/// (⌘A for all) and add them to a board in one go, confirmed first.
struct OffBoardIssuesView: View {
    /// Issues about to be added to a board.
    private struct Adding: Identifiable {
        let id = UUID()
        let board: OrgProject
        let issues: [IssueRecord]
    }

    @Environment(IssueStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(OrgConfigStore.self) private var configs
    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow
    @Environment(\.navigate) private var navigate
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("showHidden") private var showHidden = false
    @Environment(HiddenStore.self) private var hidden
    private var stored = StoredIssueFilters("offBoard")

    let org: String
    let team: Team?

    /// Not on this board, by number; nil is not on any board.
    @State private var board: Int?
    @State private var choseBoard = false
    @State private var selection: Set<String> = []
    @State private var adding: Adding?

    init(org: String, team: Team?) {
        self.org = org
        self.team = team
    }

    private var state: IssueFilters.State { stored.wrappedValue.state }

    var body: some View {
        let pool = pool
        let issues = pool.filter { stored.wrappedValue.matches($0, names: { $0 }) }
        VStack(spacing: 0) {
            IssueFilterBar(filters: stored.projectedValue, pool: pool, names: { $0 }) {
                Picker("Not on", selection: $board) {
                    Text("Not on any board").tag(Int?.none)
                    Divider()
                    ForEach(boards) { Text("Not on \($0.title)").tag(Optional($0.number)) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Issues on no board, or not on one board")
            }
            Divider()
            List(selection: $selection) {
                Section {
                    if issues.isEmpty {
                        Text(store.history(for: org) == nil ? "Loading issues." : stored.wrappedValue.isNarrowed ? "No issues match." : "Nothing here: every \(state == .all ? "" : state.rawValue.lowercased() + " ")issue is on \(boardName ?? "a board").")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(issues) { issue in
                        row(issue).tag(issue.id)
                    }
                } header: {
                    Text("\(issues.count) \(issues.count == 1 ? "issue" : "issues") not on \(boardName ?? "any board")")
                } footer: {
                    if let history = store.history(for: org), state != .open {
                        Text("Closed issues since \(history.coveredFrom.formatted(date: .abbreviated, time: .omitted)), as far back as the issue history goes (Investments' All time fetches everything).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                addMenu(ids)
            } primaryAction: { ids in
                let picked = issues.filter { ids.contains($0.id) }
                if picked.count == 1, let issue = picked.first, let navigate {
                    navigate(.issueReference(IssueReference(org: org, record: issue)))
                } else {
                    // Several at once get a window each.
                    for issue in picked { openWindow(value: IssueReference(org: org, record: issue)) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selection.isEmpty { selectionBar(issues) }
            }
        }
        .task(id: org) {
            await projects.loadBoards(org: org)
            await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays())
        }
        .onAppear {
            // Start from the board investments are tracked on, if any.
            if !choseBoard, case .projectField(let number, _, _) = configs.config(for: org).investmentConfig.trackedBy, number != 0 {
                board = number
            }
        }
        .onChange(of: board) {
            choseBoard = true
            selection = []
        }
        .onChange(of: state) { selection = [] }
        .sheet(item: $adding) { request in
            BulkWriteSheet(
                title: request.issues.count == 1 ? "Add 1 issue to \(request.board.title)?" : "Add \(request.issues.count) issues to \(request.board.title)?",
                explanation: "Each issue is added to the board on GitHub with its fields empty, where it can then be triaged.",
                action: request.issues.count == 1 ? "Add Issue" : "Add \(request.issues.count) Issues",
                rows: request.issues.map { .init(id: $0.id, title: $0.title, detail: "\($0.repo)#\($0.number)") }
            ) { row in
                guard let api = auth.api else { throw InvestmentWriteError.message("Not signed in") }
                try await api.addToProject(projectID: request.board.id, contentID: row.id)
                store.recordAddedToBoard(org: org, issueID: row.id, projectNumber: request.board.number, projectTitle: request.board.title)
            } onClose: {
                adding = nil
                selection = []
            }
        }
    }

    // MARK: Issues

    private var boards: [OrgProject] { projects.boardLists[org] ?? [] }

    private var boardName: String? {
        board.map { number in boards.first { $0.number == number }?.title ?? "project \(number)" }
    }

    /// The page's issues after its own filters and every other one.
    private var issues: [IssueRecord] {
        pool.filter { stored.wrappedValue.matches($0, names: { $0 }) }
    }

    /// Not on the board, in the state picked, less hidden ones and (with a
    /// team) those not assigned to its members: what the bar's menus count.
    /// Newest first: open by when they were opened, closed by when they closed.
    private var pool: [IssueRecord] {
        guard let history = store.history(for: org) else { return [] }
        let members = team.map { Set($0.members) }
        return history.issues.values
            .filter { issue in
                switch state {
                case .open: issue.isOpen
                case .closed: !issue.isOpen
                case .all: true
                }
            }
            .filter { issue in
                board.map { number in issue.fields(onProject: number) == nil } ?? issue.projectFields.isEmpty
            }
            .filter { issue in members.map { team in issue.assignees.contains(where: team.contains) } ?? true }
            .filter { showHidden || !hidden.keys.contains($0.id) }
            .sorted { ($0.closedAt ?? $0.createdAt) > ($1.closedAt ?? $1.createdAt) }
    }

    private func row(_ issue: IssueRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(issue.repo)#\(String(issue.number))")
                    if let author = issue.author { Text("by \(author)") }
                    if let closedAt = issue.closedAt {
                        Text("· closed")
                        RelativeDate(date: closedAt)
                    } else {
                        Text("· opened")
                        RelativeDate(date: issue.createdAt)
                    }
                    if !issue.projectFields.isEmpty {
                        Text("· on \(issue.projectFields.map(\.projectTitle).joined(separator: ", "))")
                    }
                    if !issue.labels.isEmpty {
                        Text("· \(issue.labels.prefix(3).joined(separator: ", "))")
                    }
                    if !issue.linkedPullRequests.isEmpty {
                        LinkedPullRequestsBadge(
                            count: issue.linkedPullRequests.count,
                            tint: issue.linkedPullRequests.linkedPullRequestsTint,
                            anyMerged: issue.linkedPullRequests.contains(where: \.isMerged)
                        )
                    }
                    if let mentioned = issue.mentionedInPullRequests, !mentioned.isEmpty {
                        LinkedPullRequestsBadge(
                            count: mentioned.count,
                            tint: mentioned.linkedPullRequestsTint,
                            anyMerged: mentioned.contains(where: \.isMerged),
                            systemImage: "at",
                            label: "Mentioned in pull requests"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            AvatarStack(people: issue.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
        }
        .padding(.vertical, 2)
    }

    // MARK: Adding

    @ViewBuilder
    private func addMenu(_ ids: Set<String>) -> some View {
        let chosen = issues.filter { ids.contains($0.id) }
        Menu(chosen.count == 1 ? "Add to Board" : "Add \(chosen.count) to Board") {
            ForEach(boards) { target in
                Button(target.title) { adding = Adding(board: target, issues: chosen.filter { $0.fields(onProject: target.number) == nil }) }
            }
        }
        .disabled(chosen.isEmpty || boards.isEmpty)
        if chosen.count == 1, let issue = chosen.first {
            Link("Open on GitHub", destination: issue.url)
        }
    }

    private func selectionBar(_ issues: [IssueRecord]) -> some View {
        let chosen = issues.filter { selection.contains($0.id) }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("\(chosen.count) selected").monospacedDigit()
                Button("Select All \(issues.count)") { selection = Set(issues.map(\.id)) }
                    .disabled(chosen.count == issues.count)
                Button("Clear") { selection = [] }
                Spacer()
                Menu {
                    ForEach(boards) { target in
                        Button(target.title) { adding = Adding(board: target, issues: chosen.filter { $0.fields(onProject: target.number) == nil }) }
                    }
                } label: {
                    Label(chosen.count == 1 ? "Add to Board" : "Add \(chosen.count) to Board", systemImage: "plus.rectangle.on.rectangle")
                }
                .fixedSize()
                .disabled(boards.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}
