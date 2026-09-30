import SwiftUI

/// What's waiting on you in the org, as one table in sections: on the Mac
/// the Claude Code sessions waiting on you, then PRs you've been asked to
/// review (longest waiting first), your own open PRs and where each
/// stands, and the issues assigned to you (in progress first). PRs show
/// their checks; clicking a row opens it in the drawer.
struct InboxView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issueStore
    @Environment(DetailStore.self) private var details
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @Environment(SessionStore.self) private var sessions
    #endif
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload

    @State private var selection: Set<String> = []
    /// Column order, widths and which are hidden, on this Mac.
    @AppStorage("inboxColumns") private var storedColumns = Data()

    var body: some View {
        if let login = auth.viewer?.login {
            let inbox = Inbox(login: login, workload: workload, history: issueStore.history(for: org), workflow: configs.config(for: org).workflow)
            let sections = sections(inbox)
            Table(of: InboxRow.self, selection: $selection, columnCustomization: TableColumnStore.binding($storedColumns)) {
                TableColumn("Title") { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.tint).frame(width: 8, height: 8)
                        Text(row.title).lineLimit(1)
                    }
                    .help(row.title)
                }
                .width(min: 220, ideal: 420)
                .customizationID("title")
                TableColumn("Number") { row in
                    Text(verbatim: row.reference).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 80, ideal: 110)
                .customizationID("number")
                TableColumn("Who") { row in
                    AvatarStack(people: row.people)
                        .help(row.people.map(\.displayName).joined(separator: ", "))
                }
                .width(min: 50, ideal: 70)
                .customizationID("who")
                TableColumn("Checks") { row in
                    if let checks = row.checks { ChecksBadge(state: checks) }
                }
                .width(min: 60, ideal: 90)
                .customizationID("checks")
                TableColumn("State") { row in
                    HStack(spacing: 4) {
                        FlagBadge(flags: row.flags)
                        Text(row.state).foregroundStyle(row.stateColor).lineLimit(1)
                    }
                    .help(row.state)
                }
                .width(min: 100, ideal: 200)
                .customizationID("state")
                TableColumn("Since") { row in
                    SinceCell(row: row)
                }
                .width(min: 70, ideal: 100)
                .customizationID("since")
                TableColumn("Size") { row in
                    if let size = row.size {
                        LinesText(added: size.added, removed: size.removed)
                    }
                }
                .width(min: 70, ideal: 90)
                .customizationID("size")
            } rows: {
                ForEach(sections, id: \.title) { section in
                    Section("\(section.title) (\(section.rows.count))") {
                        ForEach(section.rows) { TableRow($0) }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let row = sections.flatMap(\.rows).first(where: { ids.contains($0.id) }), let page = row.page {
                    OpenElsewhereItems(page)
                }
            } primaryAction: { ids in
                guard let row = sections.flatMap(\.rows).first(where: { ids.contains($0.id) }) else { return }
                open(row)
            }
            .task(id: org) { await issueStore.sync(org, windowDays: windowDays) }
            // Checks finishing don't touch a PR's updatedAt, so running or
            // unknown ones are asked for; the detail store re-asks pending
            // ones after a couple of minutes.
            .task(id: (inbox.reviews.map(\.pr) + inbox.pullRequests).map(\.id)) {
                for pr in inbox.reviews.map(\.pr) + inbox.pullRequests where pr.checks == nil || pr.checks == .pending || pr.checks == .expected {
                    await details.load(pr.id, updatedAt: pr.updatedAt)
                }
            }
        } else {
            ContentUnavailableView("Not signed in", systemImage: "tray")
        }
    }

    private func open(_ row: InboxRow) {
        #if os(macOS)
        if let session = row.session {
            openWindow(value: SessionWindowID(id: session))
            return
        }
        #endif
        if let page = row.page { navigate?(page) }
    }

    private func sections(_ inbox: Inbox) -> [(title: String, rows: [InboxRow])] {
        var sections: [(title: String, rows: [InboxRow])] = []
        #if os(macOS)
        let waiting = sessions.sessions(for: org).filter { [.needsYou, .idle].contains(sessions.state($0.id)) }
        if !waiting.isEmpty {
            sections.append(("Claude Code", waiting.map { session in
                let state = sessions.state(session.id)
                return InboxRow(
                    id: "session-\(session.id)", title: session.issue.title, reference: session.repo,
                    people: [], checks: nil, state: state.label, stateColor: state == .needsYou ? .orange : .secondary,
                    tint: state.color, since: nil, sinceLabel: "", size: nil, page: nil, session: session.id
                )
            }))
        }
        #endif
        sections.append(("Needs your review", inbox.reviews.map { item in
            InboxRow(
                id: "review-\(item.pr.id)", title: item.pr.title, reference: Self.number(item.pr.repo, item.pr.number),
                people: item.pr.author.map { [$0] } ?? [], checks: checks(item.pr),
                state: item.pr.isDraft ? "Draft, review requested" : "Review requested", stateColor: .secondary,
                tint: ChartPalette.blue, since: item.askedAt, sinceLabel: "Asked", size: (item.pr.additions, item.pr.deletions),
                page: .pullRequest(item.pr.id)
            )
        }))
        sections.append(("Your pull requests", inbox.pullRequests.map { pr in
            let standing = Inbox.standing(pr, needsReview: configs.config(for: org).needsReview(pr.repo))
            return InboxRow(
                id: "pr-\(pr.id)", title: pr.title, reference: Self.number(pr.repo, pr.number),
                people: pr.requestedReviewers + pr.reviewers.filter { reviewer in !pr.requestedReviewers.contains { $0.login == reviewer.login } },
                checks: checks(pr), state: standing.text, stateColor: standing.color,
                tint: standing.color, since: pr.updatedAt, sinceLabel: "Last updated", size: (pr.additions, pr.deletions),
                page: .pullRequest(pr.id)
            )
        }))
        sections.append(("Your issues", inbox.issues.map { item in
            let status = item.signals.status ?? (item.record.isOpen ? "Open" : "Closed")
            return InboxRow(
                id: "issue-\(item.record.id)", title: item.record.title, reference: Self.number(item.record.repo, item.record.number),
                people: [], checks: nil,
                state: item.signals.timeInStatus.map { "\(status), \($0.compactDuration)" } ?? status,
                stateColor: item.inProgress ? .primary : .secondary,
                tint: item.inProgress ? ChartPalette.blue : .secondary.opacity(0.4),
                since: item.record.statusChanges.last?.at ?? item.record.createdAt, sinceLabel: "Last moved",
                size: nil, page: .issueReference(IssueReference(org: org, record: item.record)), flags: item.signals.flags
            )
        }))
        return sections
    }

    /// Fresher from the detail store when it has them.
    private func checks(_ pr: PullRequest) -> ItemDetail.CheckState? {
        details.detail(for: pr.id)?.checks ?? pr.checks
    }

    static func number(_ repo: String, _ number: Int) -> String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(String(number))"
    }
}

