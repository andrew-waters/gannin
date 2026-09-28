import Charts
import SwiftUI

/// The Actions page: how the org's GitHub Actions workflows are doing over
/// the metrics window. Headline numbers, what needs a look, weekly trends,
/// then every workflow and every trigger. A workflow opens over it, and its
/// runs and jobs over that (`DetailSelection.workflow` and on).
struct ActionsView: View {
    @Environment(ActionsStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @State private var sort: StatsSort?
    @State private var eventSort: StatsSort?
    @State private var repoSort: StatsSort?
    @AppStorage("actionsGranularity") private var granularity: IssueMetrics.Granularity = .week

    let org: String
    @Binding var selection: DetailSelection?

    var body: some View {
        dashboard
            .task(id: "\(org) \(windowDays)") { await sync(force: false) }
    }

    private func navigate(_ route: DetailSelection) {
        selection = route
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let history = store.history(for: org) {
                    let metrics = ActionsMetrics(history: history, windowDays: windowDays, config: configs.config(for: org))
                    content(metrics)
                } else {
                    Section {
                        Group {
                            if let error = store.errors[org] {
                                Banner(message: "Couldn't load workflow runs: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                                    Task { await sync(force: true) }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Fetching workflow runs for the last \(windowDays) days, repo by repo.").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .sectionContent()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem { syncIndicator }
            ToolbarItem { ColumnGuideButton.actions }
        }
    }

    private func sync(force: Bool) async {
        await store.sync(org, windowDays: windowDays, excluding: configs.config(for: org).excludedRepos, force: force)
    }

    @ViewBuilder
    private var syncIndicator: some View {
        if store.syncing.contains(org) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func content(_ metrics: ActionsMetrics) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                if let error = store.errors[org] {
                    Banner(message: "Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await sync(force: true) }
                    }
                }
                if metrics.workflows.isEmpty {
                    Text("No workflow runs in the last \(windowDays) days.").foregroundStyle(.secondary)
                } else {
                    tiles(metrics)
                }
            }
            .updating(store.syncing.contains(org))
            .sectionContent()
        }
        if !metrics.workflows.isEmpty {
            Section {
                AttentionList(items: metrics.attention) { navigate(.workflow($0)) }
                    .sectionContent()
            } header: {
                PinnedHeader { SectionHeader(title: "Needs attention", count: metrics.attention.count) }
            }
            Section {
                let buckets = metrics.buckets(granularity)
                VStack(alignment: .leading, spacing: 24) {
                    StackedRunTimeChart(title: "Run time by repository", data: metrics.runTimeByRepo(granularity), granularity: granularity)
                    RunsChart(buckets: buckets, granularity: granularity)
                    DurationChart(buckets: buckets, granularity: granularity)
                }
                .sectionContent()
            } header: {
                PinnedHeader {
                    HStack(spacing: 12) {
                        Text("Trends")
                        Spacer(minLength: 8)
                        Picker("Per", selection: $granularity) {
                            ForEach([IssueMetrics.Granularity.day, .week]) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .font(.body)
                    }
                }
            }
            Section {
                RepositoriesTable(org: org, metrics: metrics, sort: $repoSort) { navigate(.actionsRepository($0)) }
                    .sectionContent()
            } header: {
                PinnedHeader { SectionHeader(title: "Repositories", count: metrics.repos.count) }
            }
            Section {
                WorkflowsTable(org: org, workflows: metrics.workflows, hasPrevious: metrics.hasPrevious, sort: $sort) { navigate(.workflow($0)) }
                    .sectionContent()
            } header: {
                PinnedHeader { SectionHeader(title: "Workflows by repository", count: metrics.workflows.count) }
            }
            Section {
                EventsTable(events: metrics.events, sort: $eventSort)
                    .sectionContent()
            } header: {
                PinnedHeader { Text("By trigger") }
            }
        }
    }

    /// Run time, runs, failure rate and the typical run first, each against
    /// the period before, then the default branches and re-runs.
    private func tiles(_ metrics: ActionsMetrics) -> some View {
        let perDay = Double(metrics.runCount) / Double(max(metrics.windowDays, 1))
        let previous = metrics.hasPrevious ? metrics.previous : nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            StatTile(
                title: "Run time",
                value: metrics.runTime.compactDuration,
                detail: "Wall clock, summed",
                change: previous.flatMap { StatChange.percent(metrics.runTime, $0.runTime, higherIsWorse: true) }
            )
            StatTile(
                title: "Runs",
                value: "\(metrics.runCount)",
                detail: "\(perDay.formatted(.number.precision(.fractionLength(perDay < 10 ? 1 : 0)))) a day · \(metrics.repoCount) repos",
                change: previous.flatMap { StatChange.percent(Double(metrics.runCount), Double($0.runs), higherIsWorse: nil) }
            )
            StatTile(
                title: "Failure rate",
                value: Self.percent(metrics.counts.failureRate),
                detail: "All runs, PRs included",
                change: previous.flatMap { StatChange.points(metrics.counts.failureRate, $0.counts.failureRate, higherIsWorse: true) }
            )
            StatTile(
                title: "Typical run (p90)",
                value: metrics.duration.p90?.compactDuration ?? "-",
                detail: metrics.duration.median.map { "Median \($0.compactDuration)" },
                change: previous.flatMap { before in metrics.duration.p90.flatMap { now in before.duration.p90.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } }
            )
            StatTile(
                title: "Default branch",
                value: Self.percent(metrics.defaultBranchCounts.successRate),
                detail: "Succeeded, outside PRs"
            )
            StatTile(
                title: "Red now",
                value: "\(metrics.red.count)",
                detail: metrics.red.isEmpty ? "Every default branch green" : "Failing on a default branch"
            )
            StatTile(
                title: "Re-run",
                value: Self.percent(metrics.runCount == 0 ? nil : Double(metrics.retried) / Double(metrics.runCount)),
                detail: "\(metrics.passedOnRetry) passed only on a re-run"
            )
        }
    }

    static func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-"
    }
}

// MARK: - Needs attention

private struct AttentionList: View {
    let items: [ActionsAttention]
    let open: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Label("Nothing stands out: default branches are green, and no workflow looks flaky or is getting slower.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: ActionsAttention) -> some View {
        Button {
            open(item.workflow.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(item.kind))
                    .foregroundStyle(tint(item.kind))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.workflow.name).fontWeight(.medium)
                        Text(item.workflow.shortRepo).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Text("\(label(item.kind)): \(item.message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                OutcomeStrip(runs: Array(item.workflow.runs.prefix(20)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensElsewhere(.workflow(item.workflow.id))
    }

    private func icon(_ kind: ActionsAttention.Kind) -> String {
        switch kind {
        case .red: "xmark.octagon.fill"
        case .failing: "exclamationmark.triangle.fill"
        case .flaky: "arrow.triangle.2.circlepath"
        case .slower: "tortoise.fill"
        }
    }

    private func tint(_ kind: ActionsAttention.Kind) -> Color {
        switch kind {
        case .red: ChartPalette.critical
        case .failing, .flaky: ChartPalette.warning
        case .slower: .secondary
        }
    }

    private func label(_ kind: ActionsAttention.Kind) -> String {
        switch kind {
        case .red: "Red"
        case .failing: "Often failing"
        case .flaky: "Flaky"
        case .slower: "Slower"
        }
    }
}

// MARK: - Outcome strip

/// The latest runs as a row of ticks, oldest on the left: tall and red for a
/// failure, short and green for a success, so it reads without colour too.
struct OutcomeStrip: View {
    let runs: [WorkflowRun]
    var tick: CGFloat = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(runs.reversed()) { run in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.color(run.outcome))
                    .frame(width: tick, height: Self.height(run.outcome))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .help(summary)
    }

