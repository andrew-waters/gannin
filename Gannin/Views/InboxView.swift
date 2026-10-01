import SwiftUI

/// A section of the Inbox, each turned on or off from its Show menu (per org,
/// on this Mac). The first four are on until turned off; the rest are there
/// for those who want them.
enum InboxSection: String, CaseIterable, Identifiable {
    case sessions = "Claude Code"
    case reviews = "Needs your review"
    case pullRequests = "Your pull requests"
    case issues = "Your issues"
    case opened = "Issues you opened"
    case plans = "Your harness plans"
    case uncategorised = "Uncategorised investments"

    var id: Self { self }

    var isOnByDefault: Bool {
        switch self {
        case .sessions, .reviews, .pullRequests, .issues: true
        case .opened, .plans, .uncategorised: false
        }
    }

    var help: String {
        switch self {
        case .sessions: "Claude Code sessions waiting on you"
        case .reviews: "PRs you've been asked to review, longest waiting first"
        case .pullRequests: "Your open PRs and where each stands"
        case .issues: "Open issues assigned to you, in progress first"
        case .opened: "Open issues you opened that aren't assigned to you"
        case .plans: "Harness plans you own that aren't done"
        case .uncategorised: "Open issues, and those completed in the window, with no investment category"
        }
    }

    /// Those on the Mac only (Claude Code) left out elsewhere.
    static var available: [InboxSection] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .sessions }
        #endif
    }
}

