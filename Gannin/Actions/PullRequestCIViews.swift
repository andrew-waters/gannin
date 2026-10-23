import Charts
import SwiftUI

// MARK: - CI page sections

/// CI time per PR on the CI page: the averages and what's behind them, then
/// every PR, who uses the time, and how it follows the amount of change.
struct PullRequestCISections: View {
    let org: String
    let ci: PullRequestCIMetrics
    let hasPrevious: Bool
    let navigate: (DetailSelection) -> Void
    @State private var filter: PullRequestCIFilter = .all
    @State private var showAll = false
    @State private var sort: StatsSort?
    @State private var peopleSort: StatsSort?
    @State private var bandSort: StatsSort?

    private static let shown = 50

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                if ci.pullRequests.isEmpty && ci.bots.isEmpty {
                    Text("No pull requests with CI runs in the window.").foregroundStyle(.secondary)
                } else {
                    PullRequestCITiles(ci: ci, hasPrevious: hasPrevious)
                    if ci.unmatchedTime > 0 {
                        Text("\(ci.unmatchedTime.compactDuration) of pull request runs couldn't be matched to a pull request: from forks, or not yet fetched.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    let rows = filter.rows(ci)
                    PullRequestCITable(org: org, pullRequests: showAll ? rows : Array(rows.prefix(Self.shown)), sort: $sort, navigate: navigate)
                    if rows.count > Self.shown {
                        Button(showAll ? "Show the first \(Self.shown)" : "Show all \(rows.count)") { showAll.toggle() }
                            .linkButton()
                            .font(.callout)
                    }
                }
            }
            .sectionContent()
        } header: {
            PinnedHeader {
                HStack(spacing: 12) {
                    SectionHeader(title: "Pull requests", count: filter.rows(ci).count)
                    Spacer(minLength: 8)
                    Picker("Show", selection: $filter) {
                        ForEach(PullRequestCIFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .font(.body)
                }
            }
        }
        if !ci.people.isEmpty {
            Section {
                PeopleCITable(people: ci.people, sort: $peopleSort, navigate: navigate)
                    .sectionContent()
            } header: {
                PinnedHeader { SectionHeader(title: "People", count: ci.people.count) }
            }
        }
        if !ci.scaling.points.isEmpty || ci.scaling.weeks.contains(where: { $0.lines > 0 }) {
            Section {
                CIScalingView(scaling: ci.scaling, hasPrevious: hasPrevious, sort: $bandSort, navigate: navigate)
                    .sectionContent()
            } header: {
                PinnedHeader { Text("CI and the size of change") }
            }
        }
    }
}

/// Which PRs the table lists.
enum PullRequestCIFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case wasted = "Most wasted"
    case small = "Small, full CI"
    case bots = "Bots"

    var id: Self { self }

    func rows(_ ci: PullRequestCIMetrics) -> [PullRequestCI] {
        switch self {
        case .all: ci.pullRequests
        case .wasted: ci.pullRequests.filter { $0.wastedTime > 0 }.sorted { ($0.wastedTime, $1.id) > ($1.wastedTime, $0.id) }
        case .small: ci.smallButCostly
        case .bots: ci.bots
        }
    }
}

/// The window's CI time per PR and what's behind it, against the period
/// before when every repo's runs reach back that far.
struct PullRequestCITiles: View {
    let ci: PullRequestCIMetrics
    let hasPrevious: Bool