    static func color(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .success: ChartPalette.good
        case .failure: ChartPalette.critical
        case .cancelled, .skipped: ChartPalette.neutral
        case .running: ChartPalette.blue
        }
    }

    private static func height(_ outcome: RunOutcome) -> CGFloat {
        switch outcome {
        case .failure: 16
        case .success: 9
        case .running: 12
        case .cancelled, .skipped: 5
        }
    }

    private var summary: String {
        let counts = OutcomeCounts(runs)
        return "Last \(runs.count) runs, oldest first: \(counts.succeeded) succeeded, \(counts.failed) failed, \(counts.cancelled) cancelled"
            + (counts.skipped > 0 ? ", \(counts.skipped) skipped" : "")
    }
}

// MARK: - Charts

extension IssueMetrics.Granularity {
    /// The chart unit for a day or week bucket.
    var chartUnit: Calendar.Component { self == .day ? .day : .weekOfYear }

    /// "Week of 7 Sep" or "7 Sep 2026", for tooltips.
    func label(_ start: Date) -> String {
        self == .week ? "Week of \(start.formatted(.dateTime.day().month()))" : start.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Maps the pointer to the bucket under it.
private struct BucketHover: View {
    let proxy: ChartProxy
    let starts: [Date]
    @Binding var hovered: Date?

    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geometry[plotFrame].origin.x) else { return }
                        hovered = starts.last { $0 <= date }
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }
}