/// What's waiting on you in the org, as one table in sections, those you've
/// turned on (`InboxSection`): on the Mac the Claude Code sessions waiting on
/// you, then PRs you've been asked to review (longest waiting first), your
/// own open PRs and where each stands, the issues assigned to you (in
/// progress first), and if you want them, issues you opened, your harness
/// plans and the uncategorised investments. PRs show their checks; clicking
/// a row opens it in the drawer.
struct InboxView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issueStore
    @Environment(DetailStore.self) private var details
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(HiddenStore.self) private var hidden
    @Environment(\.navigate) private var navigate
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @Environment(SessionStore.self) private var sessions
    #endif
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload

    @State private var selection: Set<String> = []
    /// Applied within each section; empty keeps each section's own order.
    @State private var sortOrder: [KeyPathComparator<InboxRow>] = []
    /// Column order, widths and which are hidden, on this Mac.
    @AppStorage("inboxColumns") private var storedColumns = Data()
    /// The sections turned on, as raw values, comma separated; empty for
    /// those on by default.
    @AppStorage private var storedSections: String
    /// Every section in the order you've put them, comma separated; empty
    /// for the usual order.
    @AppStorage private var storedOrder: String
    @State private var search = ""
    @State private var isArranging = false

    init(org: String, workload: Workload) {
        self.org = org
        self.workload = workload
        _storedSections = AppStorage(wrappedValue: "", "inboxSections.\(org)")
        _storedOrder = AppStorage(wrappedValue: "", "inboxSectionOrder.\(org)")
    }

    /// The sections in your order, any added since at the end.
    private var order: [InboxSection] {
        let saved = storedOrder.split(separator: ",").compactMap { InboxSection(rawValue: String($0)) }.filter(InboxSection.available.contains)
        return saved + InboxSection.available.filter { !saved.contains($0) }
    }

    private var shown: Set<InboxSection> {
        guard !storedSections.isEmpty else { return Set(InboxSection.allCases.filter(\.isOnByDefault)) }
        return Set(storedSections.split(separator: ",").compactMap { InboxSection(rawValue: String($0)) })
    }

    private func show(_ section: InboxSection, _ isOn: Bool) {
        var sections = shown
        if isOn { sections.insert(section) } else { sections.remove(section) }
        storedSections = InboxSection.allCases.filter(sections.contains).map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        if let login = auth.viewer?.login {
            let inbox = Inbox(login: login, workload: workload, history: issueStore.history(for: org), workflow: configs.config(for: org).workflow)
            let sections = sections(inbox)
            VStack(spacing: 0) {
                bar
                Divider()
                table(sections)
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

    /// Search across the sections, and which sections show, in what order.
    private var bar: some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Title, number, state or person")
            Spacer(minLength: 0)
            Button {
                isArranging = true
            } label: {
                Label("Sections", systemImage: "list.bullet.rectangle")
            }
            .help("Choose which sections show, and their order")
            .popover(isPresented: $isArranging, arrowEdge: .bottom) { arrangement }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Every section with a tick to show it; drag to reorder.
    private var arrangement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sections").font(.headline)
            List {
                ForEach(order) { section in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { shown.contains(section) }, set: { show(section, $0) })) {
                            Text(section.rawValue)
                        }
                        .checkboxToggle()
                        .help(section.help)
                        Spacer(minLength: 8)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                }
                .onMove { from, to in
                    var sections = order
                    sections.move(fromOffsets: from, toOffset: to)
                    storedOrder = sections.map(\.rawValue).joined(separator: ",")
                }
            }
            .listStyle(.plain)
            .frame(height: CGFloat(order.count) * 30 + 8)
            HStack {
                Text("Drag to reorder.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Usual Sections") {
                    storedSections = ""
                    storedOrder = ""
                }
                .disabled(storedSections.isEmpty && storedOrder.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Rows matching the search, every word in the title, number, state or a
    /// person's name.
    private func matches(_ row: InboxRow) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let fields = [row.title, row.reference, row.state] + row.people.flatMap { [$0.login, $0.displayName] }
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
    }

    private func table(_ sections: [(title: String, rows: [InboxRow])]) -> some View {
        Table(of: InboxRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: TableColumnStore.binding($storedColumns)) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.tint).frame(width: 8, height: 8)
                    Text(row.title).lineLimit(1)
                }
                .help(row.title)
            }
            .width(min: 220, ideal: 420)
            .customizationID("title")
            TableColumn("Number", value: \.reference) { row in
                Text(verbatim: row.reference).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 110)
            .customizationID("number")
            TableColumn("Who", value: \.whoSort) { row in
                AvatarStack(people: row.people)
                    .help(row.people.map(\.displayName).joined(separator: ", "))
            }
            .width(min: 50, ideal: 70)
            .customizationID("who")
            TableColumn("Checks", value: \.checksSort) { row in
                if let checks = row.checks { ChecksBadge(state: checks) }
            }
            .width(min: 60, ideal: 90)
            .customizationID("checks")
            TableColumn("State", value: \.state) { row in
                HStack(spacing: 4) {
                    FlagBadge(flags: row.flags)
                    Text(row.state).foregroundStyle(row.stateColor).lineLimit(1)
                }
                .help(row.state)
            }
            .width(min: 100, ideal: 200)
            .customizationID("state")
            TableColumn("Since", value: \.sinceSort) { row in
                SinceCell(row: row)
            }
            .width(min: 70, ideal: 100)
            .customizationID("since")
            TableColumn("Size", value: \.sizeSort) { row in
                if let size = row.size {
                    LinesText(added: size.added, removed: size.removed)
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID("size")
        } rows: {
            ForEach(sections, id: \.title) { section in
                Section("\(section.title) (\(section.rows.count))") {
                    // Sorted within the section, so they stay apart.
                    ForEach(sortOrder.isEmpty ? section.rows : section.rows.sorted(using: sortOrder)) { TableRow($0) }
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
    }

    private func open(_ row: InboxRow) {
        #if os(macOS)
        if let session = row.session {
            sessions.show(session, with: openWindow)
            return
        }
        #endif
        if let page = row.page { navigate?(page) }
    }

    private func sections(_ inbox: Inbox) -> [(title: String, rows: [InboxRow])] {
        var sections: [(title: String, rows: [InboxRow])] = []
        let shown = shown
        #if os(macOS)
        let waiting = sessions.sessions(for: org).filter { [.needsYou, .idle].contains(sessions.state($0.id)) }
        if shown.contains(.sessions), !waiting.isEmpty {
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
        if shown.contains(.reviews) { sections.append((InboxSection.reviews.rawValue, inbox.reviews.map { item in
            InboxRow(
                id: "review-\(item.pr.id)", title: item.pr.title, reference: Self.number(item.pr.repo, item.pr.number),
                people: item.pr.author.map { [$0] } ?? [], checks: checks(item.pr),
                state: item.pr.isDraft ? "Draft, review requested" : "Review requested", stateColor: .secondary,
                tint: ChartPalette.blue, since: item.askedAt, sinceLabel: "Asked", size: (item.pr.additions, item.pr.deletions),
                page: .pullRequest(item.pr.id)
            )
        })) }
        if shown.contains(.pullRequests) { sections.append((InboxSection.pullRequests.rawValue, inbox.pullRequests.map { pr in
            let standing = Inbox.standing(pr, needsReview: configs.config(for: org).needsReview(pr.repo))
            return InboxRow(
                id: "pr-\(pr.id)", title: pr.title, reference: Self.number(pr.repo, pr.number),
                people: pr.requestedReviewers + pr.reviewers.filter { reviewer in !pr.requestedReviewers.contains { $0.login == reviewer.login } },
                checks: checks(pr), state: standing.text, stateColor: standing.color,
                tint: standing.color, since: pr.updatedAt, sinceLabel: "Last updated", size: (pr.additions, pr.deletions),
                page: .pullRequest(pr.id)
            )
        })) }
        if shown.contains(.issues) { sections.append((InboxSection.issues.rawValue, inbox.issues.map { item in
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
        })) }
        if shown.contains(.opened) { sections.append((InboxSection.opened.rawValue, opened.map(issueRow))) }
        if shown.contains(.plans) { sections.append((InboxSection.plans.rawValue, plans)) }
        if shown.contains(.uncategorised) { sections.append((InboxSection.uncategorised.rawValue, uncategorised.map(issueRow))) }
        // In your order, narrowed by the search (empty ones go while searching).
        let order = order
        return sections
            .map { ($0.title, $0.rows.filter(matches)) }
            .filter { search.isEmpty || !$0.1.isEmpty }
            .sorted { a, b in
                (InboxSection(rawValue: a.0).flatMap(order.firstIndex) ?? 99) < (InboxSection(rawValue: b.0).flatMap(order.firstIndex) ?? 99)
            }
    }

    // MARK: Sections you can turn on

    /// The issue history's issues as the workload sees them: excluded repos
    /// and hidden ones left out.
    private var historyIssues: [IssueRecord] {
        let excluded = configs.config(for: org).excludedRepos
        return (issueStore.history(for: org).map { Array($0.issues.values) } ?? [])
            .filter { !excluded.contains($0.repo) && !hidden.keys.contains($0.id) }
    }

    /// Open issues you opened, newest first, less those assigned to you
    /// (they're under Your issues).
    private var opened: [IssueRecord] {
        guard let login = auth.viewer?.login else { return [] }
        return historyIssues
            .filter { $0.isOpen && $0.author == login && !$0.assignees.contains(login) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Open issues, and those completed in the window, that no investment
    /// category takes, as the Investments page counts them: open ones first.
    private var uncategorised: [IssueRecord] {
        let config = configs.config(for: org).investmentConfig
        let issues = issueStore.history(for: org)?.issues ?? [:]
        let since = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now) ?? .now
        return historyIssues
            .filter { $0.isOpen || (!$0.isNotPlanned && ($0.closedAt ?? .distantPast) >= since) }
            .filter { config.categorise($0, parent: $0.parentID.flatMap { issues[$0] }) == nil }
            .sorted { a, b in
                if a.isOpen != b.isOpen { return a.isOpen }
                return (a.closedAt ?? a.createdAt) > (b.closedAt ?? b.createdAt)
            }
    }

    /// Plans in the harness you own that aren't done or abandoned, newest first.
    private var plans: [InboxRow] {
        guard let login = auth.viewer?.login, let setup = configs.config(for: org).harness,
              let index = harness.index(for: org, setup) else { return [] }
        return index.documents(.plans)
            .filter { $0.followsStandard && $0.owner?.lowercased() == login.lowercased() }
            .filter { !["done", "abandoned"].contains(($0.status ?? "").lowercased()) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .map { plan in
                InboxRow(
                    id: "plan-\(plan.path)", title: plan.title, reference: "Plan",
                    people: [], checks: nil,
                    state: [plan.statusLabel, plan.tasks > 0 ? "\(plan.tasksDone) of \(plan.tasks) tasks" : nil].compactMap { $0 }.joined(separator: ", "),
                    stateColor: .secondary, tint: ChartPalette.violet, since: plan.date, sinceLabel: "Dated",
                    size: nil, page: .harnessDocument(plan.path)
                )
            }
    }

    private func issueRow(_ record: IssueRecord) -> InboxRow {
        InboxRow(
            id: "issue-\(record.id)", title: record.title, reference: Self.number(record.repo, record.number),
            people: [], checks: nil,
            state: record.isOpen ? (record.statusChanges.last?.status ?? "Open") : "Closed",
            stateColor: .secondary, tint: record.isOpen ? .green : .purple,
            since: record.closedAt ?? record.createdAt, sinceLabel: record.isOpen ? "Opened" : "Closed",
            size: nil, page: .issueReference(IssueReference(org: org, record: record))
        )
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

    // What the columns sort by.
    var whoSort: String { people.first?.displayName.lowercased() ?? "" }
    var sinceSort: Date { since ?? .distantPast }
    var sizeSort: Int { size.map { $0.added + $0.removed } ?? -1 }
    /// Failing first, then running, then passing, then none.
    var checksSort: Int {
        switch checks {
        case .failure, .error: 0
        case .pending, .expected: 1
        case .success: 2
        case nil: 3
        }
    }
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