    var body: some View {
        let botShare = ci.runTime + ci.botTime > 0 ? ci.botTime / (ci.runTime + ci.botTime) : nil
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            StatTile(
                title: "CI time per PR",
                value: ci.perPR.median?.compactDuration ?? "-",
                detail: "p75 \(ci.perPR.p75?.compactDuration ?? "-") · \(ci.pullRequests.count) PRs",
                change: hasPrevious ? ci.perPR.median.flatMap { now in ci.previousPerPR.median.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } : nil
            )
            StatTile(
                title: "Wasted",
                value: ActionsView.percent(ci.wastedShare),
                detail: "\(ci.wastedTime.compactDuration) on replaced commits and failures",
                change: hasPrevious ? StatChange.points(ci.wastedShare, ci.previousWastedShare, higherIsWorse: true) : nil
            )
            StatTile(
                title: "Waiting on CI",
                value: ci.finalWait.median?.compactDuration ?? "-",
                detail: ci.finalWaitShare.map { "Final push to green, \(ActionsView.percent($0)) of cycle time" } ?? "Final push to green, merged PRs"
            )
            StatTile(
                title: "Merged on CI",
                value: ActionsView.percent(ci.mergedWithWait == 0 ? nil : Double(ci.mergedOnCI) / Double(ci.mergedWithWait)),
                detail: "Merged within 15 min of CI finishing"
            )
            StatTile(
                title: "Small, full CI",
                value: "\(ci.smallButCostly.count)",
                detail: "Up to \(PullRequestCI.smallLines) lines, over the median PR"
            )
            StatTile(
                title: "CI per 1,000 lines",
                value: ci.scaling.minutesPerThousand.map { ($0 * 60).compactDuration } ?? "-",
                detail: "PR CI time over lines merged",
                change: hasPrevious ? ci.scaling.minutesPerThousand.flatMap { now in ci.scaling.previousMinutesPerThousand.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } : nil
            )
            StatTile(
                title: "Bots",
                value: ActionsView.percent(botShare),
                detail: "\(ci.botTime.compactDuration) on \(ci.bots.count) PRs, left out above"
            )
        }
    }
}

/// PRs with the CI they took and what drove it; each opens its runs.
struct PullRequestCITable: View {
    @Environment(\.openURL) private var openURL
    let org: String
    let pullRequests: [PullRequestCI]
    @Binding var sort: StatsSort?
    let navigate: (DetailSelection) -> Void