/// Runs per day or week, stacked by how they ended.
private struct RunsChart: View {
    let buckets: [ActionsBucket]
    let granularity: IssueMetrics.Granularity
    @State private var hovered: Date?

    private static let series: [(RunOutcome, Color)] = [
        (.success, ChartPalette.good),
        (.failure, ChartPalette.critical),
        (.cancelled, ChartPalette.neutral),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(granularity == .day ? "Runs per day" : "Runs per week").font(.headline)
            Chart {
                ForEach(buckets) { bucket in
                    ForEach(Self.series, id: \.0) { outcome, _ in
                        BarMark(
                            x: .value("Period", bucket.start, unit: granularity.chartUnit),
                            y: .value("Runs", count(bucket, outcome))
                        )
                        .foregroundStyle(by: .value("Outcome", outcome.rawValue))
                        .opacity(hovered == nil || hovered == bucket.start ? 1 : 0.4)
                    }
                }
            }
            .chartForegroundStyleScale(domain: Self.series.map(\.0.rawValue), range: Self.series.map(\.1))
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in BucketHover(proxy: proxy, starts: buckets.map(\.start), hovered: $hovered) }
            .frame(height: 160)
            if let hovered, let bucket = buckets.first(where: { $0.start == hovered }) {
                Text("\(granularity.label(bucket.start)): \(bucket.counts.succeeded) succeeded, \(bucket.counts.failed) failed, \(bucket.counts.cancelled) cancelled · failure rate \(ActionsView.percent(bucket.counts.failureRate))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover for values.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func count(_ bucket: ActionsBucket, _ outcome: RunOutcome) -> Int {
        switch outcome {
        case .success: bucket.counts.succeeded
        case .failure: bucket.counts.failed
        default: bucket.counts.cancelled
        }
    }
}

/// Median and p90 run duration per day or week, on one duration axis.
private struct DurationChart: View {
    let buckets: [ActionsBucket]
    let granularity: IssueMetrics.Granularity
    @State private var hovered: Date?

    var body: some View {
        let points = buckets.flatMap { bucket in
            [("Median", bucket.duration.median), ("p90", bucket.duration.p90)].compactMap { series, value in
                value.map { (start: bucket.start, series: series, minutes: $0 / 60) }
            }
        }
        let top = max(points.map(\.minutes).max() ?? 1, 1) * 1.15
        let unit = granularity.chartUnit
        VStack(alignment: .leading, spacing: 8) {
            Text(granularity == .day ? "Run duration per day" : "Run duration per week").font(.headline)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Period", point.start, unit: unit), y: .value("Minutes", point.minutes), series: .value("Series", point.series))
                        .foregroundStyle(by: .value("Series", point.series))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    // Points only where they stay legible: every week, or the hovered day.
                    if granularity == .week || hovered == point.start {
                        PointMark(x: .value("Period", point.start, unit: unit), y: .value("Minutes", point.minutes))
                            .foregroundStyle(by: .value("Series", point.series))
                            .symbolSize(hovered == point.start ? 90 : 50)
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Period", hovered, unit: unit))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(["Median": ChartPalette.blue, "p90": ChartPalette.orange])
            .chartLegend(position: .top, alignment: .leading)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in BucketHover(proxy: proxy, starts: buckets.map(\.start), hovered: $hovered) }
            .frame(height: 140)
            if let hovered, let bucket = buckets.first(where: { $0.start == hovered }) {
                Text("\(granularity.label(bucket.start)): median \(bucket.duration.median?.compactDuration ?? "-"), p90 \(bucket.duration.p90?.compactDuration ?? "-") over \(bucket.duration.count) runs")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.callout)
            }
        }
    }
}

