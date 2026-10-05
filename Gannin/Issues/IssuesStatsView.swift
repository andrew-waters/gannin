import Charts
import SwiftUI

/// The Issues page: throughput, cycle time, work in progress and a breakdown
/// for the chosen window, from issue history and the org's board workflow.
struct IssuesStatsView: View {
    @Environment(IssueStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.navigate) private var navigate
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("issueGrouping") private var grouping: IssueMetrics.Grouping = .type
    @AppStorage("issueGranularity") private var granularity: IssueMetrics.Granularity = .week
    @State private var sort: StatsSort?
    /// "In progress now" order: "project number|field name", or empty for
    /// time in progress. Remembered per org.
    @State private var order = ""
    @State private var descending = false
    /// Narrows the In progress now list.
    @State private var search = ""

    let org: String
    let workload: Workload?
    @Binding var selection: DetailSelection?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let history = store.history(for: org) {
                    let metrics = IssueMetrics(history: history, window: MetricsWindow(code: windowDays), team: workload?.team, config: configs.config(for: org))
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            notices(metrics, history: history)
                            tiles(metrics)
                        }
                        .updating(store.syncing.contains(org))
                        .sectionContent()
                    }
                    Section {
                        OpenClosedCharts(buckets: metrics.buckets(granularity), granularity: granularity)
                            .sectionContent()
                    } header: {
                        PinnedHeader {
                            HStack(spacing: 12) {
                                Text("Opened and closed")
                                Spacer(minLength: 8)
                                Picker("Per", selection: $granularity) {
                                    ForEach(IssueMetrics.Granularity.allCases.filter { $0 != .year }) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                .font(.body)
                            }
                        }
                    }
                    Section {
                        WIPChart(points: metrics.wip)
                            .sectionContent()
                    } header: {
                        PinnedHeader { Text("In progress") }
                    }
                    Section {
                        CycleScatter(issues: metrics.completed, median: metrics.cycleTime.median) { open($0) }
                            .sectionContent()
                    } header: {
                        PinnedHeader { Text("Cycle time") }
                    }
                    Section {
                        inProgressList(metrics).sectionContent()
                    } header: {
                        PinnedHeader { inProgressHeader(metrics) }
                    }
                    Section {
                        breakdown(metrics).sectionContent()
                    } header: {
                        PinnedHeader {
                            HStack(spacing: 12) {
                                Text("Breakdown")
                                Spacer(minLength: 8)
                                Picker("Group by", selection: $grouping) {
                                    ForEach(IssueMetrics.Grouping.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                .font(.body)
                            }
                        }
                    }
                } else {
                    Section {
                        Group {
                            if let error = store.errors[org] {
                                Banner(message: "Couldn't load issues: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                                    Task { await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays(), force: true) }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Fetching issues for \(MetricsWindow(code: windowDays).span), with their board history.").foregroundStyle(.secondary)
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
        }
        .task(id: "\(org) \(windowDays)") { await store.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
        .onAppear {
            order = UserDefaults.standard.string(forKey: "inProgressOrder.\(org)") ?? ""
            descending = UserDefaults.standard.bool(forKey: "inProgressDescending.\(org)")
        }
        .onChange(of: order) { UserDefaults.standard.set(order, forKey: "inProgressOrder.\(org)") }
        .onChange(of: descending) { UserDefaults.standard.set(descending, forKey: "inProgressDescending.\(org)") }
    }

    /// In the toolbar; the title is the window's and the window picker
    /// `OrgWorkloadView`'s.
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
    private func notices(_ metrics: IssueMetrics, history: IssueHistory) -> some View {
        if metrics.statusesSeen.isEmpty && !history.issues.isEmpty {
            Text("No project board status changes found, so cycle time falls back to linked PRs. If your issues live on a GitHub project, sign out and back in to grant project access, then check the workflow in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tiles(_ metrics: IssueMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            StatTile(title: "Completed", value: "\(metrics.completed.count)", detail: "Closed as completed")
            StatTile(title: "Cycle time", value: metrics.cycleTime.median?.compactDuration ?? "-", detail: metrics.cycleTime.p75.map { "Median · p75 \($0.compactDuration)" })
            StatTile(title: "Lead time", value: metrics.leadTime.median?.compactDuration ?? "-", detail: "Median, created to done")
            StatTile(title: "In progress", value: "\(metrics.inProgress.count)", detail: "Right now")
            StatTile(title: "Not planned", value: metrics.notPlannedShare.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-", detail: "\(metrics.notPlanned.count) closed as not planned")
            StatTile(title: "Reopened", value: "\(metrics.reopened)", detail: "Reopen events")
            StatTile(title: "Flow efficiency", value: metrics.flowEfficiency.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-", detail: "Median, days with PR activity")
            StatTile(title: "Scope creep", value: metrics.scopeCreep.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-", detail: "Sub-issues added after start")
        }
    }

    // MARK: In progress

    /// Board fields seen on the in-progress issues, as "project|field" keys.
    private func orderOptions(_ metrics: IssueMetrics) -> [(key: String, label: String)] {
        var options: [String: String] = [:]
        for timing in metrics.inProgress {
            for board in timing.record.projectFields {
                for field in board.values.keys { options["\(board.projectNumber)|\(field)"] = "\(board.projectTitle) › \(field)" }
            }
        }
        return options.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 }
    }

    private func inProgressHeader(_ metrics: IssueMetrics) -> some View {
        let options = orderOptions(metrics)
        return HStack(spacing: 12) {
            SectionHeader(title: "In progress now", count: metrics.inProgress.count)
            TextField("Search", text: $search, prompt: Text("Search in progress"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .font(.body)
                .controlSize(.small)
            Spacer(minLength: 8)
            Group {
                Picker("Order by", selection: $order) {
                    Text("Time in progress").tag("")
                    if !options.isEmpty { Divider() }
                    ForEach(options, id: \.key) { Text($0.label).tag($0.key) }
                }
                .fixedSize()
                Button {
                    descending.toggle()
                } label: {
                    Image(systemName: descending ? "arrow.down" : "arrow.up")
                }
                .help(descending ? "Descending" : "Ascending")
            }
            .font(.body)
            .controlSize(.small)
        }
    }

    /// Where an issue stands for the chosen board field.
    private enum Placement {
        case value(IssueFieldValue)
        case empty
        case notOnBoard
    }

    private func placement(_ record: IssueRecord) -> (placement: Placement, project: String, field: String)? {
        let parts = order.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let number = Int(parts[0]) else { return nil }
        let field = parts[1]
        guard let board = record.fields(onProject: number) else {
            return (.notOnBoard, boardTitle(number), field)
        }
        if let value = board.values[field] { return (.value(value), board.projectTitle, field) }
        return (.empty, board.projectTitle, field)
    }

    private func boardTitle(_ number: Int) -> String {
        store.history(for: org)?.issues.values.lazy.compactMap { $0.fields(onProject: number)?.projectTitle }.first ?? "the board"
    }

    /// Ordered by the chosen field: values in order, then empty on the
    /// board, then not on it; time in progress breaks ties.
    private func ordered(_ issues: [IssueTiming]) -> [IssueTiming] {
        let issues = issues.filter { IssueSearch.matches(search, record: $0.record) }
        let byTime = issues.sorted { ($0.start ?? .now) < ($1.start ?? .now) }
        let timeOrder = descending ? Array(byTime.reversed()) : byTime
        guard !order.isEmpty else { return timeOrder }
        func rank(_ timing: IssueTiming) -> Int {
            switch placement(timing.record)?.placement {
            case .value: 0
            case .empty: 1
            default: 2
            }
        }
        return timeOrder.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            if case .value(let x)? = placement(a.element.record)?.placement, case .value(let y)? = placement(b.element.record)?.placement {
                if IssueFieldValue.ascending(x, y) { return !descending }
                if IssueFieldValue.ascending(y, x) { return descending }
            }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    @ViewBuilder
    private func orderChip(_ record: IssueRecord) -> some View {
        if let (placement, project, field) = placement(record) {
            switch placement {
            case .value(let value):
                Text("\(field): \(value.display)")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            case .empty:
                Text("No \(field)").font(.caption).foregroundStyle(.secondary)
            case .notOnBoard:
                Text("Not in \(project)").font(.caption).italic().foregroundStyle(.tertiary)
            }
        }
    }

    private func inProgressList(_ metrics: IssueMetrics) -> some View {
        VStack(spacing: 0) {
            if metrics.inProgress.isEmpty || ordered(metrics.inProgress).isEmpty {
                Text(metrics.inProgress.isEmpty ? "Nothing in progress." : "Nothing in progress matches.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(ordered(metrics.inProgress)) { timing in
                Button { open(timing.record) } label: {
                    HStack(spacing: 12) {
                        // A fixed slot, so titles line up whoever's assigned.
                        AvatarStack(people: timing.record.assignees.map(person), size: 22)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(timing.record.title).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(timing.record.repo)#\(String(timing.record.number))")
                                if let author = timing.record.author { Text("by \(author)") }
                                if let status = timing.currentStatus { Text("· \(status)") }
                                if let pr = timing.record.linkedPullRequests.last {
                                    Text("· PR #\(String(pr.number)) \(pr.statusText.lowercased())")
                                        .foregroundStyle(pr.statusColor)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        orderChip(timing.record)
                        if let start = timing.start {
                            Text(Date.now.timeIntervalSince(start).compactDuration)
                                .font(.callout.monospacedDigit().weight(.medium))
                                .help("In progress since \(start.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.issueReference(IssueReference(org: org, record: timing.record)))
                Divider()
            }
        }
    }

    /// A member's profile when the snapshot has it; otherwise GitHub's
    /// avatar for the login.
    private func person(_ login: String) -> Person {
        workload?.snapshot.members.first { $0.login == login }
            ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
    }

    // MARK: Breakdown

    private func breakdown(_ metrics: IssueMetrics) -> some View {
        let groups = metrics.groups(by: grouping)
        let scale = BarScale(groups.compactMap(\.cycleTime.median))
        return StatsTable(
            rows: groups,
            columns: [
                StatsColumn(id: "name", title: grouping.rawValue, help: "Issues grouped by \(grouping.rawValue.lowercased())", width: nil, minWidth: 200,
                            sortKey: { .text($0.name.lowercased()) },
                            cell: { AnyView(Text($0.name).lineLimit(1)) }),
                StatsColumn(id: "completed", title: "Completed", help: "Closed as completed in the window", width: 90,
                            sortKey: { .number(Double($0.completed)) },
                            cell: { AnyView(NumberCell(text: "\($0.completed)", dimmed: $0.completed == 0)) }),
                StatsColumn(id: "cycle", title: "Cycle", help: "Median time in progress", width: 160,
                            sortKey: { .number($0.cycleTime.median ?? -1) },
                            cell: { AnyView(BarCell(value: $0.cycleTime.median, scale: scale)) }),
                StatsColumn(id: "wip", title: "In progress", help: "In progress right now", width: 100,
                            sortKey: { .number(Double($0.inProgress)) },
                            cell: { AnyView(NumberCell(text: "\($0.inProgress)", dimmed: $0.inProgress == 0)) }),
                StatsColumn(id: "notPlanned", title: "Not planned", help: "Closed as not planned in the window", width: 100,
                            sortKey: { .number(Double($0.notPlanned)) },
                            cell: { AnyView(NumberCell(text: "\($0.notPlanned)", dimmed: $0.notPlanned == 0)) }),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: { _ in }
        )
    }

    /// Over this page, or in a window of its own outside a main window.
    private func open(_ record: IssueRecord) {
        let reference = IssueReference(org: org, record: record)
        if let navigate { navigate(.issueReference(reference)) } else { openWindow(value: reference) }
    }
}

// MARK: - Charts

/// Total open issues over time, and issues opened and closed per period.
/// Two charts on one timeline rather than one with two y-axes: the total
/// runs in the hundreds, the per-period counts in the tens.
private struct OpenClosedCharts: View {
    let buckets: [IssueMetrics.Bucket]
    let granularity: IssueMetrics.Granularity
    @State private var hovered: Date?

    private var unit: Calendar.Component {
        switch granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .quarter: .quarter
        case .year: .year
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open issues").font(.headline)
                Chart {
                    ForEach(buckets) { bucket in
                        LineMark(x: .value("Period", bucket.start, unit: unit), y: .value("Open", bucket.openAtEnd))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(ChartPalette.aqua)
                        if hovered == bucket.start {
                            PointMark(x: .value("Period", bucket.start, unit: unit), y: .value("Open", bucket.openAtEnd))
                                .symbolSize(70)
                                .foregroundStyle(ChartPalette.aqua)
                        }
                    }
                    if let hovered {
                        RuleMark(x: .value("Period", hovered, unit: unit))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartXAxis { xAxis }
                .chartOverlay { proxy in hover(proxy) }
                .frame(height: 150)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Opened and closed").font(.headline)
                Chart {
                    ForEach(buckets) { bucket in
                        BarMark(x: .value("Period", bucket.start, unit: unit), y: .value("Issues", bucket.opened))
                            .foregroundStyle(by: .value("Series", "Opened"))
                            .position(by: .value("Series", "Opened"))
                            .cornerRadius(3)
                            .opacity(hovered == nil || hovered == bucket.start ? 1 : 0.4)
                        BarMark(x: .value("Period", bucket.start, unit: unit), y: .value("Issues", bucket.closed))
                            .foregroundStyle(by: .value("Series", "Closed"))
                            .position(by: .value("Series", "Closed"))
                            .cornerRadius(3)
                            .opacity(hovered == nil || hovered == bucket.start ? 1 : 0.4)
                    }
                }
                .chartForegroundStyleScale(["Opened": ChartPalette.blue, "Closed": ChartPalette.orange])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartXAxis { xAxis }
                .chartOverlay { proxy in hover(proxy) }
                .frame(height: 170)
            }
            tooltip
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
            AxisValueLabel(format: granularity.axisFormat)
        }
    }

    private func hover(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame,
                              let date: Date = proxy.value(atX: location.x - geometry[plotFrame].origin.x) else { return }
                        hovered = buckets.last { $0.start <= date }?.start
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered, let bucket = buckets.first(where: { $0.start == hovered }) {
            let label = switch granularity {
            case .day: bucket.start.formatted(date: .abbreviated, time: .omitted)
            case .week: "Week of \(bucket.start.formatted(.dateTime.day().month()))"
            case .month: bucket.start.formatted(.dateTime.month(.wide).year())
            case .quarter: bucket.start.formatted(.dateTime.quarter().year())
            case .year: bucket.start.formatted(.dateTime.year())
            }
            Text("\(label): \(bucket.opened) opened, \(bucket.closed) closed, \(bucket.openAtEnd) open at the end")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Hover for values. Closed counts completed and not planned alike.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct WIPChart: View {
    let points: [(day: Date, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In progress per day").font(.headline)
            Chart {
                ForEach(points, id: \.day) { point in
                    LineMark(x: .value("Day", point.day, unit: .day), y: .value("Issues", point.count))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(ChartPalette.blue)
                        .interpolationMethod(.stepCenter)
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .frame(height: 180)
            Text("Issues in an in-progress status at midday.").font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One dot per completed issue: when it closed and how long it was in
/// progress, with the median as a rule. Click a dot to open the issue.
private struct CycleScatter: View {
    let issues: [IssueTiming]
    let median: TimeInterval?
    let onOpen: (IssueRecord) -> Void
    @State private var hovered: IssueTiming?

    var body: some View {
        let points = issues.compactMap { timing in timing.cycleTime.map { (timing, timing.record.closedAt ?? .now, $0 / 86_400) } }
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(points, id: \.0.id) { timing, closed, days in
                    PointMark(x: .value("Closed", closed), y: .value("Days", days))
                        .symbolSize(hovered?.id == timing.id ? 90 : 40)
                        .foregroundStyle(ChartPalette.blue.opacity(hovered == nil || hovered?.id == timing.id ? 0.9 : 0.35))
                }
                if let median {
                    RuleMark(y: .value("Median", median / 86_400))
                        .foregroundStyle(ChartPalette.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Median \(median.compactDuration)").font(.caption).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxisLabel("Days in progress")
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = nearest(location, proxy: proxy, geometry: geometry, points: points)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            if let timing = nearest(location, proxy: proxy, geometry: geometry, points: points) { onOpen(timing.record) }
                        }
                }
            }
            .frame(height: 220)
            if let hovered {
                Text("\(hovered.record.repo)#\(String(hovered.record.number)) \(hovered.record.title) · \(hovered.cycleTime?.compactDuration ?? "-") in progress")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Each dot is a completed issue. Hover for detail, click to open it in a new window.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func nearest(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, points: [(IssueTiming, Date, Double)]) -> IssueTiming? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        return points
            .compactMap { timing, closed, days -> (IssueTiming, CGFloat)? in
                guard let x = proxy.position(forX: closed), let y = proxy.position(forY: days) else { return nil }
                return (timing, hypot(x - local.x, y - local.y))
            }
            .filter { $0.1 < 12 }
            .min { $0.1 < $1.1 }?.0
    }
}