    var body: some View {
        let scale = BarScale(pullRequests.map(\.runTime))
        StatsTable(
            rows: pullRequests,
            columns: [
                StatsColumn(
                    id: "pr", title: "Pull request", help: "Pull requests by their latest run in the window",
                    width: nil, minWidth: 240,
                    sortKey: { .text(($0.title ?? "").lowercased()) },
                    cell: { pr in
                        AnyView(HStack(spacing: 6) {
                            Text(pr.title ?? "#\(pr.number)").lineLimit(1)
                            Text("\(pr.shortRepo)#\(pr.number)").foregroundStyle(.secondary).lineLimit(1)
                            if pr.merged == nil {
                                Text("open").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .help(pr.id))
                    }
                ),
                StatsColumn(
                    id: "author", title: "Author", help: "Who opened it",
                    width: 110,
                    sortKey: { .text(($0.author ?? "").lowercased()) },
                    cell: { AnyView(Text($0.author ?? "-").lineLimit(1).foregroundStyle(.secondary)) }
                ),
                StatsColumn(
                    id: "time", title: "CI time", help: "Wall-clock time summed over its runs",
                    width: 160,
                    sortKey: { .number($0.runTime) },
                    cell: { AnyView(BarCell(value: $0.runTime, scale: scale)) }
                ),
                StatsColumn(
                    id: "workflows", title: "By workflow", help: "Its CI time split by workflow, most first",
                    width: 110,
                    sortKey: { .number(Double($0.workflows.count)) },
                    cell: { AnyView(WorkflowSplitBar(pr: $0)) }
                ),
                StatsColumn(
                    id: "runs", title: "Runs", help: "Runs matched to it",
                    width: 48,
                    sortKey: { .number(Double($0.runs.count)) },
                    cell: { AnyView(NumberCell(text: "\($0.runs.count)", dimmed: false)) }
                ),
                StatsColumn(
                    id: "commits", title: "Pushes", help: "Commits CI ran on",
                    width: 56,
                    sortKey: { .number(Double($0.commits)) },
                    cell: { AnyView(NumberCell(text: "\($0.commits)", dimmed: $0.commits <= 1)) }
                ),
                StatsColumn(
                    id: "failed", title: "Failed", help: "Runs that failed",
                    width: 52,
                    sortKey: { .number(Double($0.failed)) },
                    cell: { AnyView(NumberCell(text: "\($0.failed)", dimmed: $0.failed == 0)) }
                ),
                StatsColumn(
                    id: "reruns", title: "Re-runs", help: "Runs re-run at least once (earlier attempts' time isn't listed)",
                    width: 58,
                    sortKey: { .number(Double($0.reruns)) },
                    cell: { AnyView(NumberCell(text: "\($0.reruns)", dimmed: $0.reruns == 0)) }
                ),
                StatsColumn(
                    id: "wasted", title: "Wasted", help: "Time on commits a later push replaced, and on failed or cancelled runs of the last commit",
                    width: 70,
                    sortKey: { .number($0.wastedTime) },
                    cell: { pr in
                        AnyView(NumberCell(text: pr.wastedTime > 0 ? pr.wastedTime.compactDuration : "-", dimmed: pr.wastedTime == 0)
                            .help("\(pr.supersededTime.compactDuration) on replaced commits, \(pr.failedTime.compactDuration) on failed or cancelled runs"))
                    }
                ),
                StatsColumn(
                    id: "lines", title: "Lines", help: "Lines changed, once merged",
                    width: 60,
                    sortKey: { .number(Double($0.lines ?? -1)) },
                    cell: { AnyView(NumberCell(text: $0.lines.map { "\($0)" } ?? "-", dimmed: $0.lines == nil)) }
                ),
                StatsColumn(
                    id: "wait", title: "Wait", help: "Merged PRs: the final push to its CI finishing",
                    width: 56,
                    sortKey: { .number($0.finalWait ?? -1) },
                    cell: { pr in
                        AnyView(NumberCell(text: pr.finalWait?.compactDuration ?? "-", dimmed: pr.finalWait == nil)
                            .help(pr.mergedOnCI ? "Merged within 15 minutes of CI finishing" : "Waited on CI"))
                    }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { navigate(.pullRequestCI($0.id)) },
            contextMenu: { pr in
                AnyView(Group {
                    if let url = pr.url {
                        Button("Open on GitHub") { openURL(url) }
                    }
                })
            },
            destination: { .pullRequestCI($0.id) }
        )
    }
}

/// A PR's CI time as one bar split by workflow, in palette order, with the
/// split in its tooltip.
private struct WorkflowSplitBar: View {
    let pr: PullRequestCI

    var body: some View {
        let shown = Array(pr.workflows.prefix(4))
        let total = max(pr.runTime, 1)
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, workflow in
                    Rectangle()
                        .fill(ChartPalette.slot(index))
                        .frame(width: max(2, geometry.size.width * workflow.time / total))
                }
                Spacer(minLength: 0)
            }
            .background(ChartPalette.neutral.opacity(0.4))
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .help(pr.workflows.map { "\($0.name): \($0.time.compactDuration)" }.joined(separator: "\n"))
    }
}

/// Authors by CI time, against their share of PRs.
struct PeopleCITable: View {
    let people: [PersonCI]
    @Binding var sort: StatsSort?
    let navigate: (DetailSelection) -> Void

    var body: some View {
        let scale = BarScale(people.map(\.runTime))
        StatsTable(
            rows: people,
            columns: [
                StatsColumn(
                    id: "person", title: "Person", help: "Authors of PRs with CI in the window",
                    width: nil, minWidth: 150,
                    sortKey: { .text($0.login.lowercased()) },
                    cell: { AnyView(Text($0.login).lineLimit(1)) }
                ),
                StatsColumn(
                    id: "prs", title: "PRs", help: "Their PRs with CI in the window",
                    width: 40,
                    sortKey: { .number(Double($0.pullRequests.count)) },
                    cell: { AnyView(NumberCell(text: "\($0.pullRequests.count)", dimmed: false)) }
                ),
                StatsColumn(
                    id: "time", title: "CI time", help: "Summed over their PRs",
                    width: 160,
                    sortKey: { .number($0.runTime) },
                    cell: { AnyView(BarCell(value: $0.runTime, scale: scale)) }
                ),
                StatsColumn(
                    id: "share", title: "Of CI · of PRs", help: "Their share of everyone's PR CI time, and of the PRs",
                    width: 104,
                    sortKey: { .number($0.shareOfTime) },
                    cell: { AnyView(NumberCell(text: "\(ActionsView.percent($0.shareOfTime)) · \(ActionsView.percent($0.shareOfPRs))", dimmed: false)) }
                ),
                StatsColumn(
                    id: "weight", title: "Weight", help: "Share of CI time over share of PRs: over 1× their PRs cost more than their count suggests",
                    width: 56,
                    sortKey: { .number($0.weight ?? 0) },
                    cell: { person in
                        AnyView(NumberCell(text: person.weight.map { "\($0.formatted(.number.precision(.fractionLength(1))))×" } ?? "-", dimmed: (person.weight ?? 0) <= 1))
                    }
                ),
                StatsColumn(
                    id: "median", title: "Median", help: "Median CI time per PR",
                    width: 60,
                    sortKey: { .number($0.perPR.median ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.perPR.median?.compactDuration ?? "-", dimmed: false)) }
                ),
                StatsColumn(
                    id: "p75", title: "p75", help: "75th percentile CI time per PR",
                    width: 56,
                    sortKey: { .number($0.perPR.p75 ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.perPR.p75?.compactDuration ?? "-", dimmed: false)) }
                ),
                StatsColumn(
                    id: "pushes", title: "Pushes", help: "Median commits CI ran on, per PR",
                    width: 56, group: "Median per PR",
                    sortKey: { .number($0.commits ?? -1) },
                    cell: { AnyView(NumberCell(text: Self.count($0.commits), dimmed: false)) }
                ),
                StatsColumn(
                    id: "failed", title: "Failed", help: "Median failed runs per PR",
                    width: 52, group: "Median per PR",
                    sortKey: { .number($0.failed ?? -1) },
                    cell: { AnyView(NumberCell(text: Self.count($0.failed), dimmed: ($0.failed ?? 0) == 0)) }
                ),
                StatsColumn(
                    id: "reruns", title: "Re-runs", help: "Median re-run runs per PR",
                    width: 58, group: "Median per PR",
                    sortKey: { .number($0.reruns ?? -1) },
                    cell: { AnyView(NumberCell(text: Self.count($0.reruns), dimmed: ($0.reruns ?? 0) == 0)) }
                ),
                StatsColumn(
                    id: "wasted", title: "Wasted", help: "Their time on replaced commits and failures, and its share of their CI time",
                    width: 90,
                    sortKey: { .number($0.wastedTime) },
                    cell: { person in
                        AnyView(NumberCell(text: person.runTime > 0 ? "\(person.wastedTime.compactDuration) · \(ActionsView.percent(person.wastedTime / person.runTime))" : "-", dimmed: person.wastedTime == 0))
                    }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { navigate(.personCI($0.login)) },
            destination: { .personCI($0.login) }
        )
    }

    static func count(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "-"
    }
}

// MARK: - Scaling

/// Whether CI time grows in step with the change it checks: each merged PR's
/// lines against its CI time, the median by size band, and CI minutes per
/// 1,000 lines merged, week by week.
struct CIScalingView: View {
    let scaling: CIScaling
    let hasPrevious: Bool
    @Binding var sort: StatsSort?
    let navigate: (DetailSelection) -> Void
    @State private var hovered: PullRequestCI?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !scaling.points.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        scatter.frame(minWidth: 420)
                        weekly.frame(minWidth: 360)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        scatter
                        weekly
                    }
                }
                bands
            } else {
                weekly
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let correlation = scaling.correlation {
            let strength = switch abs(correlation) {
            case ..<0.2: "barely follows"
            case ..<0.4: "loosely follows"
            case ..<0.7: "follows"
            default: "closely follows"
            }
            parts.append("CI time \(strength) PR size (rank correlation \(correlation.formatted(.number.precision(.fractionLength(2)))), over \(scaling.points.count) merged PRs).")
        } else {
            parts.append("Too few merged PRs with CI to say how CI time follows size.")
        }
        if let first = scaling.bands.first?.perHundredLines, let last = scaling.bands.last?.perHundredLines, scaling.bands.count > 1 {
            parts.append(first > last * 1.5
                ? "Small PRs cost more per line: a fixed cost each PR pays, whatever its size."
                : "The cost per line holds roughly steady across sizes.")
        }
        return parts.joined(separator: " ")
    }

    private var scatter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CI time by lines changed").font(.headline)
            Chart {
                ForEach(scaling.points) { pr in
                    PointMark(
                        x: .value("Lines", max(pr.lines ?? 1, 1)),
                        y: .value("Minutes", max(pr.runTime / 60, 0.1))
                    )
                    .foregroundStyle(ChartPalette.blue.opacity(hovered?.id == pr.id ? 1 : 0.6))
                    .symbolSize(hovered?.id == pr.id ? 80 : 24)
                }
            }
            .chartXScale(type: .log)
            .chartYScale(type: .log)
            .chartXAxisLabel("Lines changed")
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = nearest(location, proxy: proxy, geometry: geometry)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            if let pr = nearest(location, proxy: proxy, geometry: geometry) { navigate(.pullRequestCI(pr.id)) }
                        }
                }
            }
            .frame(height: 220)
            if let hovered {
                Text("\(hovered.shortRepo)#\(hovered.number) \(hovered.title ?? ""): \(hovered.lines ?? 0) lines, \(hovered.runTime.compactDuration)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Both axes are logarithmic. Hover a PR for details, click to open it.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func nearest(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> PullRequestCI? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        var best: (PullRequestCI, CGFloat)?
        for pr in scaling.points {
            guard let x = proxy.position(forX: max(pr.lines ?? 1, 1)), let y = proxy.position(forY: max(pr.runTime / 60, 0.1)) else { continue }
            let distance = hypot(x - point.x, y - point.y)
            if distance < (best?.1 ?? 20) { best = (pr, distance) }
        }
        return best?.0
    }

    private var weekly: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CI per 1,000 lines merged").font(.headline)
            Chart(scaling.weeks) { week in
                if let ratio = week.minutesPerThousand {
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Minutes", ratio))
                        .foregroundStyle(ChartPalette.blue)
                        .annotation(position: .top) {
                            Text((ratio * 60).compactDuration).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .frame(height: 220)
            Text("Rising means CI time grows faster than the change it checks.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .help(scaling.weeks.map { "\($0.start.formatted(.dateTime.day().month())): \($0.runTime.compactDuration) of CI, \($0.lines) lines merged" }.joined(separator: "\n"))
        }
    }

    private var bands: some View {
        let scale = BarScale(scaling.bands.compactMap(\.time.median))
        return StatsTable(
            rows: scaling.bands,
            columns: [
                StatsColumn(
                    id: "band", title: "Lines changed", help: "Merged PRs by size",
                    width: nil, minWidth: 120,
                    sortKey: { band in .number(Double(SizeStat.bucketLabels.firstIndex(of: band.label) ?? 0)) },
                    cell: { AnyView(Text($0.label)) }
                ),
                StatsColumn(
                    id: "prs", title: "PRs", help: "Merged PRs with CI in this band",
                    width: 44,
                    sortKey: { .number(Double($0.count)) },
                    cell: { AnyView(NumberCell(text: "\($0.count)", dimmed: false)) }
                ),
                StatsColumn(
                    id: "median", title: "Median CI time", help: "Median CI time per PR",
                    width: 170,
                    sortKey: { .number($0.time.median ?? -1) },
                    cell: { AnyView(BarCell(value: $0.time.median, scale: scale)) }
                ),
                StatsColumn(
                    id: "p75", title: "p75", help: "75th percentile CI time per PR",
                    width: 56,
                    sortKey: { .number($0.time.p75 ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.time.p75?.compactDuration ?? "-", dimmed: false)) }
                ),
                StatsColumn(
                    id: "perHundred", title: "Per 100 lines", help: "Median per PR of CI time for each 100 lines changed: steady if CI time grows in step with size",
                    width: 90,
                    sortKey: { .number($0.perHundredLines ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.perHundredLines?.compactDuration ?? "-", dimmed: false)) }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { _ in }
        )
    }
}

// MARK: - Pages

/// One PR's CI: its time against the median PR, what made it up, and its
/// runs commit by commit, newest first.
struct PullRequestCIPage: View {
    let org: String
    let pr: PullRequestCI
    let metrics: PullRequestCIMetrics
    let navigate: (DetailSelection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                tiles
                ActionsSection("By workflow") { workflows }
                ActionsSection("Runs by commit") { commits }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title ?? "#\(pr.number)").font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text("\(pr.repo)#\(pr.number)")
                if let author = pr.author {
                    Text("·")
                    Text(author)
                }
                Text("·")
                Text(pr.merged.map { "Merged \($0.mergedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "Open")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if let url = pr.url {
                    Link("Open on GitHub", destination: url)
                }
                if let author = pr.author, metrics.person(author) != nil {
                    Button("\(author)'s CI") { navigate(.personCI(author)) }
                        .linkButton()
                }
            }
            .font(.callout)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
            StatTile(
                title: "CI time", value: pr.runTime.compactDuration,
                detail: metrics.perPR.median.flatMap { $0 > 0 ? "\((pr.runTime / $0).formatted(.number.precision(.fractionLength(1))))× the median PR" : nil }
            )
            StatTile(title: "Runs", value: "\(pr.runs.count)", detail: "\(pr.failed) failed, \(pr.reruns) re-run")
            StatTile(title: "Pushes", value: "\(pr.commits)", detail: "Commits CI ran on")
            StatTile(
                title: "Wasted", value: pr.wastedTime.compactDuration,
                detail: "\(pr.supersededTime.compactDuration) replaced, \(pr.failedTime.compactDuration) failed"
            )
            if let lines = pr.lines {
                StatTile(title: "Lines changed", value: "\(lines)", detail: pr.merged?.changedFiles.map { "\($0) files" })
            }
            if let wait = pr.finalWait {
                StatTile(
                    title: "Waiting on CI", value: wait.compactDuration,
                    detail: pr.mergeAfterCI.map { $0 < 0 ? "Merged before CI finished" : "Merged \($0.compactDuration) after" }
                )
            }
        }
    }

    private var workflows: some View {
        let scale = BarScale(pr.workflows.map(\.time))
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(pr.workflows.enumerated()), id: \.offset) { index, workflow in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(index < 4 ? ChartPalette.slot(index) : ChartPalette.neutral).frame(width: 8, height: 8)
                        Text(workflow.name).lineLimit(1)
                    }
                    BarCell(value: workflow.time, scale: scale).frame(width: 220)
                    Text(ActionsView.percent(pr.runTime > 0 ? workflow.time / pr.runTime : nil)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private var commits: some View {
        let latest = pr.runs.first?.headSha
        let groups = Dictionary(grouping: pr.runs, by: \.headSha)
            .map { (sha: $0.key, runs: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.runs.last?.createdAt ?? .distantPast) > ($1.runs.last?.createdAt ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.sha) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(String(group.sha.prefix(7))).font(.callout.monospaced()).textSelection(.enabled)
                        Text(group.runs.reduce(0) { $0 + ($1.duration ?? 0) }.compactDuration).monospacedDigit()
                        Text(group.sha == latest ? "Latest" : "Replaced by a later push").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let pushed = group.runs.last?.createdAt {
                            RelativeDate(date: pushed).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    RunList(runs: group.runs, navigate: navigate)
                }
            }
        }
    }
}

