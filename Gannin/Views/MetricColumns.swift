import SwiftUI

/// A number on the overview that can be opened into the items behind it.
enum MetricDrill: Hashable {
    case openPullRequests
    case stalePullRequests
    case awaitingFirstReview
    case unassignedIssues
    case merged
    case cycleTime
    case timeToFirstReview
    case mergedWithoutReview
    case stage(CycleStage)
    case repo(String)
    case week(Date)
    case personStats(String)
    case unansweredRequests
    /// An investment category's issues, recomputed live.
    case investment(InvestmentBalance.Drill)

    var title: String {
        switch self {
        case .openPullRequests: "Open pull requests"
        case .stalePullRequests: "Stale pull requests"
        case .awaitingFirstReview: "Awaiting first review"
        case .unassignedIssues: "Unassigned issues"
        case .merged: "Merged"
        case .cycleTime: "Cycle time"
        case .timeToFirstReview: "Time to first review"
        case .mergedWithoutReview: "Merged without review"
        case .stage(let stage): stage.rawValue
        case .repo(let repo): repo
        case .week(let week): "Week of \(week.formatted(.dateTime.day().month()))"
        case .personStats(let login): login
        case .unansweredRequests: "Unanswered review requests"
        case .investment(let drill): drill.title
        }
    }

    var explanation: String? {
        switch self {
        case .stalePullRequests: "Open PRs with no activity for \(Workload.staleAfterDays) days."
        case .awaitingFirstReview: "Open, ready PRs nobody has reviewed yet, oldest first."
        case .cycleTime: "First commit to merge, slowest first."
        case .timeToFirstReview: "Ready for review to the first review by someone other than the author, slowest first."
        case .mergedWithoutReview: "Merged with no review from anyone but the author."
        case .stage(let stage): "\(stage.help), slowest first."
        case .personStats: "Their PRs merged in the window, and review requests on merged PRs plus open ones waiting on them. Response time runs from the request (or the PR being marked ready) to their first review."
        case .unansweredRequests: "Requested reviewers who never reviewed before the PR merged. Withdrawn requests aren't counted."
        case .investment: "Right-click an issue to choose its investment category by hand; click it to open it in its own window."
        default: nil
        }
    }
}

// MARK: - Drill column

struct MetricColumn: View {
    let drill: MetricDrill
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(drill.title).font(.title3.weight(.semibold))
                    if let explanation = drill.explanation {
                        Text(explanation).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch drill {
        case .openPullRequests:
            openSection(workload?.openPullRequests ?? [])
        case .stalePullRequests:
            openSection((workload?.openPullRequests ?? []).filter(Workload.isStale))
        case .awaitingFirstReview:
            openSection((workload?.awaitingFirstReview ?? []))
        case .unassignedIssues:
            let issues = workload?.unassignedIssues ?? []
            Section(header: SectionHeader(title: "Issues", count: issues.count)) {
                ForEach(issues) { issue in
                    IssueRow(issue: issue, linked: workload?.linkedPullRequests(for: issue) ?? [])
                        .tag(DetailSelection.issue(issue.id))
                }
            }
        case .merged:
            mergedSection(metrics?.merged ?? [], value: nil)
        case .cycleTime:
            mergedSection(metrics?.merged ?? [], value: { $0.cycleTime })
        case .timeToFirstReview:
            mergedSection((metrics?.merged ?? []).filter { $0.firstReviewAt != nil }, value: { $0.timeToFirstReview ?? 0 })
        case .mergedWithoutReview:
            mergedSection(metrics?.mergedWithoutReview ?? [], value: nil)
        case .stage(let stage):
            mergedSection((metrics?.merged ?? []).filter { $0.duration(of: stage) != nil }, value: { $0.duration(of: stage) ?? 0 })
        case .repo(let repo):
            mergedSection((metrics?.merged ?? []).filter { $0.repo == repo }, value: { $0.cycleTime })
        case .week(let week):
            let end = Calendar.metrics.date(byAdding: .day, value: 7, to: week) ?? week
            mergedSection(metrics?.mergedInRange(week..<end) ?? [], value: { $0.cycleTime })
        case .personStats(let login):
            let outcomes = (metrics?.reviewOutcomes ?? []).filter { $0.login == login }
            Section {
                Button {
                    selection = .person(login)
                } label: {
                    Label("Current work", systemImage: "person.crop.rectangle.stack")
                }
                .linkButton()
            }
            pendingSection((metrics?.pendingReviews ?? []).filter { $0.login == login }, showReviewer: false)
            outcomeSection("Review requests not answered", outcomes.filter { $0.respondedAt == nil }, showReviewer: false)
            outcomeSection("Review requests answered", outcomes.filter { $0.respondedAt != nil }, showReviewer: false)
            mergedSection((metrics?.merged ?? []).filter { $0.author?.login == login }, value: { $0.cycleTime }, title: "Their merged PRs")
        case .unansweredRequests:
            outcomeSection("Not answered", (metrics?.reviewOutcomes ?? []).filter { $0.respondedAt == nil }, showReviewer: true)
        case .investment(let drill):
            issuesSection(investmentIssues(drill))
        }
    }

