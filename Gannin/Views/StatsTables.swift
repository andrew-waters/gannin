import SwiftUI

// The overview's People and Repositories tables, built on `StatsTable`.

// MARK: - Rows

nonisolated extension PersonStatsRow {
    // Sort keys. Missing durations sort as -1, so they go last when
    // sorting slowest first.
    var name: String { person.displayName }
    var merged: Int { author?.merged ?? 0 }
    var cycle: Double { author?.cycleTime.median ?? -1 }
    var ttfr: Double { author?.timeToFirstReview.median ?? -1 }
    var reviewed: Int { author?.reviewsGiven ?? 0 }
    var asked: Int { reviewer?.requested ?? 0 }
    var answered: Double { reviewer?.responseRate ?? -1 }
    var response: Double { reviewer?.responseTime.median ?? -1 }
    /// Waiting count first, then the oldest wait.
    var waiting: Double {
        let pending = Double(reviewer?.pending ?? 0)
        let oldest = reviewer?.oldestPendingSince.map { Date.now.timeIntervalSince($0) } ?? 0
        return pending * 1e9 + oldest
    }
}

nonisolated extension RepoMetrics {
    var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var cycle: Double { cycleTime.median ?? -1 }
}

// MARK: - People

struct PeopleStatsTable: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let metrics: OrgMetrics
    @Binding var selection: DetailSelection?

    /// Nil keeps the default order: most active first.
    @State private var sort: StatsSort?

    var body: some View {
        let rows = PersonStatsRow.rows(metrics).sorted {
            $0.activity != $1.activity ? $0.activity > $1.activity : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        StatsTable(
            rows: rows,
            columns: columns(rows),
            sort: $sort,
            selectedID: selectedLogin,
            onSelect: { selection = .metric(.personStats($0.person.login)) },
            contextMenu: { row in
                AnyView(Button("Exclude \(row.person.login) from Stats") {
                    configs.toggleAuthor(row.person.login, in: org)
                })
            },
            destination: { .metric(.personStats($0.person.login)) }
        )
    }

    private var selectedLogin: String? {
        if case .metric(.personStats(let login)) = selection { return login }
        return nil
    }

    private func columns(_ rows: [PersonStatsRow]) -> [StatsColumn<PersonStatsRow>] {
        let days = metrics.window.lengthInDays()
        let cycleScale = BarScale(rows.compactMap { $0.author?.cycleTime.median })
        let ttfrScale = BarScale(rows.compactMap { $0.author?.timeToFirstReview.median })
        let responseScale = BarScale(rows.compactMap { $0.reviewer?.responseTime.median })

        return [
            StatsColumn(
                id: "person", title: "Person", help: "Org members with PRs or review requests in the window",
                width: nil, minWidth: 180,
                sortKey: { .text($0.name.lowercased()) },
                cell: { row in
                    AnyView(HStack(spacing: 8) {
                        Avatar(url: row.person.avatarUrl, size: 22)
                        Text(row.person.displayName).lineLimit(1)
                        if row.reviewer?.needsAttention == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Answers under half their review requests, or takes over a day at the median")
                                .accessibilityLabel("Slow or unresponsive reviewer")
                        }
                    })
                }
            ),
            StatsColumn(
                id: "merged", title: "Merged", help: "PRs they authored that merged in the window",
                width: 76, group: "Authoring",
                sortKey: { .number(Double($0.merged)) },
                cell: { row in
                    AnyView(NumberCell(text: "\(row.merged)", dimmed: row.merged == 0)
                        .help("\(row.merged) PRs they authored were merged in the last \(days) days"))
                }
            ),
            StatsColumn(
                id: "cycle", title: "Cycle", help: "Median first commit to merge on their PRs",
                width: 140, group: "Authoring",
                sortKey: { .number($0.cycle) },
                cell: { row in
                    AnyView(BarCell(value: row.author?.cycleTime.median, scale: cycleScale)
                        .help(Self.durationHelp("Median cycle time (first commit to merge) of their PRs", row.author?.cycleTime)))
                }
            ),
            StatsColumn(
                id: "ttfr", title: "TTFR", help: "Median time their PRs waited for a first review",
                width: 140, group: "Authoring",
                sortKey: { .number($0.ttfr) },
                cell: { row in
                    AnyView(BarCell(value: row.author?.timeToFirstReview.median, scale: ttfrScale)
                        .help(Self.durationHelp("Median time their PRs waited for a first review", row.author?.timeToFirstReview)))
                }
            ),
            StatsColumn(
                id: "reviewed", title: "Reviewed", help: "Other people's merged PRs they reviewed",
                width: 88, group: "Reviewing",
                sortKey: { .number(Double($0.reviewed)) },
                cell: { row in
                    AnyView(NumberCell(text: "\(row.reviewed)", dimmed: row.reviewed == 0)
                        .help("They reviewed \(row.reviewed) of other people's PRs merged in the last \(days) days"))
                }
            ),
            StatsColumn(
                id: "asked", title: "Asked", help: "Review requests on PRs merged in the window, withdrawn ones excluded",
                width: 72, group: "Reviewing",
                sortKey: { .number(Double($0.asked)) },
                cell: { row in
                    AnyView(NumberCell(text: "\(row.asked)", dimmed: row.asked == 0)
                        .help("Asked to review \(row.asked) times on PRs merged in the last \(days) days (withdrawn requests not counted)"))
                }
            ),
            StatsColumn(
                id: "answered", title: "Answered", help: "Share of their requests reviewed before the PR merged",
                width: 90, group: "Reviewing",
                sortKey: { .number($0.answered) },
                cell: { row in
                    AnyView(NumberCell(
                        text: row.reviewer?.responseRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-",
                        dimmed: row.reviewer?.responseRate == nil
                    )
                    .help(row.reviewer.map { "Reviewed \($0.answered) of \($0.requested) requests before the PR merged" } ?? "Not asked to review"))
                }
            ),
            StatsColumn(
                id: "response", title: "Response", help: "Median time from being asked to their review",
                width: 140, group: "Reviewing",
                sortKey: { .number($0.response) },
                cell: { row in
                    AnyView(BarCell(value: row.reviewer?.responseTime.median, scale: responseScale)
                        .help(Self.durationHelp("Median time from being asked to their review", row.reviewer?.responseTime)))
                }
            ),
            StatsColumn(
                id: "waiting", title: "Waiting", help: "Open PRs waiting on their review now, and the oldest wait",
                width: 130, group: "Reviewing",
                sortKey: { .number($0.waiting) },
                cell: { row in AnyView(WaitingCell(reviewer: row.reviewer)) }
            ),
        ]
    }

    /// "Median X over N PRs, p75 Y", or a note when there's nothing to measure.
    static func durationHelp(_ what: String, _ stat: DurationStat?) -> String {
        guard let stat, let median = stat.median else { return "\(what): nothing to measure yet" }
        var text = "\(what): \(median.compactDuration) over \(stat.count) PR\(stat.count == 1 ? "" : "s")"
        if let p75 = stat.p75 { text += ", p75 \(p75.compactDuration)" }
        return text
    }
}

