import SwiftUI

// MARK: - Shared

private func age(_ date: Date, now: Date = .now) -> String {
    max(now.timeIntervalSince(date), 0).compactDuration
}

private func shortRepo(_ repo: String) -> String {
    repo.split(separator: "/").last.map(String.init) ?? repo
}

/// A PR on one line: number, title, repo and author, and its age.
private struct PullRequestLine: View {
    let pr: PullRequest
    let age: String
    var note: String?
    @Binding var selection: DetailSelection?

    var body: some View {
        Button { selection = .pullRequest(pr.id) } label: {
            HStack(spacing: 8) {
                Avatar(url: pr.author?.avatarUrl, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).lineLimit(1)
                    Text([("\(shortRepo(pr.repo))#\(pr.number)"), note].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(age).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Attention

/// What needs someone to act, ranked: broken main, goals off track, review
/// requests sitting (worse when the reviewer's off), approved work not
/// merged, changes asked for and not answered, committed work overdue,
/// people carrying too much, and work gone quiet.
struct AttentionOverview: View {
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.showSidebarItem) private var showSidebarItem
    @Environment(SessionStore.self) private var sessions
    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow
    let org: String
    let workload: Workload
    let scorecard: [ScorecardHeadline]
    @Binding var selection: DetailSelection?

    enum Severity: Int, Comparable {
        case critical, warning, notice
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .critical: "Act now"
            case .warning: "Today"
            case .notice: "Keep an eye on"
            }
        }

        var color: Color {
            switch self {
            case .critical: ChartPalette.critical
            case .warning: ChartPalette.warning
            case .notice: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .critical: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .notice: "eye"
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let severity: Severity
        let symbol: String
        let title: String
        let detail: String
        /// Sorts within a severity: bigger first.
        let weight: Double
        let open: () -> Void
    }

    var body: some View {
        let items = items()
        VStack(alignment: .leading, spacing: 24) {
            if items.isEmpty {
                ContentUnavailableView("Nothing needs attention", systemImage: "checkmark.seal", description: Text("Main is green, goals are on track and nothing's waiting too long."))
            }
            // Two columns: the groups side by side, so short rows don't
            // leave the width empty.
            let groups = [Severity.critical, .warning, .notice].compactMap { severity -> (Severity, [Item])? in
                let group = items.filter { $0.severity == severity }.sorted { $0.weight > $1.weight }
                return group.isEmpty ? nil : (severity, group)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.0) { severity, group in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(severity.title) · \(group.count)", systemImage: severity.symbol)
                            .font(.headline)
                            .foregroundStyle(severity.color)
                        VStack(spacing: 0) {
                            ForEach(Array(group.prefix(12).enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                row(item)
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        if group.count > 12 {
                            Text("and \(group.count - 12) more").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        Button(action: item.open) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .foregroundStyle(item.severity.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func items(now: Date = .now) -> [Item] {
        var items: [Item] = []
        let config = configs.config(for: org)
        let today = Calendar.current.startOfDay(for: now)
        func isOff(_ login: String) -> Bool {
            if case .absent = peopleDates.dates(for: login, in: org).status(on: today) { return true }
            return false
        }
        let names = Dictionary(workload.people.map { ($0.person.login, $0.person.displayName) }, uniquingKeysWith: { a, _ in a })
        func name(_ login: String) -> String { names[login] ?? login }

        // Main broken.
        if let history = actionsStore.history(for: org) {
            let actions = ActionsMetrics(history: history, window: MetricsWindow(code: 30), config: config)
            for workflow in actions.red {
                let since = workflow.defaultBranch?.redSince
                items.append(Item(
                    id: "red \(workflow.id)", severity: .critical, symbol: "xmark.octagon",
                    title: "\(workflow.name) is red on \(workflow.shortRepo)",
                    detail: since.map { "Failing for \(age($0, now: now))" } ?? "Failing on the default branch",
                    weight: since.map { now.timeIntervalSince($0) } ?? 0,
                    open: { selection = .workflow(workflow.id) }
                ))
            }
        }

        // Goals off track.
        for headline in scorecard where headline.met == false {
            items.append(Item(
                id: "goal \(headline.id)", severity: .warning, symbol: "target",
                title: "\(headline.measurable.name) is off target",
                detail: [headline.valueText, headline.targetText.map { "target \($0)" }, headline.periodText].compactMap { $0 }.joined(separator: " · "),
                weight: 1,
                open: { showSidebarItem?(.tab(.scorecard)) }
            ))
        }

        // Yours to approve: Claude would, and the team's waiting on it.
        if let me = auth.viewer?.login {
            for pr in workload.openPullRequests where !pr.isDraft && pr.requestedReviewers.contains(where: { $0.login == me }) {
                guard let session = sessions.readyForApproval(pr.id) else { continue }
                let asked = pr.reviewRequestedAt[me] ?? pr.createdAt
                items.append(Item(
                    id: "approve \(pr.id)", severity: .critical, symbol: "checkmark.seal",
                    title: pr.title,
                    detail: "Claude would approve: yours to look over, asked \(age(asked, now: now)) ago · \(shortRepo(pr.repo))#\(pr.number)",
                    // Above everything else that's urgent.
                    weight: .greatestFiniteMagnitude / 2 + now.timeIntervalSince(asked),
                    open: { sessions.show(session.id, with: openWindow) }
                ))
            }
        }

        for pr in workload.openPullRequests where !pr.isDraft {
            // Review requests sitting, worse with the reviewer off.
            for reviewer in pr.requestedReviewers {
                guard let asked = pr.reviewRequestedAt[reviewer.login] else { continue }
                let waited = now.timeIntervalSince(asked)
                let off = isOff(reviewer.login)
                guard waited > 24 * 3600 || (off && waited > 2 * 3600) else { continue }
                items.append(Item(
                    id: "review \(pr.id) \(reviewer.login)", severity: off || waited > 3 * 24 * 3600 ? .critical : .warning,
                    symbol: off ? "person.crop.circle.badge.moon" : "eye.trianglebadge.exclamationmark",
                    title: pr.title,
                    detail: "Waiting on \(reviewer.displayName) for \(age(asked, now: now))\(off ? ", who's off today" : "") · \(shortRepo(pr.repo))#\(pr.number)",
                    weight: waited,
                    open: { selection = .pullRequest(pr.id) }
                ))
            }
            // Approved and sitting.
            if pr.review == .approved, let approved = pr.reviewedAt?.values.max(), now.timeIntervalSince(approved) > 24 * 3600 {
                items.append(Item(
                    id: "approved \(pr.id)", severity: .warning, symbol: "checkmark.circle.badge.questionmark",
                    title: pr.title,
                    detail: "Approved \(age(approved, now: now)) ago, not merged · \(pr.author.map { name($0.login) } ?? "") · \(shortRepo(pr.repo))#\(pr.number)",
                    weight: now.timeIntervalSince(approved),
                    open: { selection = .pullRequest(pr.id) }
                ))
            }
            // Changes asked for, nothing since.
            if pr.review == .changesRequested {
                let asked = pr.reviewedAt?.values.max() ?? pr.updatedAt
                let since = max(pr.authorRepliedAt ?? .distantPast, pr.lastCommitAt ?? .distantPast)
                if since < asked, now.timeIntervalSince(asked) > 2 * 24 * 3600 {
                    items.append(Item(
                        id: "changes \(pr.id)", severity: .notice, symbol: "arrow.uturn.backward.circle",
                        title: pr.title,
                        detail: "Changes asked for \(age(asked, now: now)) ago, no reply · \(pr.author.map { name($0.login) } ?? "")",
                        weight: now.timeIntervalSince(asked),
                        open: { selection = .pullRequest(pr.id) }
                    ))
                }
            }
            // Gone quiet.
            if Workload.isStale(pr) {
                items.append(Item(
                    id: "stale \(pr.id)", severity: .notice, symbol: "moon.zzz",
                    title: pr.title,
                    detail: "No activity for \(age(pr.updatedAt, now: now)) · \(pr.author.map { name($0.login) } ?? "") · \(shortRepo(pr.repo))#\(pr.number)",
                    weight: now.timeIntervalSince(pr.updatedAt) / 10,
                    open: { selection = .pullRequest(pr.id) }
                ))
            }
        }

        // Committed work overdue.
        if let board = config.workflow.projectNumber, let history = issueStore.history(for: org) {
            let field = configs.config(for: org).committedDate
            for record in history.issues.values where record.isOpen && !config.repoExclusion.contains(record.repo) {
                guard case .date(let due)? = record.fields(onProject: board)?.values[field], due < today else { continue }
                items.append(Item(
                    id: "overdue \(record.id)", severity: .critical, symbol: "calendar.badge.exclamationmark",
                    title: record.title,
                    detail: "Committed for \(due.formatted(.dateTime.day().month(.abbreviated))), \(age(due, now: now)) overdue · \(shortRepo(record.repo))#\(record.number)",
                    weight: now.timeIntervalSince(due),
                    open: { selection = .issueReference(IssueReference(org: org, id: record.id, number: record.number, title: record.title, repo: record.repo, url: record.url)) }
                ))
            }
        }

        // Carrying too much: well over the team's usual.
        let loads = workload.people.map(\.inFlight).filter { $0 > 0 }.sorted()
        let typical = loads.isEmpty ? 0 : loads[loads.count / 2]
        for load in workload.people where load.inFlight >= max(5, typical * 2) {
            items.append(Item(
                id: "load \(load.id)", severity: .notice, symbol: "scalemass",
                title: "\(load.person.displayName) has \(load.inFlight) things in flight",
                detail: "Usual is \(typical) · \(load.pullRequests.count) PRs, \(load.reviewRequests.count) reviews owed",
                weight: Double(load.inFlight),
                open: { selection = .person(load.person.login) }
            ))
        }
        return items
    }
}

// MARK: - Team

/// The team at a glance, in tiles (who's in and off, reviews owed, who's
/// free, and the open work), then a card per person: today (in or off,
/// and when they're next off), what they're carrying against the busiest,
/// the reviews they owe and how long the oldest has waited, and what they
/// merged and reviewed in the window.
struct TeamOverview: View {
    @Environment(PeopleDatesStore.self) private var peopleDates
    let org: String
    let workload: Workload
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    var body: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let people = workload.people.sorted { $0.inFlight > $1.inFlight }
        let most = max(people.map(\.inFlight).max() ?? 1, 1)
        let weeks = weeks()
        let merged = mergedByAuthor(weeks: weeks)
        let reviewed = Dictionary((metrics?.people ?? []).map { ($0.person.login, $0.reviewsGiven) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 16) {
            tiles(people, today: today)
            EvenGrid(minWidth: 260, spacing: 12) {
                ForEach(people) { load in
                    card(load, most: most, today: today, weeks: weeks, merged: merged[load.person.login] ?? [:], reviewed: reviewed[load.person.login] ?? 0)
                }
            }
        }
    }

    /// Every tile with a subtitle, so they're the same height.
    private func tiles(_ people: [PersonLoad], today: Date) -> some View {
        let off = people.filter { isOff($0.person.login, on: today) }
        let owed = people.flatMap { load in load.reviewRequests.compactMap { $0.reviewRequestedAt[load.person.login] } }
        let free = people.filter { $0.inFlight == 0 && !isOff($0.person.login, on: today) }
        let open = workload.openPullRequests
        let stale = open.filter(Workload.isStale)
        return EvenGrid(minWidth: 190, spacing: 12) {
            StatTile(title: "In today", value: "\(people.count - off.count)", detail: "Of \(people.count) people")
            StatTile(title: "Off", value: "\(off.count)", detail: off.isEmpty ? "Nobody off today" : off.map(\.person.displayName).joined(separator: ", "))
            StatTile(title: "Reviews owed", value: "\(owed.count)", detail: owed.min().map { "Oldest asked \(age($0)) ago" } ?? "Nobody waiting")
            StatTile(title: "Nothing in flight", value: "\(free.count)", detail: free.isEmpty ? "Everyone has work on" : free.map(\.person.displayName).joined(separator: ", "))
            StatTile(title: "Open PRs", value: "\(open.count)", detail: "\(open.filter(\.isDraft).count) drafts", drill: .openPullRequests, selection: $selection)
            StatTile(
                title: "Awaiting first review", value: "\(workload.awaitingFirstReview.count)",
                detail: workload.awaitingFirstReview.first.map { "Oldest opened " + $0.createdAt.formatted(.relative(presentation: .named)) } ?? "None waiting",
                drill: .awaitingFirstReview, selection: $selection
            )
            StatTile(title: "Stale PRs", value: "\(stale.count)", detail: "No activity for \(Workload.staleAfterDays)d", drill: .stalePullRequests, selection: $selection)
            if workload.team == nil {
                StatTile(title: "Unassigned issues", value: "\(workload.unassignedIssues.count)", detail: "Open, nobody assigned", drill: .unassignedIssues, selection: $selection)
            }
        }
    }

    private func isOff(_ login: String, on day: Date) -> Bool {
        if case .absent = peopleDates.dates(for: login, in: org).status(on: day) { return true }
        return false
    }

    /// The next day off in the coming fortnight, if any.
    private func nextOff(_ login: String, after today: Date) -> Date? {
        (1...14).lazy.compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }.first { isOff(login, on: $0) }
    }

    /// The window's weeks, oldest first.
    private func weeks() -> [Date] {
        guard let interval = metrics?.interval else { return Calendar.metrics.weeks(back: 8) }
        var weeks: [Date] = []
        var week = Calendar.metrics.startOfWeek(for: interval.start)
        while week < interval.end {
            weeks.append(week)
            week = Calendar.metrics.date(byAdding: .day, value: 7, to: week) ?? interval.end
        }
        return weeks
    }

    /// PRs merged in the window, by author and week.
    private func mergedByAuthor(weeks: [Date]) -> [String: [Date: Int]] {
        var counts: [String: [Date: Int]] = [:]
        for pr in metrics?.merged ?? [] {
            guard let login = pr.author?.login else { continue }
            counts[login, default: [:]][Calendar.metrics.startOfWeek(for: pr.mergedAt), default: 0] += 1
        }
        return counts
    }

    private func card(_ load: PersonLoad, most: Int, today: Date, weeks: [Date], merged: [Date: Int], reviewed: Int) -> some View {
        let login = load.person.login
        let status = peopleDates.dates(for: login, in: org).status(on: today)
        let oldestReview = load.reviewRequests.compactMap { $0.reviewRequestedAt[login] }.min()
        let next = nextOff(login, after: today)
        let points = weeks.map { ScorecardPoint(start: $0, value: Double(merged[$0] ?? 0)) }
        let total = merged.values.reduce(0, +)
        return Button { selection = .person(login) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Avatar(url: load.person.avatarUrl, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(load.person.displayName).font(.headline).lineLimit(1)
                        Group {
                            if let status {
                                Label(status.label, systemImage: "moon.fill").foregroundStyle(ChartPalette.warning)
                            } else if let next {
                                Text("In · off \(next.formatted(.dateTime.weekday(.wide)))")
                            } else {
                                Text("In")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("In flight").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(load.inFlight)").monospacedDigit().fontWeight(.semibold)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(ChartPalette.blue)
                                .frame(width: geometry.size.width * CGFloat(load.inFlight) / CGFloat(most))
                        }
                    }
                    .frame(height: 6)
                }
                .font(.callout)
                HStack(alignment: .top, spacing: 14) {
                    stat("\(load.pullRequests.count)", "PRs open")
                    stat("\(load.reviewRequests.count)", oldestReview.map { "reviews, oldest \(age($0))" } ?? "reviews owed")
                    stat("\(load.activeIssues.count)", "issues")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Merged \(total), reviewed \(reviewed) · \(metrics?.window.phrase ?? "8 weeks")").font(.caption).foregroundStyle(.secondary)
                    ScorecardSparkline(points: points, goal: nil, filled: true).frame(height: 30)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if status != nil {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(ChartPalette.warning.opacity(0.5))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Flow

/// Open PRs as a pipeline, left to right: draft, waiting for a first
/// review, being reviewed, changes asked for, approved, then merged this
/// week. Each stage: how many, how long they've sat (median), and the
/// oldest.
struct FlowOverview: View {
    let org: String
    let workload: Workload
    /// For what merged in the window.
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    enum Stage: String, CaseIterable {
        case draft = "Draft"
        case waiting = "Waiting for review"
        case reviewing = "In review"
        case changes = "Changes asked"
        case approved = "Approved"

        var color: Color {
            switch self {
            case .draft: .secondary
            case .waiting: ChartPalette.orange
            case .reviewing: ChartPalette.blue
            case .changes: ChartPalette.magenta
            case .approved: ChartPalette.aqua
            }
        }
    }

    private func stage(_ pr: PullRequest) -> Stage {
        if pr.isDraft { return .draft }
        switch pr.review {
        case .approved: return .approved
        case .changesRequested: return .changes
        default: return (pr.reviewedAt ?? [:]).isEmpty ? .waiting : .reviewing
        }
    }

    /// When it entered its stage, as near as the snapshot says.
    private func since(_ pr: PullRequest, _ stage: Stage) -> Date {
        switch stage {
        case .draft, .waiting: pr.reviewRequestedAt.values.min() ?? pr.createdAt
        case .reviewing, .changes, .approved: pr.reviewedAt?.values.max() ?? pr.updatedAt
        }
    }

    var body: some View {
        let now = Date.now
        let byStage = Dictionary(grouping: workload.openPullRequests, by: stage)
        VStack(alignment: .leading, spacing: 20) {
            pipelineBar(byStage, total: workload.openPullRequests.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Stage.allCases, id: \.self) { stage in
                        column(stage, prs: byStage[stage] ?? [], now: now)
                    }
                    mergedColumn(now: now)
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// The open PRs' split as one bar.
    private func pipelineBar(_ byStage: [Stage: [PullRequest]], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(total) open PRs").font(.title2.weight(.semibold))
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Stage.allCases, id: \.self) { stage in
                        let count = byStage[stage]?.count ?? 0
                        if count > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(stage.color)
                                .frame(width: max(4, (geometry.size.width - 10) * CGFloat(count) / CGFloat(max(total, 1))))
                                .help("\(stage.rawValue): \(count)")
                        }
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(Stage.allCases, id: \.self) { stage in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(stage.color).frame(width: 10, height: 10)
                        Text("\(stage.rawValue) \(byStage[stage]?.count ?? 0)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func column(_ stage: Stage, prs: [PullRequest], now: Date) -> some View {
        let waits = prs.map { now.timeIntervalSince(since($0, stage)) }.sorted()
        let median = waits.isEmpty ? nil : waits[waits.count / 2]
        let oldest = prs.sorted { since($0, stage) < since($1, stage) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(stage.color).frame(width: 8, height: 8)
                Text(stage.rawValue).font(.headline)
                Spacer()
                Text("\(prs.count)").font(.headline.monospacedDigit())
            }
            Text(median.map { "Median \($0.compactDuration) here" } ?? "Empty").font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(oldest.prefix(6)) { pr in
                PullRequestLine(pr: pr, age: age(since(pr, stage), now: now), selection: $selection)
            }
            if prs.count > 6 {
                Text("and \(prs.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// What merged in the window, newest first.
    private func mergedColumn(now: Date) -> some View {
        let merged = (metrics?.merged ?? []).sorted { $0.mergedAt > $1.mergedAt }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(ChartPalette.good)
                Text("Merged").font(.headline)
                Spacer()
                Text("\(merged.count)").font(.headline.monospacedDigit())
            }
            Text(metrics.map { $0.window.title } ?? "In the window").font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(merged.prefix(6), id: \.id) { pr in
                Button {
                    selection = .pullRequestReference(PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url))
                } label: {
                    HStack(spacing: 8) {
                        Avatar(url: pr.author?.avatarUrl, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pr.title).lineLimit(1)
                            Text("\(shortRepo(pr.repo))#\(pr.number)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(age(pr.mergedAt, now: now)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension Calendar {
    /// The starts of the last `count` whole weeks, oldest first.
    func weeks(back count: Int, now: Date = .now) -> [Date] {
        let thisWeek = startOfWeek(for: now)
        return (1...count).reversed().compactMap { date(byAdding: .day, value: -7 * $0, to: thisWeek) }
    }
}