    @Environment(IssueStore.self) private var issueStore
    @Environment(\.currentOrg) private var org
    @Environment(\.openWindow) private var openWindow
    @Environment(\.navigate) private var navigate

    @Environment(OrgConfigStore.self) private var configs

    /// The drill's issues from the live history and config.
    private func investmentIssues(_ drill: InvestmentBalance.Drill) -> [IssueRecord] {
        guard let org, let history = issueStore.history(for: org) else { return [] }
        let balance = InvestmentBalance(history: history, config: configs.config(for: org), team: workload?.team, range: drill.range, granularity: drill.period)
        return balance.issues(for: drill)
    }

    /// Issues, newest completed first, open ones on top.
    private func issuesSection(_ records: [IssueRecord]) -> some View {
        let records = records
            .sorted { ($0.closedAt ?? .distantFuture) > ($1.closedAt ?? .distantFuture) }
        return Section(header: SectionHeader(title: "Issues", count: records.count)) {
            ForEach(records) { record in
                Button {
                    if let org {
                        let reference = IssueReference(org: org, record: record)
                        if let navigate { navigate(.issueReference(reference)) } else { openWindow(value: reference) }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(record.repo)#\(String(record.number))")
                                if let author = record.author { Text("by \(author)") }
                                if let closedAt = record.closedAt {
                                    Text("· completed")
                                    RelativeDate(date: closedAt)
                                } else {
                                    Text("· open")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        AvatarStack(people: record.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let org { OpenElsewhereItems(.issueReference(IssueReference(org: org, record: record))) }
                    CategoriseMenu(issueID: record.id)
                    Link("Open on GitHub", destination: record.url)
                }
            }
        }
    }

    private func pendingSection(_ pending: [PendingReview], showReviewer: Bool) -> some View {
        Section(header: SectionHeader(title: "Waiting on them now", count: pending.count)) {
            ForEach(pending) { item in
                VStack(alignment: .leading, spacing: 2) {
                    PullRequestRow(pr: item.pr)
                    HStack(spacing: 3) {
                        Image(systemName: "hourglass")
                        Text("Asked")
                        RelativeDate(date: item.since)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                .tag(DetailSelection.pullRequest(item.pr.id))
            }
        }
    }

    /// Review requests, slowest (or, unanswered, oldest) first.
    private func outcomeSection(_ title: String, _ outcomes: [ReviewRequestOutcome], showReviewer: Bool) -> some View {
        let sorted = outcomes.sorted {
            if let a = $0.responseTime, let b = $1.responseTime { return a > b }
            return $0.requestedAt < $1.requestedAt
        }
        return Section(header: SectionHeader(title: title, count: outcomes.count)) {
            ForEach(sorted) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                    MetricPullRequestRow(pr: outcome.pr, value: outcome.responseTime)
                    HStack(spacing: 3) {
                        if showReviewer {
                            Text(outcome.login).fontWeight(.medium)
                        }
                        Text("asked \(outcome.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                        if outcome.respondedAt == nil {
                            Text("· merged without their review")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(DetailSelection.pullRequest(outcome.pr.id))
            }
        }
    }

    private func openSection(_ prs: [PullRequest]) -> some View {
        Section(header: SectionHeader(title: "Pull requests", count: prs.count)) {
            ForEach(prs) { pr in
                PullRequestRow(pr: pr).tag(DetailSelection.pullRequest(pr.id))
            }
        }
    }

    /// Merged PRs, sorted by `value` (slowest first) when given, else newest first.
    private func mergedSection(
        _ prs: [MetricPullRequest],
        value: ((MetricPullRequest) -> TimeInterval)?,
        title: String = "Merged pull requests"
    ) -> some View {
        let sorted = value.map { value in prs.sorted { value($0) > value($1) } } ?? prs.sorted { $0.mergedAt > $1.mergedAt }
        return Section(header: SectionHeader(title: title, count: prs.count)) {
            ForEach(sorted) { pr in
                MetricPullRequestRow(pr: pr, value: value?(pr)).tag(DetailSelection.pullRequest(pr.id))
            }
        }
    }
}

struct MetricPullRequestRow: View {
    let pr: MetricPullRequest
    let value: TimeInterval?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(pr.repo)#\(String(pr.number))")
                    if let author = pr.author {
                        Text("by \(author.login)")
                    }
                    Text("·")
                    Text("merged")
                    RelativeDate(date: pr.mergedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let value {
                Text(value.compactDuration)
                    .font(.callout.monospacedDigit().weight(.medium))
            }
        }
        .padding(.vertical, 2)
        .hideable(pr.id, url: pr.url, opens: .pullRequest(pr.id))
    }
}

// MARK: - Merged PR column

/// A merged PR that's only in the metrics history (older than the snapshot).
struct MetricPullRequestColumn: View {
    let pr: MetricPullRequest
    @Binding var selection: DetailSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                ItemHeader(
                    title: pr.title,
                    reference: "\(pr.repo)#\(pr.number)",
                    url: pr.url,
                    pill: Pill(text: "Merged", color: .purple)
                )
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    if let author = pr.author {
                        PeopleGridRow(title: "Author", people: [author], selection: $selection)
                    }
                    PeopleGridRow(
                        title: "Reviewed by",
                        people: pr.reviewers.map { Person(login: $0, name: nil, avatarUrl: nil) },
                        selection: $selection
                    )
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("+\(pr.additions)").foregroundStyle(.green)
                            Text("-\(pr.deletions)").foregroundStyle(.red)
                        }
                        .monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
            }
            TimelineSection(pr: pr)
            DescriptionSections(id: pr.id, url: pr.url)
        }
        .task(id: pr.id) { await details.load(pr.id) }
    }

    @Environment(DetailStore.self) private var details
}

// MARK: - Timeline

/// Each step from first commit to merge, with the time each stage took.
struct TimelineSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.currentOrg) private var org
    let pr: MetricPullRequest

    var body: some View {
        Section(header: HStack {
            Text("Timeline")
            Spacer()
            Text("Cycle time \(pr.cycleTime.compactDuration)").monospacedDigit()
        }) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                step("First commit", pr.firstCommitAt ?? pr.startedAt, stage: nil)
                step("Opened", pr.createdAt, stage: nil)
                if let ready = pr.readyAt {
                    step("Ready for review", ready, stage: nil)
                }
                step("Coding", nil, stage: .coding)
                if let review = pr.firstReviewAt {
                    step("First review" + (pr.firstReviewer.map { " by \($0)" } ?? ""), review, stage: .waiting)
                } else if org.map({ configs.config(for: $0).needsReview(pr.repo) }) ?? true {
                    GridRow {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text("No review before merge").foregroundStyle(.secondary)
                        Text("")
                    }
                    .help("PRs in \(pr.repo) should have a review. If they don't need one, untick Needs Review for it in the org's Settings, under Repositories.")
                } else {
                    GridRow {
                        Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                        Text("No review, which \(pr.repo) doesn't need").foregroundStyle(.secondary)
                        Text("")
                    }
                }
                if let approved = pr.approvedAt {
                    step("Approved", approved, stage: .rework)
                }
                step("Merged", pr.mergedAt, stage: pr.approvedAt == nil ? nil : .merging)
            }
            .padding(.vertical, 4)

            if !pr.reviewRequests.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review requests").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(pr.reviewRequests, id: \.self) { request in
                        HStack(spacing: 6) {
                            Text(request.login).fontWeight(.medium)
                            Text(requestOutcome(request))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func requestOutcome(_ request: MetricReviewRequest) -> String {
        let deadline = request.removedAt ?? pr.mergedAt
        let start = max(request.requestedAt, pr.reviewableAt)
        if let review = pr.reviews.first(where: {
            $0.login == request.login && $0.submittedAt >= request.requestedAt && $0.submittedAt <= deadline
        }) {
            return "reviewed after \(max(0, review.submittedAt.timeIntervalSince(start)).compactDuration)"
        }
        return request.removedAt == nil ? "never reviewed" : "request withdrawn"
    }

    /// A dated step, or (with a nil date) a stage-only row. The stage is the
    /// span that ended at this step.
    @ViewBuilder
    private func step(_ title: String, _ date: Date?, stage: CycleStage?) -> some View {
        if let date {
            GridRow {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let stage, let duration = pr.duration(of: stage) {
                    StageDuration(stage: stage, duration: duration)
                } else {
                    Text("")
                }
            }
        } else if let stage, let duration = pr.duration(of: stage) {
            GridRow {
                Text("")
                Text("")
                StageDuration(stage: stage, duration: duration)
            }
        }
    }
}

