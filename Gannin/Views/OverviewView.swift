import Charts
import SwiftUI

/// Two pages. Overview, the org landing page: the state of work right now,
/// and summaries of delivery, investment balance and CI for the window,
/// each linking to its page. PR flow (Delivery): the window's delivery
/// metrics in full, against the period before and the goals. Every number
/// opens the items behind it. The breakdowns by person and repo are on Team
/// and Repositories.
struct OverviewView: View {
    enum Part { case overview, delivery }

    @Environment(MetricsStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(IssueStore.self) private var issueStore
    @Environment(HiddenStore.self) private var hidden
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @State private var showsDigest = false

    let org: String
    let workload: Workload
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?
    var part: Part = .overview

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if part == .overview {
                    Section {
                        rightNow.sectionContent()
                    } header: {
                        PinnedHeader { Text("Right now") }
                    }
                    let goals = configs.config(for: org).measurables
                    if !goals.isEmpty {
                        Section {
                            ScorecardStanding(headlines: scorecard(goals)).sectionContent()
                        } header: {
                            PinnedHeader { SummaryHeader(title: "Scorecards", link: "Scorecards", item: .tab(.scorecard)) }
                        }
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            notices
                            if let metrics {
                                deliverySummary(metrics)
                                PRSizeSummary(metrics: metrics, selection: $selection)
                            } else if store.syncing.contains(org) {
                                loading
                            }
                        }
                        .sectionContent()
                    } header: {
                        PinnedHeader { SummaryHeader(title: "Delivery · \(MetricsWindow(code: windowDays).phrase)", link: "PR flow", item: .tab(.delivery)) }
                    }
                } else {
                Section {
                    VStack(alignment: .leading, spacing: 28) {
                        notices
                        if let metrics {
                            Group {
                                delivery(metrics)
                                let goals = configs.config(for: org).goals?.targets(for: workload.team).results(for: metrics) ?? []
                                if !goals.isEmpty {
                                    GoalsSection(results: goals, selection: $selection)
                                }
                                if let previous = metrics.previous {
                                    WhatChangedSection(
                                        explanation: DeliveryExplanation(current: metrics.current, previous: previous, members: Dictionary(workload.people.map { ($0.person.login, $0.person) }, uniquingKeysWith: { a, _ in a })),
                                        previousPhrase: metrics.window.previousPhrase
                                    )
                                }
                                stageBreakdown(metrics)
                                SizeRiskSection(metrics: metrics, selection: $selection)
                                charts(metrics)
                            }
                            .updating(store.syncing.contains(org))
                        } else if store.syncing.contains(org) {
                            loading
                        } else if store.errors[org] == nil {
                            Text("No metrics yet.").foregroundStyle(.secondary)
                        }
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader {
                        HStack(spacing: 12) {
                            Text("Delivery · \(MetricsWindow(code: windowDays).phrase)")
                            MetricsSyncIndicator(org: org)
                            Spacer()
                            if let metrics, metrics.previous == nil {
                                Text("No history for \(metrics.window.previousPhrase) yet")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Changes against \(MetricsWindow(code: windowDays).previousPhrase)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Weekly Digest") { showsDigest = true }
                                .help("The week in a page: delivery, what shipped, CI and who's off next, to copy or commit to the harness")
                        }
                    }
                }
                }
                if part == .overview {
                Section {
                    InvestmentsSummary(org: org, windowDays: windowDays, selection: $selection)
                        .sectionContent()
                } header: {
                    PinnedHeader { SummaryHeader(title: "Investments · \(MetricsWindow(code: windowDays).phrase)", link: "Investments", item: .tab(.investments)) }
                }
                Section {
                    ActionsSummary(org: org, windowDays: windowDays, selection: $selection)
                        .sectionContent()
                } header: {
                    PinnedHeader { SummaryHeader(title: "CI · \(MetricsWindow(code: windowDays).phrase)", link: "CI", item: .tab(.actions)) }
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .syncOffNotice(.metrics)
        .sheet(isPresented: $showsDigest) {
            DigestSheet(org: org, team: workload.team)
        }
    }

    // MARK: Delivery, in short

    /// Each scorecard goal's last whole period at its own cadence.
    private func scorecard(_ goals: [Measurable]) -> [ScorecardHeadline] {
        ScorecardHeadline.latest(
            goals, history: store.history(for: org), config: configs.config(for: org), hidden: hidden.keys,
            teams: orgs.snapshot(for: org)?.teams ?? [],
            sources: Scorecard.Sources(
                openPullRequests: orgs.snapshot(for: org)?.openPullRequests ?? [],
                runs: actionsStore.history(for: org).map { Array($0.runs.values) },
                issues: issueStore.history(for: org)
            )
        )
    }

    /// The headline numbers with their changes, and how the goals stand;
    /// the rest is on PR flow.
    private func deliverySummary(_ metrics: OrgMetrics) -> some View {
        let previous = metrics.previous
        let goals = configs.config(for: org).goals?.targets(for: workload.team).results(for: metrics) ?? []
        return VStack(alignment: .leading, spacing: 12) {
            TileGrid {
                StatTile(
                    title: "PRs merged", value: "\(metrics.merged.count)",
                    detail: perWeek(metrics.merged.count, days: metrics.window.lengthInDays()),
                    drill: .merged, selection: $selection,
                    change: previous.flatMap { StatChange.percent(Double(metrics.merged.count), Double($0.merged), higherIsWorse: false) }
                )
                StatTile(
                    title: "Cycle time", value: metrics.cycleTime.median?.compactDuration ?? "-", detail: "Median",
                    drill: .cycleTime, selection: $selection,
                    change: change(metrics.cycleTime.median, previous?.cycleTime.median)
                )
                StatTile(
                    title: "Time to first review", value: metrics.timeToFirstReview.median?.compactDuration ?? "-", detail: "Median",
                    drill: .timeToFirstReview, selection: $selection,
                    change: change(metrics.timeToFirstReview.median, previous?.timeToFirstReview.median)
                )
                StatTile(
                    title: "Merged without review", value: "\(metrics.mergedWithoutReview.count)",
                    detail: metrics.mergedNeedingReview == 0 ? nil : percent(metrics.mergedWithoutReview.count, of: metrics.mergedNeedingReview),
                    drill: .mergedWithoutReview, selection: $selection
                )
            }
            if !goals.isEmpty {
                let met = goals.filter { $0.onTrack == true }.count
                Label("\(met) of \(goals.count) goals on track", systemImage: met == goals.count ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(met == goals.count ? ChartPalette.good : ChartPalette.warning)
                    .font(.callout)
            }
        }
    }

    // MARK: Right now

    private var rightNow: some View {
        VStack(alignment: .leading, spacing: 10) {
            TileGrid {
                StatTile(
                    title: "Open PRs",
                    value: "\(workload.openPullRequests.count)",
                    drill: .openPullRequests,
                    selection: $selection
                )
                StatTile(
                    title: "Awaiting first review",
                    value: "\(workload.awaitingFirstReview.count)",
                    detail: workload.awaitingFirstReview.first.map { "Oldest opened " + $0.createdAt.formatted(.relative(presentation: .named)) },
                    drill: .awaitingFirstReview,
                    selection: $selection
                )
                StatTile(
                    title: "Stale PRs",
                    value: "\(workload.openPullRequests.filter(Workload.isStale).count)",
                    detail: "No activity for \(Workload.staleAfterDays)d",
                    drill: .stalePullRequests,
                    selection: $selection
                )
                if workload.team == nil {
                    StatTile(
                        title: "Unassigned issues",
                        value: "\(workload.unassignedIssues.count)",
                        drill: .unassignedIssues,
                        selection: $selection
                    )
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if store.errors[org] != nil || metrics?.isTeamScoped == true {
            VStack(alignment: .leading, spacing: 6) {
                if let error = store.errors[org] {
                    Banner(message: "Metrics sync failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                        Task { await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays(), force: true) }
                    }
                }
                if metrics?.isTeamScoped == true {
                    Text("Scoped to PRs authored by the team. PRs opened is org-wide.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Fetching merged PRs for \(MetricsWindow(code: windowDays).span). The first sync of a large org can take a minute.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Delivery

    private func delivery(_ metrics: OrgMetrics) -> some View {
        TileGrid {
            let previous = metrics.previous
            StatTile(
                title: "PRs opened", value: "\(metrics.opened)", detail: "Whole weeks, org-wide",
                change: previous?.opened.flatMap { StatChange.percent(Double(metrics.opened), Double($0), higherIsWorse: nil) }
            )
            StatTile(
                title: "PRs merged",
                value: "\(metrics.merged.count)",
                detail: perWeek(metrics.merged.count, days: metrics.window.lengthInDays()),
                drill: .merged,
                selection: $selection,
                change: previous.flatMap { StatChange.percent(Double(metrics.merged.count), Double($0.merged), higherIsWorse: false) }
            )
            StatTile(
                title: "Cycle time",
                value: metrics.cycleTime.median?.compactDuration ?? "-",
                detail: metrics.cycleTime.p75.map { "Median · p75 \($0.compactDuration)" },
                drill: .cycleTime,
                selection: $selection,
                change: change(metrics.cycleTime.median, previous?.cycleTime.median)
            )
            StatTile(
                title: "Time to first review",
                value: metrics.timeToFirstReview.median?.compactDuration ?? "-",
                detail: metrics.timeToFirstReview.p75.map { "Median · p75 \($0.compactDuration)" },
                drill: .timeToFirstReview,
                selection: $selection,
                change: change(metrics.timeToFirstReview.median, previous?.timeToFirstReview.median)
            )
            StatTile(
                title: "Review requests answered",
                value: answeredRate(metrics),
                detail: "\(metrics.reviewOutcomes.filter { $0.respondedAt == nil }.count) unanswered of \(metrics.reviewOutcomes.count)",
                drill: .unansweredRequests,
                selection: $selection,
                change: StatChange.points(metrics.answeredShare, previous?.answeredShare, higherIsWorse: false)
            )
            StatTile(
                title: "Merged without review",
                value: "\(metrics.mergedWithoutReview.count)",
                detail: metrics.mergedNeedingReview == 0 ? nil : percent(metrics.mergedWithoutReview.count, of: metrics.mergedNeedingReview),
                drill: .mergedWithoutReview,
                selection: $selection,
                change: StatChange.points(metrics.unreviewedShare, previous?.unreviewedShare, higherIsWorse: true)
            )
        }
    }

    /// A duration's change on the period before; longer is worse.
    private func change(_ now: TimeInterval?, _ before: TimeInterval?) -> StatChange? {
        guard let now, let before else { return nil }
        return StatChange.percent(now, before, higherIsWorse: true)
    }

    private func answeredRate(_ metrics: OrgMetrics) -> String {
        guard !metrics.reviewOutcomes.isEmpty else { return "-" }
        let answered = metrics.reviewOutcomes.filter { $0.respondedAt != nil }.count
        return (Double(answered) / Double(metrics.reviewOutcomes.count)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func perWeek(_ count: Int, days: Double) -> String {
        let weekly = Double(count) / (days / 7)
        return weekly.formatted(.number.precision(.fractionLength(weekly < 10 ? 1 : 0))) + " a week"
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0))) + " of merged"
    }

    // MARK: Stages

    /// Median of each stage as a single stacked bar, with a legend that
    /// carries the values and opens each stage's PRs.
    private func stageBreakdown(_ metrics: OrgMetrics) -> some View {
        let summaries = CycleStage.allCases.map { ($0, metrics.stages[$0]) }
        let stages = summaries.map { ($0.0, $0.1?.overall.median ?? 0) }
        let total = max(stages.map(\.1).reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Where cycle time goes").font(.headline)
            GeometryReader { geometry in
                let gaps = CGFloat(stages.count - 1) * 2
                HStack(spacing: 2) {
                    ForEach(stages, id: \.0) { stage, value in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(stage.color)
                            .frame(width: max(0, (geometry.size.width - gaps) * value / total))
                            .help("\(stage.rawValue): median \(value.compactDuration)")
                    }
                }
            }
            .frame(height: 18)
            FlowLegend {
                ForEach(summaries, id: \.0) { stage, summary in
                    Button {
                        selection = .metric(.stage(stage))
                    } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(stage.color).frame(width: 10, height: 10)
                            Text(stage.rawValue)
                            Text(stageValue(summary))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(stage.help)
                }
            }
            Text("Bars are the median of each stage, so they needn't add up to the median cycle time. Stages most PRs skip show how often they happen and their median when they do.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func stageValue(_ summary: StageSummary?) -> String {
        guard let summary else { return "-" }
        guard summary.isOccasional else { return summary.overall.median?.compactDuration ?? "-" }
        let share = summary.share.formatted(.percent.precision(.fractionLength(0)))
        return "\(share) of PRs · \(summary.whenItHappens.median?.compactDuration ?? "-")"
    }

    // MARK: Charts

    private func charts(_ metrics: OrgMetrics) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            WeeklyThroughputChart(weeks: metrics.weeks, selection: $selection)
            WeeklyCycleTimeChart(weeks: metrics.weeks, selection: $selection)
        }
    }

    // MARK: Tables
}

// MARK: - People table

/// One person's authoring and reviewing stats together.
nonisolated struct PersonStatsRow: Identifiable {
    let person: Person
    let author: PersonMetrics?
    let reviewer: ReviewerMetrics?

    var id: String { person.login }

    var activity: Int {
        (author?.merged ?? 0) + (author?.reviewsGiven ?? 0) + (reviewer?.requested ?? 0) + (reviewer?.pending ?? 0)
    }

    static func rows(_ metrics: OrgMetrics) -> [PersonStatsRow] {
        let authors = Dictionary(metrics.people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reviewers = Dictionary(metrics.reviewers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(authors.keys).union(reviewers.keys).map { login in
            let author = authors[login]
            let reviewer = reviewers[login]
            // Prefer whichever side has a display name.
            let person = [author?.person, reviewer?.person].compactMap { $0 }.first { $0.name != nil }
                ?? author?.person ?? reviewer!.person
            return PersonStatsRow(person: person, author: author, reviewer: reviewer)
        }
    }
}

// MARK: - Layout

/// Section title that stays pinned to the top while its section scrolls.
struct PinnedHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
        }
        .background(.bar)
    }
}

extension View {
    /// Standard padding for content under a pinned section header.
    func sectionContent() -> some View {
        padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
    }
}

// MARK: - Tiles

struct TileGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
            content
        }
    }
}

/// A headline number. With a drill it's a button that opens the items behind it.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var drill: MetricDrill?
    var selection: Binding<DetailSelection?>?
    /// Change on the period before, beside the value.
    var change: StatChange?

    var body: some View {
        if let drill, let selection {
            let isSelected = selection.wrappedValue == .metric(drill)
            Button {
                selection.wrappedValue = .metric(drill)
            } label: {
                tile(isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .opensElsewhere(.metric(drill))
        } else {
            tile(isSelected: false)
        }
    }

    private func tile(isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                if drill != nil {
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.title.weight(.semibold).monospacedDigit())
                ChangeLabel(change: change)
                    .font(.callout.weight(.medium))
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Wraps legend items onto as many lines as they need.
private struct FlowLegend<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: 14) { content }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + 6
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                height += rowHeight + 6
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxWidth = max(maxWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (maxWidth, height + rowHeight)
    }
}

// MARK: - Charts

/// Opened and merged PRs per week, side by side. Hover for values, click a
/// week to open its merged PRs.
private struct WeeklyThroughputChart: View {
    let weeks: [WeekMetrics]
    @Binding var selection: DetailSelection?
    @State private var hovered: Date?

    private struct Point: Identifiable {
        let week: Date
        let series: String
        let count: Int
        var id: String { "\(week.timeIntervalSince1970)-\(series)" }
    }

    var body: some View {
        let points = weeks.flatMap { week in
            [
                Point(week: week.start, series: "Opened", count: week.opened ?? 0),
                Point(week: week.start, series: "Merged", count: week.merged),
            ]
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("PRs per week").font(.headline)
            Chart(points) { point in
                bar(point)
            }
            .chartForegroundStyleScale(["Opened": ChartPalette.blue, "Merged": ChartPalette.orange])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: weeks.count > 8 ? 2 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in
                WeekHoverOverlay(proxy: proxy, weeks: weeks.map(\.start), hovered: $hovered) { week in
                    selection = .metric(.week(week))
                }
            }
            .frame(height: 160)
            tooltip
        }
    }

    private func bar(_ point: Point) -> some ChartContent {
        let opacity: Double = hovered == nil || hovered == point.week ? 1 : 0.4
        return BarMark(
            x: .value("Week", point.week, unit: .weekOfYear),
            y: .value("PRs", point.count)
        )
        .foregroundStyle(by: .value("Series", point.series))
        .position(by: .value("Series", point.series))
        .cornerRadius(4)
        .opacity(opacity)
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered, let week = weeks.first(where: { $0.start == hovered }) {
            Text("Week of \(week.start.formatted(.dateTime.day().month())): \(week.opened.map(String.init) ?? "-") opened, \(week.merged) merged")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Hover a week for values, click to see its merged PRs.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Median cycle time per week, in days.
private struct WeeklyCycleTimeChart: View {
    let weeks: [WeekMetrics]
    @Binding var selection: DetailSelection?
    @State private var hovered: Date?

    var body: some View {
        // Plotted in hours; ticks are labelled as durations so short and
        // long cycle times both read naturally.
        let points = weeks.compactMap { week in week.cycleTime.median.map { (week.start, $0 / 3600) } }
        let top = max(points.map(\.1).max() ?? 1, 0.5) * 1.15
        VStack(alignment: .leading, spacing: 8) {
            Text("Median cycle time per week").font(.headline)
            Chart {
                ForEach(points, id: \.0) { week, hours in
                    LineMark(x: .value("Week", week, unit: .weekOfYear), y: .value("Hours", hours))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(ChartPalette.blue)
                    PointMark(x: .value("Week", week, unit: .weekOfYear), y: .value("Hours", hours))
                        .symbolSize(hovered == week ? 90 : 50)
                        .foregroundStyle(ChartPalette.blue)
                }
                if let hovered {
                    RuleMark(x: .value("Week", hovered, unit: .weekOfYear))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let hours = value.as(Double.self) { Text((hours * 3600).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: weeks.count > 8 ? 2 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in
                WeekHoverOverlay(proxy: proxy, weeks: weeks.map(\.start), hovered: $hovered) { week in
                    selection = .metric(.week(week))
                }
            }
            .frame(height: 140)
            if let hovered, let week = weeks.first(where: { $0.start == hovered }) {
                Text("Week of \(week.start.formatted(.dateTime.day().month())): median \(week.cycleTime.median?.compactDuration ?? "-"), p75 \(week.cycleTime.p75?.compactDuration ?? "-") over \(week.merged) PRs")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.callout)
            }
        }
    }
}

/// Maps the pointer to the nearest week for hover and click.
struct WeekHoverOverlay: View {
    let proxy: ChartProxy
    let weeks: [Date]
    @Binding var hovered: Date?
    let onSelect: (Date) -> Void

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = week(at: location, in: geometry)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { location in
                    if let week = week(at: location, in: geometry) { onSelect(week) }
                }
        }
    }

    private func week(at location: CGPoint, in geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let x = location.x - geometry[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        // Nearest week by its midpoint, so it doesn't matter which day the
        // chart's own calendar starts weeks on.
        let halfWeek: TimeInterval = 3.5 * 86_400
        return weeks
            .map { ($0, abs(date.timeIntervalSince($0.addingTimeInterval(halfWeek)))) }
            .filter { $0.1 <= halfWeek * 1.2 }
            .min { $0.1 < $1.1 }?.0
    }
}