/// One row of the Inbox table: a session, a PR or an issue.
struct InboxRow: Identifiable {
    let id: String
    let title: String
    let reference: String
    let people: [Person]
    let checks: ItemDetail.CheckState?
    let state: String
    let stateColor: Color
    let tint: Color
    let since: Date?
    let sinceLabel: String
    let size: (added: Int, removed: Int)?
    let page: DetailSelection?
    var session: UUID? = nil
    var flags: [IssueSignals.Flag] = []
}

/// When the row last moved, relative, with the full date on hover.
private struct SinceCell: View {
    let row: InboxRow

    var body: some View {
        if let since = row.since {
            let full = since.formatted(date: .abbreviated, time: .shortened)
            Text(since, format: .relative(presentation: .named))
                .foregroundStyle(.secondary)
                .help("\(row.sinceLabel) \(full)")
        }
    }
}

/// A PR's checks as an icon and a word, in the palette's status colours.
struct ChecksBadge: View {
    let state: ItemDetail.CheckState

    var body: some View {
        let (icon, color, text): (String, Color, String) = switch state {
        case .success: ("checkmark.circle.fill", ChartPalette.good, "Passing")
        case .failure, .error: ("xmark.circle.fill", ChartPalette.critical, "Failing")
        case .pending, .expected: ("clock.fill", ChartPalette.warning, "Running")
        }
        Label(text, systemImage: icon)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

/// The signed-in person's share of the workload.
struct Inbox {
    struct Review {
        let pr: PullRequest
        let askedAt: Date?
    }

    struct AssignedIssue {
        let record: IssueRecord
        let signals: IssueSignals
        let inProgress: Bool
    }

    let reviews: [Review]
    let pullRequests: [PullRequest]
    let issues: [AssignedIssue]

    init(login: String, workload: Workload, history: IssueHistory?, workflow: IssueWorkflow) {
        let open = workload.openPullRequests
        reviews = open
            .filter { $0.requestedReviewers.contains { $0.login == login } }
            .map { Review(pr: $0, askedAt: $0.reviewRequestedAt[login]) }
            .sorted { ($0.askedAt ?? $0.pr.createdAt) < ($1.askedAt ?? $1.pr.createdAt) }
        pullRequests = open
            .filter { $0.workers.contains(login) }
            // What needs you first: changes asked for, failing checks, then
            // the rest by how long since anything happened.
            .sorted { a, b in
                let (x, y) = (Self.urgency(a), Self.urgency(b))
                return x != y ? x < y : a.updatedAt < b.updatedAt
            }
        let context = FieldContext(board: workflow.projectNumber, workflow: workflow, history: history)
        issues = (history.map { Array($0.issues.values) } ?? [])
            .filter { $0.isOpen && $0.assignees.contains(login) }
            .map { record in
                let signals = context.signals(record)
                return AssignedIssue(record: record, signals: signals, inProgress: signals.status.map(workflow.isInProgress) ?? false)
            }
            .sorted { a, b in
                a.inProgress != b.inProgress ? a.inProgress : (a.signals.timeInStatus ?? 0) > (b.signals.timeInStatus ?? 0)
            }
    }

    private static func urgency(_ pr: PullRequest) -> Int {
        if pr.reviewDecision == .changesRequested { return 0 }
        if pr.checks == .failure || pr.checks == .error { return 1 }
        return 2
    }

    /// Reviews waiting on you, and your PRs with changes asked for.
    var count: Int {
        reviews.count + pullRequests.filter { $0.reviewDecision == .changesRequested }.count
    }

    /// Where a PR of yours stands, in words and a colour.
    static func standing(_ pr: PullRequest, needsReview: Bool = true) -> (text: String, color: Color) {
        if pr.isDraft { return ("Draft", .secondary) }
        switch pr.reviewDecision {
        case .changesRequested: return ("Changes requested", ChartPalette.critical)
        case .approved: return ("Approved", ChartPalette.good)
        default:
            if Workload.isStale(pr) { return ("Stale", .orange) }
            let waiting = pr.requestedReviewers.map(\.displayName)
            if waiting.isEmpty, !needsReview { return ("No review needed", .secondary) }
            return (waiting.isEmpty ? "No reviewer" : "Waiting on \(waiting.joined(separator: ", "))", waiting.isEmpty ? .orange : ChartPalette.blue)
        }
    }
}