private struct StageDuration: View {
    let stage: CycleStage
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(stage.color).frame(width: 8, height: 8)
            Text("\(stage.rawValue) \(duration.compactDuration)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .gridColumnAlignment(.trailing)
        .help(stage.help)
    }
}

// MARK: - Colours

extension CycleStage {
    /// Categorical slots 1-4 of the validated chart palette, in order.
    var color: Color {
        switch self {
        case .coding: ChartPalette.blue
        case .waiting: ChartPalette.orange
        case .rework: ChartPalette.aqua
        case .merging: ChartPalette.yellow
        }
    }
}

enum ChartPalette {
    static let blue = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let orange = Color(light: 0xEB6834, dark: 0xD95926)
    static let aqua = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let yellow = Color(light: 0xEDA100, dark: 0xC98500)
    static let magenta = Color(light: 0xE87BA4, dark: 0xD55181)
    static let green = Color(light: 0x008300, dark: 0x008300)
    static let violet = Color(light: 0x4A3AA7, dark: 0x9085E9)
    static let red = Color(light: 0xE34948, dark: 0xE66767)
    /// For "no category"; not a series hue.
    static let neutral = Color(light: 0xB9B8B2, dark: 0x5A5955)

    /// Status colours, for states rather than series (a run passed or
    /// failed). Never used for a series, and always beside a label or shape.
    static let good = Color(light: 0x0CA30C, dark: 0x0CA30C)
    static let warning = Color(light: 0xFAB219, dark: 0xFAB219)
    static let critical = Color(light: 0xD03B3B, dark: 0xD03B3B)

    /// Categorical slots 1-8 in the palette's fixed, validated order.
    static let categorical = [blue, orange, aqua, yellow, magenta, green, violet, red]

    static func slot(_ slot: Int?) -> Color {
        guard let slot, categorical.indices.contains(slot) else { return neutral }
        return categorical[slot]
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        func color(_ hex: UInt32) -> NSColor {
            let (r, g, b) = components(hex)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}