// MARK: - Tables

/// Workflows under a header per repo (or, on a repo's page, just the
/// table), a row each.
struct WorkflowsTable: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openURL) private var openURL
    let org: String
    let workflows: [WorkflowStats]
    /// Whether the period before is stored, for the changes on it.
    let hasPrevious: Bool
    /// Under a header per repo; off on a repo's own page.
    var grouped = true
    @Binding var sort: StatsSort?
    let open: (String) -> Void
    /// Repos folded shut, by `owner/name`.
    @State private var collapsed: Set<String> = []
    @Environment(\.navigate) private var navigate

    /// Workflows by repo, busiest repo first.
    private var groups: [(repo: String, workflows: [WorkflowStats])] {
        Dictionary(grouping: workflows, by: \.repo)
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                let runsA = a.workflows.reduce(0) { $0 + $1.runs.count }
                let runsB = b.workflows.reduce(0) { $0 + $1.runs.count }
                return (runsA, b.repo) > (runsB, a.repo)
            }
    }

    var body: some View {
        // One scale for every repo, so bars compare across them.
        let columns = columns(durationScale: BarScale(workflows.compactMap(\.duration.median)))
        if !grouped {
            StatsTable(rows: workflows, columns: columns, sort: $sort, selectedID: nil, onSelect: { open($0.id) }, contextMenu: menu, destination: { .workflow($0.id) })
        } else {
            groupedTables(columns)
        }
    }

    private func groupedTables(_ columns: [StatsColumn<WorkflowStats>]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.repo) { group in
                header(group.repo, workflows: group.workflows)
                if !collapsed.contains(group.repo) {
                    StatsTable(rows: group.workflows, columns: columns, sort: $sort, selectedID: nil, onSelect: { open($0.id) }, contextMenu: menu, destination: { .workflow($0.id) })
                        .padding(.bottom, 10)
                }
            }
        }
    }

    /// The repo's name with its runs and anything red, folding its table.
    private func header(_ repo: String, workflows: [WorkflowStats]) -> some View {
        let runs = workflows.reduce(0) { $0 + $1.runs.count }
        let red = workflows.filter { $0.defaultBranch?.isRed == true }.count
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if collapsed.remove(repo) == nil { collapsed.insert(repo) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(collapsed.contains(repo) ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                    .font(.headline)
                Text("\(workflows.count) \(workflows.count == 1 ? "workflow" : "workflows") · \(runs) runs")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if red > 0 {
                    Label("\(red) red", systemImage: "xmark.circle.fill")
                        .foregroundStyle(ChartPalette.critical)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                if let navigate {
                    Button("Repository page") { navigate(.actionsRepository(repo)) }
                        .linkButton()
                }
            }
            .font(.callout)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repo)
        .contextMenu {
            OpenElsewhereItems(.actionsRepository(repo))
            if let url = URL(string: "https://github.com/\(repo)/actions") {
                Button("Open on GitHub") { openURL(url) }
            }
            Button("Exclude \(repo) from Stats") { configs.toggleRepo(repo, in: org) }
        }
    }

    private func menu(_ workflow: WorkflowStats) -> AnyView {
        AnyView(Group {
            if let url = workflow.url {
                Button("Open on GitHub") { openURL(url) }
            }
            Button("Exclude \(workflow.repo) from Stats") {
                configs.toggleRepo(workflow.repo, in: org)
            }
        })
    }

    private func columns(durationScale: BarScale) -> [StatsColumn<WorkflowStats>] {
        [
            StatsColumn(
                id: "workflow", title: "Workflow", help: "Workflows with runs in the window",
                width: nil, minWidth: 220,
                sortKey: { .text($0.name.lowercased()) },
                cell: { workflow in
                    AnyView(Text(workflow.name).lineLimit(1).help(workflow.path))
                }
            ),
            StatsColumn(
                id: "branch", title: "Main", help: "The latest run on the default branch, outside PRs",
                width: 60,
                sortKey: { .number($0.defaultBranch.map { $0.isRed ? 2 : 1 } ?? 0) },
                cell: { AnyView(BranchCell(health: $0.defaultBranch)) }
            ),
            StatsColumn(
                id: "runs", title: "Runs", help: "Runs created in the window",
                width: 60,
                sortKey: { .number(Double($0.runs.count)) },
                cell: { AnyView(NumberCell(text: "\($0.runs.count)", dimmed: false)) }
            ),
            StatsColumn(
                id: "failed", title: "Failed", help: "Share of runs that failed, of those that passed or failed",
                width: 64,
                sortKey: { .number($0.counts.failureRate ?? -1) },
                cell: { workflow in
                    AnyView(NumberCell(text: ActionsView.percent(workflow.counts.failureRate), dimmed: (workflow.counts.failureRate ?? 0) == 0)
                        .help("\(workflow.counts.failed) failed, \(workflow.counts.succeeded) succeeded, \(workflow.counts.cancelled) cancelled"))
                }
            ),
            StatsColumn(
                id: "median", title: "Median", help: "Median run duration",
                width: 170,
                sortKey: { .number($0.duration.median ?? -1) },
                cell: { AnyView(BarCell(value: $0.duration.median, scale: durationScale)) }
            ),
            StatsColumn(
                id: "p90", title: "p90", help: "90th percentile run duration: the slow runs people wait on",
                width: 60,
                sortKey: { .number($0.duration.p90 ?? -1) },
                cell: { AnyView(NumberCell(text: $0.duration.p90?.compactDuration ?? "-", dimmed: $0.duration.p90 == nil)) }
            ),
            StatsColumn(
                id: "time", title: "Run time", help: "Wall-clock time summed over runs, and its change on the period before",
                width: 110,
                sortKey: { .number($0.runTime) },
                cell: { workflow in
                    AnyView(HStack(spacing: 6) {
                        Text(workflow.runTime.compactDuration).monospacedDigit()
                        if hasPrevious { ChangeLabel(change: StatChange.percent(workflow.runTime, workflow.previous.runTime, higherIsWorse: true)).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading))
                }
            ),
            StatsColumn(
                id: "distribution", title: "Distribution", help: "Runs by how long they took: up to 60s, 5, 10, 20, 60 minutes, and longer",
                width: 96,
                sortKey: { .number($0.duration.median ?? -1) },
                cell: { AnyView(HistogramCell(histogram: $0.histogram)) }
            ),
            StatsColumn(
                id: "p90trend", title: "p90 trend", help: "90th percentile run duration, week by week",
                width: 110,
                sortKey: { .number($0.duration.p90 ?? -1) },
                cell: { workflow in
                    AnyView(SparkLine(values: workflow.weeks.map(\.duration.p90), help: workflow.weeks.map { "\($0.start.formatted(.dateTime.day().month())): \($0.duration.p90?.compactDuration ?? "-")" }.joined(separator: "\n")))
                }
            ),
            StatsColumn(
                id: "flaky", title: "Flaky", help: "Runs that passed only on a re-run, plus commits that both failed and passed",
                width: 56,
                sortKey: { .number(Double($0.flakySignals)) },
                cell: { workflow in
                    AnyView(NumberCell(text: "\(workflow.flakySignals)", dimmed: workflow.flakySignals == 0)
                        .help("\(workflow.passedOnRetry) passed on a re-run, \(workflow.mixedCommits) commits both failed and passed"))
                }
            ),
            StatsColumn(
                id: "recent", title: "Recent", help: "The latest 20 runs, oldest first: tall red ticks failed, short green ones passed",
                width: 130,
                sortKey: { .number(Double(OutcomeCounts($0.runs.prefix(20)).failed)) },
                cell: { AnyView(OutcomeStrip(runs: Array($0.runs.prefix(20)))) }
            ),
        ]
    }
}

/// A dot and a word for the default branch: red, green, or no runs there.
private struct BranchCell: View {
    let health: BranchHealth?

    var body: some View {
        if let health {
            HStack(spacing: 4) {
                Image(systemName: health.isRed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(health.isRed ? ChartPalette.critical : ChartPalette.good)
                Text(health.isRed ? "Red" : "OK").foregroundStyle(.secondary)
            }
            .help(help(health))
        } else {
            Text("-").foregroundStyle(.tertiary).help("No runs on the default branch outside PRs")
        }
    }

    private func help(_ health: BranchHealth) -> String {
        var text = health.isRed
            ? "Failing on the default branch" + (health.redSince.map { " since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            : "Passing on the default branch"
        if let green = health.timeToGreen {
            text += ". Back to green in a median \(green.compactDuration) over \(health.recoveries.count) breakages in the window."
        }
        return text
    }
}

private struct EventsTable: View {
    let events: [EventStats]
    @Binding var sort: StatsSort?

    var body: some View {
        let durationScale = BarScale(events.compactMap(\.duration.median))
        StatsTable(
            rows: events,
            columns: [
                StatsColumn(
                    id: "event", title: "Trigger", help: "What started the runs",
                    width: nil, minWidth: 180,
                    sortKey: { .text($0.title.lowercased()) },
                    cell: { event in AnyView(Text(event.title).lineLimit(1).help(event.event)) }
                ),
                StatsColumn(
                    id: "runs", title: "Runs", help: "Runs in the window",
                    width: 60,
                    sortKey: { .number(Double($0.counts.ran + $0.counts.skipped)) },
                    cell: { AnyView(NumberCell(text: "\($0.counts.ran + $0.counts.skipped)", dimmed: false)) }
                ),
                StatsColumn(
                    id: "failed", title: "Failed", help: "Share that failed, of those that passed or failed",
                    width: 64,
                    sortKey: { .number($0.counts.failureRate ?? -1) },
                    cell: { AnyView(NumberCell(text: ActionsView.percent($0.counts.failureRate), dimmed: ($0.counts.failureRate ?? 0) == 0)) }
                ),
                StatsColumn(
                    id: "median", title: "Median", help: "Median run duration",
                    width: 170,
                    sortKey: { .number($0.duration.median ?? -1) },
                    cell: { AnyView(BarCell(value: $0.duration.median, scale: durationScale)) }
                ),
                StatsColumn(
                    id: "time", title: "Run time", help: "Wall-clock time summed over runs",
                    width: 76,
                    sortKey: { .number($0.runTime) },
                    cell: { AnyView(NumberCell(text: $0.runTime.compactDuration, dimmed: false)) }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { _ in }
        )
    }
}

extension ColumnGuideButton {
    static let actions = ColumnGuideButton(
        groups: [
            Group(title: "Repositories", entries: [
                ("Run time", "Wall clock summed over runs"),
                ("Share", "Of the org's run time"),
                ("Run time trend", "Week by week"),
                ("Distribution", "Runs up to 60s, 5, 10, 20, 60 minutes, longer"),
            ]),
            Group(title: "Workflows", entries: [
                ("Main", "Latest default-branch run outside PRs"),
                ("Failed", "Failed of those that passed or failed"),
                ("Median · p90", "Run duration, start to finish"),
                ("p90 trend", "The slow tail, week by week"),
                ("Flaky", "Passed on re-run, or a commit that did both"),
                ("Recent", "Latest 20 runs, tall red ticks failed"),
            ]),
        ],
        footnote: "Changes compare with the period before, as long as the window. Failures on PRs are CI catching problems; failures on the default branch mean it's broken, so Needs attention flags those. Cancelled and skipped runs don't count towards failure rates. Only a run's latest attempt is listed."
    )
}

/// Every repo with runs in the window, by run time: its share, runs,
/// week-by-week run time, how long runs take and how often they fail, each
/// against the period before.
private struct RepositoriesTable: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openURL) private var openURL
    let org: String
    let metrics: ActionsMetrics
    @Binding var sort: StatsSort?
    let open: (String) -> Void

    var body: some View {
        let hasPrevious = metrics.hasPrevious
        StatsTable(
            rows: metrics.repos,
            columns: [
                StatsColumn(
                    id: "repo", title: "Repository", help: "Repositories with runs in the window",
                    width: nil, minWidth: 180,
                    sortKey: { .text($0.shortName.lowercased()) },
                    cell: { repo in
                        AnyView(HStack(spacing: 6) {
                            Text(repo.shortName).lineLimit(1)
                            if repo.red > 0 {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(ChartPalette.critical)
                                    .help("\(repo.red) \(repo.red == 1 ? "workflow" : "workflows") failing on the default branch")
                            }
                        }
                        .help(repo.repo))
                    }
                ),
                StatsColumn(
                    id: "time", title: "Run time", help: "Wall-clock time summed over runs, and its change on the period before",
                    width: 110,
                    sortKey: { .number($0.current.runTime) },
                    cell: { repo in
                        AnyView(HStack(spacing: 6) {
                            Text(repo.current.runTime.compactDuration).monospacedDigit()
                            if hasPrevious { ChangeLabel(change: StatChange.percent(repo.current.runTime, repo.previous.runTime, higherIsWorse: true)).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading))
                    }
                ),
                StatsColumn(
                    id: "share", title: "Share", help: "Share of the org's run time",
                    width: 56,
                    sortKey: { .number($0.share) },
                    cell: { AnyView(NumberCell(text: $0.share < 0.005 ? "~0%" : ActionsView.percent($0.share), dimmed: false)) }
                ),
                StatsColumn(
                    id: "runs", title: "Runs", help: "Runs created in the window, and the change on the period before",
                    width: 96,
                    sortKey: { .number(Double($0.current.runs)) },
                    cell: { repo in
                        AnyView(HStack(spacing: 6) {
                            Text("\(repo.current.runs)").monospacedDigit()
                            if hasPrevious { ChangeLabel(change: StatChange.percent(Double(repo.current.runs), Double(repo.previous.runs), higherIsWorse: nil)).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading))
                    }
                ),
                StatsColumn(
                    id: "trend", title: "Run time trend", help: "Run time week by week",
                    width: 110,
                    sortKey: { .number($0.current.runTime) },
                    cell: { repo in
                        AnyView(SparkBars(values: repo.weeks.map(\.runTime), help: repo.weeks.map { "\($0.start.formatted(.dateTime.day().month())): \($0.runTime.compactDuration)" }.joined(separator: "\n")))
                    }
                ),
                StatsColumn(
                    id: "distribution", title: "Distribution", help: "Runs by how long they took: up to 60s, 5, 10, 20, 60 minutes, and longer",
                    width: 96,
                    sortKey: { .number($0.current.duration.median ?? -1) },
                    cell: { AnyView(HistogramCell(histogram: $0.histogram)) }
                ),
                StatsColumn(
                    id: "p90", title: "p90", help: "90th percentile run duration",
                    width: 60,
                    sortKey: { .number($0.current.duration.p90 ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.current.duration.p90?.compactDuration ?? "-", dimmed: $0.current.duration.p90 == nil)) }
                ),
                StatsColumn(
                    id: "failed", title: "Failed", help: "Share of runs that failed, of those that passed or failed, and the change in points",
                    width: 96,
                    sortKey: { .number($0.current.counts.failureRate ?? -1) },
                    cell: { repo in
                        AnyView(HStack(spacing: 6) {
                            Text(ActionsView.percent(repo.current.counts.failureRate)).monospacedDigit()
                            if hasPrevious { ChangeLabel(change: StatChange.points(repo.current.counts.failureRate, repo.previous.counts.failureRate, higherIsWorse: true)).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading))
                    }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { open($0.repo) },
            contextMenu: { repo in
                AnyView(Group {
                    if let url = URL(string: "https://github.com/\(repo.repo)/actions") {
                        Button("Open on GitHub") { openURL(url) }
                    }
                    Button("Exclude \(repo.repo) from Stats") { configs.toggleRepo(repo.repo, in: org) }
                })
            },
            destination: { .actionsRepository($0.repo) }
        )
    }
}