// MARK: - Repositories

struct RepoStatsTable: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let metrics: OrgMetrics
    @Binding var selection: DetailSelection?

    @State private var sort: StatsSort?

    var body: some View {
        let cycleScale = BarScale(metrics.repos.compactMap(\.cycleTime.median))
        StatsTable(
            rows: metrics.repos,
            columns: [
                StatsColumn(
                    id: "repo", title: "Repository", help: "Repositories with PRs merged in the window",
                    width: nil, minWidth: 200,
                    sortKey: { .text($0.name.lowercased()) },
                    cell: { repo in AnyView(Text(repo.name).lineLimit(1).help(repo.repo)) }
                ),
                StatsColumn(
                    id: "merged", title: "Merged", help: "PRs merged in the window",
                    width: 90,
                    sortKey: { .number(Double($0.merged)) },
                    cell: { repo in
                        AnyView(NumberCell(text: "\(repo.merged)", dimmed: false)
                            .help("\(repo.merged) PRs merged in the last \(metrics.window.lengthInDays()) days"))
                    }
                ),
                StatsColumn(
                    id: "cycle", title: "Cycle", help: "Median first commit to merge",
                    width: 220,
                    sortKey: { .number($0.cycle) },
                    cell: { repo in
                        AnyView(BarCell(value: repo.cycleTime.median, scale: cycleScale)
                            .help(PeopleStatsTable.durationHelp("Median cycle time (first commit to merge)", repo.cycleTime)))
                    }
                ),
            ],
            sort: $sort,
            selectedID: selectedRepo,
            onSelect: { selection = .metric(.repo($0.repo)) },
            contextMenu: { repo in
                AnyView(Button("Exclude \(repo.repo) from Stats") {
                    configs.toggleRepo(repo.repo, in: org)
                })
            },
            destination: { .metric(.repo($0.repo)) }
        )
    }

    private var selectedRepo: String? {
        if case .metric(.repo(let repo)) = selection { return repo }
        return nil
    }
}