/// One person's PRs and the CI they took, against everyone's.
struct PersonCIPage: View {
    let org: String
    let person: PersonCI
    let metrics: PullRequestCIMetrics
    let navigate: (DetailSelection) -> Void
    @State private var sort: StatsSort?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(person.login).font(.title2.weight(.semibold))
                    Text("Pull requests with CI in the window").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "CI time", value: person.runTime.compactDuration, detail: "\(ActionsView.percent(person.shareOfTime)) of everyone's")
                    StatTile(title: "PRs", value: "\(person.pullRequests.count)", detail: "\(ActionsView.percent(person.shareOfPRs)) of everyone's")
                    StatTile(
                        title: "Weight", value: person.weight.map { "\($0.formatted(.number.precision(.fractionLength(1))))×" } ?? "-",
                        detail: "Share of CI over share of PRs"
                    )
                    StatTile(
                        title: "CI time per PR", value: person.perPR.median?.compactDuration ?? "-",
                        detail: "p75 \(person.perPR.p75?.compactDuration ?? "-") · everyone \(metrics.perPR.median?.compactDuration ?? "-")"
                    )
                    StatTile(
                        title: "Wasted", value: person.runTime > 0 ? ActionsView.percent(person.wastedTime / person.runTime) : "-",
                        detail: "Everyone \(ActionsView.percent(metrics.wastedShare))"
                    )
                    StatTile(
                        title: "Per PR", value: "\(PeopleCITable.count(person.commits)) pushes",
                        detail: "\(PeopleCITable.count(person.failed)) failed, \(PeopleCITable.count(person.reruns)) re-run (medians)"
                    )
                }
                ActionsSection("Pull requests") {
                    PullRequestCITable(org: org, pullRequests: person.pullRequests, sort: $sort, navigate: navigate)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