// MARK: - Cells

/// Maps durations onto bar lengths. The 90th percentile is full width so one
/// outlier doesn't flatten everyone else.
struct BarScale {
    let full: TimeInterval

    init(_ values: [TimeInterval]) {
        let sorted = values.sorted()
        let index = Int((Double(max(sorted.count - 1, 0)) * 0.9).rounded())
        full = max(sorted.isEmpty ? 1 : sorted[index], 1)
    }

    func fraction(_ value: TimeInterval) -> Double {
        min(max(value / full, 0), 1)
    }
}

/// A duration with its bar to the right, scaled against the rest of the
/// column.
struct BarCell: View {
    let value: TimeInterval?
    let scale: BarScale

    var body: some View {
        if let value {
            HStack(spacing: 8) {
                Text(value.compactDuration)
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.6))
                        Capsule()
                            .fill(ChartPalette.blue)
                            .frame(width: max(4, geometry.size.width * scale.fraction(value)))
                    }
                }
                .frame(height: 6)
            }
        } else {
            Text("-")
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NumberCell: View {
    let text: String
    let dimmed: Bool

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(dimmed ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WaitingCell: View {
    let reviewer: ReviewerMetrics?

    var body: some View {
        let pending = reviewer?.pending ?? 0
        HStack(spacing: 4) {
            Text("\(pending)")
                .foregroundStyle(pending == 0 ? .tertiary : .primary)
            if let since = reviewer?.oldestPendingSince {
                Text("· oldest \(Date.now.timeIntervalSince(since).compactDuration)")
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    private var help: String {
        guard let reviewer, reviewer.pending > 0, let since = reviewer.oldestPendingSince else {
            return "No open PRs waiting on their review"
        }
        return "\(reviewer.pending) open PR\(reviewer.pending == 1 ? "" : "s") waiting on their review. The oldest asked them \(since.formatted(.relative(presentation: .named)))."
    }
}

// MARK: - Column guide

/// An info button that explains a table's columns.
struct ColumnGuideButton: View {
    struct Group {
        let title: String?
        let entries: [(column: String, meaning: String)]
    }

    let groups: [Group]
    var footnote: String?
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .font(.body)
        .help("What the columns mean")
        .popover(isPresented: $isShowing, arrowEdge: Self.arrowEdge) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 3) {
                        if let title = group.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                            ForEach(group.entries, id: \.column) { entry in
                                GridRow {
                                    Text(entry.column).fontWeight(.medium)
                                    Text(entry.meaning).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(width: 400, alignment: .leading)
            .presentationBackground(Color.windowBackground)
        }
    }

    /// Below the button.
    private static var arrowEdge: Edge {
        .bottom
    }

    static let people = ColumnGuideButton(
        groups: [
            Group(title: "Authoring", entries: [
                ("Merged", "PRs they merged in the window"),
                ("Cycle", "Median first commit → merge"),
                ("TTFR", "Median wait for a first review"),
                ("Reviewed", "Others' merged PRs they reviewed"),
            ]),
            Group(title: "Reviewing", entries: [
                ("Asked", "Review requests, withdrawn ones excluded"),
                ("Answered", "Share reviewed before merge"),
                ("Response", "Median time from request to review"),
                ("Waiting", "Open PRs waiting on them · oldest wait"),
            ]),
        ],
        footnote: "Bars compare against the team (90th percentile = full). ⚠︎ answers under half, or over a day at the median."
    )

    static let repos = ColumnGuideButton(
        groups: [
            Group(title: nil, entries: [
                ("Merged", "PRs merged in the window"),
                ("Cycle", "Median first commit → merge"),
            ]),
        ],
        footnote: "Bars compare repos (90th percentile = full)."
    )
}
