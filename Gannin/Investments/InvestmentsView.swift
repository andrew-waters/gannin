import Charts
import SwiftUI

extension EnvironmentValues {
    /// The org the column browser is showing, for rows that act on its config.
    @Entry var currentOrg: String?
}

/// The Investments page: issues by investment category over a range, those
/// completed in it and those in progress at its end, by week, month or quarter.
struct InvestmentsView: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var store
    @SceneStorage("investmentScope") private var scope: InvestmentBalance.Scope = .completed
    @SceneStorage("investmentRange") private var rangePreset: InvestmentRange = .last90
    @SceneStorage("investmentFrom") private var customFrom: Double = Date.now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970
    @SceneStorage("investmentTo") private var customTo: Double = Date.now.timeIntervalSince1970
    @SceneStorage("investmentPeriod") private var period: IssueMetrics.Granularity = .week
    /// A bucket clicked in the chart; nil shows the whole range.
    @State private var selectedBucket: Date?
    /// The category whose issues are listed on the page.
    @State private var shown: InvestmentBalance.Key?
    @AppStorage("investmentChartValues") private var chartValues: ChartValues = .count

    enum ChartValues: String, CaseIterable {
        case count = "Count"
        case share = "Share"
    }
    /// Issues being assigned to categories one at a time.
    @State private var triage: InvestmentTriage.Queue?
    @Environment(\.openWindow) private var openWindow

    let org: String
    let team: Team?
    @Binding var selection: DetailSelection?

    /// Swarmia's rule of thumb for a balance worth reading.
    private static let categorisedTarget = 0.8

    private var range: DateInterval {
        rangePreset.interval(customFrom: Date(timeIntervalSince1970: customFrom), customTo: Date(timeIntervalSince1970: customTo), earliest: store.earliestIssue(org))
    }

    var body: some View {
        let range = range
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let history = store.history(for: org), history.coveredFrom <= range.start || !store.syncing.contains(org) {
                    let balance = InvestmentBalance(history: history, config: configs.config(for: org), team: team, range: range, granularity: period)
                    Section {
                        summary(balance).sectionContent()
                    }
                    if scope == .completed {
                        Section {
                            InvestmentChart(balance: balance, period: period, asShare: chartValues == .share, selected: $selectedBucket)
                                .sectionContent()
                        } header: {
                            PinnedHeader {
                                HStack(spacing: 12) {
                                    Text("Completed per \(period.rawValue.lowercased())")
                                    Spacer(minLength: 8)
                                    Picker("Show", selection: $chartValues) {
                                        ForEach(ChartValues.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .fixedSize()
                                    .font(.body)
                                    .help("Issues per category, or each category's share of the period")
                                }
                            }
                        }
                    }
                    let shares = scope == .completed ? balance.completed(in: selectedBucket) : balance.inProgress
                    if let uncategorised = shares.last, !uncategorised.issues.isEmpty {
                        Section {
                            uncategorisedGroups(uncategorised, balance: balance).sectionContent()
                        } header: {
                            PinnedHeader { Text("Uncategorised") }
                        }
                    }
                    if let shown, let share = shares.first(where: { $0.key == shown }), shown != .uncategorised || !share.issues.isEmpty {
                        Section {
                            issueList(share)
                        } header: {
                            PinnedHeader {
                                HStack(spacing: 12) {
                                    Text("\(share.name) · \(scope.rawValue.lowercased())")
                                    Text("\(share.issues.count)").foregroundStyle(.secondary).fontWeight(.regular)
                                    Spacer(minLength: 8)
                                    Group {
                                        Button("Assign to Categories") { startTriage(share.issues) }
                                            .disabled(share.issues.isEmpty)
                                        Button { self.shown = nil } label: { Image(systemName: "xmark") }
                                            .buttonStyle(.borderless)
                                            .help("Close the list")
                                    }
                                    .font(.body)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Fetching issues back to \(range.start.formatted(date: .abbreviated, time: .omitted)).").foregroundStyle(.secondary)
                        }
                        .sectionContent()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup { controls }
        }
        .sheet(item: $triage) { queue in
            InvestmentTriage(org: org, queue: queue)
        }
        .task(id: "\(org) \(Int(range.start.timeIntervalSince1970))") {
            let days = max(1, Int(Date.now.timeIntervalSince(range.start) / 86_400) + 1)
            await store.sync(org, windowDays: days)
        }
        .task(id: "\(org) \(rangePreset.rawValue)") {
            if rangePreset == .allTime { await store.loadEarliestIssue(org) }
        }
        .onChange(of: rangePreset) {
            // Years only make sense over all time; weeks don't.
            if !periods.contains(period) { period = rangePreset == .allTime ? .quarter : .week }
        }
        .onChange(of: period) { selectedBucket = nil }
        .onChange(of: rangePreset) { selectedBucket = nil }
    }

    // MARK: Header

    /// In the toolbar, beside the window's title.
    @ViewBuilder
    private var controls: some View {
        if store.syncing.contains(org) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating").font(.callout).foregroundStyle(.secondary)
            }
        }
        Picker("Show", selection: $scope) {
            ForEach(InvestmentBalance.Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Issues completed in the range, or in progress at its end")
        Picker("Range", selection: $rangePreset) {
            ForEach(InvestmentRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        if rangePreset == .custom {
            DatePicker("From", selection: date($customFrom), displayedComponents: .date)
                .labelsHidden()
            Text("to").foregroundStyle(.secondary)
            DatePicker("To", selection: date($customTo), in: ...Date.now, displayedComponents: .date)
                .labelsHidden()
        }
        if scope == .completed {
            Picker("Per", selection: $period) {
                ForEach(periods) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var periods: [IssueMetrics.Granularity] {
        rangePreset == .allTime ? [.week, .month, .quarter, .year] : [.week, .month, .quarter]
    }

    private func date(_ seconds: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: seconds.wrappedValue) }, set: { seconds.wrappedValue = $0.timeIntervalSince1970 })
    }

    // MARK: Summary

    private func summary(_ balance: InvestmentBalance) -> some View {
        let shares = scope == .completed ? balance.completed(in: selectedBucket) : balance.inProgress
        let total = shares.map(\.issues.count).reduce(0, +)
        let uncategorised = shares.last?.issues.count ?? 0
        let categorised = total == 0 ? 0 : Double(total - uncategorised) / Double(total)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text(headline(total: total, balance: balance))
                    .font(.callout.weight(.medium))
                Text("· \(categorised.formatted(.percent.precision(.fractionLength(0)))) categorised")
                    .font(.callout)
                if total > 0 && categorised < Self.categorisedTarget {
                    Text("· aim for 80% or more").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedBucket != nil && scope == .completed {
                    Button("Whole Range") { selectedBucket = nil }
                        .controlSize(.small)
                }
            }
            ShareBar(shares: shares)
            VStack(spacing: 0) {
                // Uncategorised only when something is.
                ForEach(shares.filter { $0.key != .uncategorised || !$0.issues.isEmpty }) { share in
                    shareRow(share, total: total, balance: balance)
                    Divider()
                }
            }
        }
    }

    private func headline(total: Int, balance: InvestmentBalance) -> String {
        let issues = total == 1 ? "1 issue" : "\(total) issues"
        switch scope {
        case .completed:
            if let selectedBucket, let bucket = balance.buckets.first(where: { $0.start == selectedBucket }) {
                return "\(issues) completed in \(InvestmentChart.label(bucket, period: period))"
            }
            return "\(issues) completed, \(balance.range.start.formatted(date: .abbreviated, time: .omitted)) to \(balance.range.end.formatted(date: .abbreviated, time: .omitted))"
        case .inProgress:
            let isNow = balance.range.end >= Date.now.addingTimeInterval(-60)
            return "\(issues) in progress \(isNow ? "now" : "on \(balance.range.end.formatted(date: .abbreviated, time: .omitted))")"
        }
    }

    private func shareRow(_ share: InvestmentBalance.Share, total: Int, balance: InvestmentBalance) -> some View {
        let isSelected = shown == share.key
        return Button {
            shown = isSelected ? nil : share.key
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChartPalette.slot(share.slot))
                    .frame(width: 12, height: 12)
                Text(share.name)
                Spacer(minLength: 8)
                Text(share.issues.count == 1 ? "1 issue" : "\(share.issues.count) issues")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(total > 0 ? (Double(share.issues.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))) : "-")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Uncategorised

    private func uncategorisedGroups(_ share: InvestmentBalance.Share, balance: InvestmentBalance) -> some View {
        let byRepo = Dictionary(grouping: share.issues, by: { $0.repo.split(separator: "/").last.map(String.init) ?? $0.repo })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        let byLabel = Dictionary(grouping: share.issues.flatMap(\.labels), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        let unlabelled = share.issues.filter { $0.labels.isEmpty && $0.issueType == nil && $0.projectFields.isEmpty }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text(uncategorisedText(share.issues.count, unlabelled: unlabelled))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 40) {
                group("By repository", Array(byRepo))
                if !byLabel.isEmpty { group("By label", Array(byLabel)) }
            }
            HStack(spacing: 12) {
                Button("Assign to Categories") { startTriage(share.issues) }
                    .buttonStyle(.borderedProminent)
                    .help("Go through them one at a time and choose each one's category")
                Button(shown == .uncategorised ? "Hide Issues" : "Show Issues") {
                    shown = shown == .uncategorised ? nil : .uncategorised
                }
            }
        }
    }

    private func uncategorisedText(_ count: Int, unlabelled: Int) -> String {
        let tracking = configs.config(for: org).investmentConfig.trackedBy
        switch tracking {
        case .gannin:
            return "\(count) issues didn't match a rule. \(unlabelled) have no labels, type or board fields. Add rules in Settings, or assign them here."
        case .labels:
            return "\(count) issues have none of the categories' labels, and nor does their parent. Assigning them adds the label on GitHub."
        case .projectField(_, let project, let field):
            return "\(count) issues have no category in \(field) on \(project), and nor does their parent. Assigning them sets it on GitHub."
        }
    }

    private func startTriage(_ issues: [IssueRecord]) {
        triage = InvestmentTriage.Queue(issues: issues.sorted { ($0.closedAt ?? .distantFuture) > ($1.closedAt ?? .distantFuture) })
    }

    // MARK: Issues

    /// The shown category's issues, newest completed first; click one to open
    /// it, right-click to change its category.
    private func issueList(_ share: InvestmentBalance.Share) -> some View {
        let records = share.issues.sorted { ($0.closedAt ?? .distantFuture) > ($1.closedAt ?? .distantFuture) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(records) { record in
                Button {
                    openWindow(value: IssueReference(org: org, record: record))
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(record.repo)#\(record.number)")
                                if let closedAt = record.closedAt {
                                    Text("· completed")
                                    RelativeDate(date: closedAt)
                                } else {
                                    Text("· open")
                                }
                                if !record.labels.isEmpty {
                                    Text("· \(record.labels.prefix(3).joined(separator: ", "))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        AvatarStack(people: record.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    CategoriseMenu(issueID: record.id, org: org)
                    Link("Open on GitHub", destination: record.url)
                }
                Divider()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }

    private func group(_ title: String, _ rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, count in
                HStack(spacing: 12) {
                    Text(name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(width: 280)
            }
        }
    }
}

// MARK: - Share bar

/// One horizontal bar split by category, with a 2pt gap between segments.
private struct ShareBar: View {
    let shares: [InvestmentBalance.Share]

    var body: some View {
        let visible = shares.filter { !$0.issues.isEmpty }
        let total = visible.map(\.issues.count).reduce(0, +)
        GeometryReader { geometry in
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { share in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ChartPalette.slot(share.slot))
                        .frame(width: max(2, (geometry.size.width - gaps) * CGFloat(share.issues.count) / CGFloat(max(total, 1))))
                        .help("\(share.name): \(share.issues.count)")
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(visible.map { "\($0.name) \($0.issues.count)" }.joined(separator: ", "))
    }
}

// MARK: - Chart

/// Completed issues per period, stacked by category. Click a period to see
/// its breakdown above; click it again for the whole range.
private struct InvestmentChart: View {
    let balance: InvestmentBalance
    let period: IssueMetrics.Granularity
    /// Each category as a percentage of its period, rather than a count.
    let asShare: Bool
    @Binding var selected: Date?
    @State private var hovered: Date?

    private struct Point: Identifiable {
        let start: Date
        let name: String
        let count: Int
        /// Percent of the period's issues.
        let share: Double
        var id: String { "\(start.timeIntervalSince1970)-\(name)" }
    }

    private var unit: Calendar.Component {
        switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .quarter: .quarter
        case .year: .year
        }
    }

    /// The categories to draw and list in the legend: Uncategorised only
    /// when some period has any.
    private var categories: [(key: InvestmentBalance.Key, name: String, slot: Int?)] {
        balance.categories.filter { category in
            category.key != .uncategorised || balance.buckets.contains { $0.count(category.key) > 0 }
        }
    }

    /// The middle of each period (thinned to about ten), where its bar is
    /// drawn, so every label sits under its bar.
    private var axisValues: [Date] {
        let starts = balance.buckets.map(\.start)
        let stride = max(1, Int((Double(starts.count) / 10).rounded(.up)))
        return starts.enumerated().filter { $0.offset % stride == 0 }.map { _, start in
            start.addingTimeInterval(period.next(after: start).timeIntervalSince(start) / 2)
        }
    }

    static func label(_ bucket: InvestmentBalance.Bucket, period: IssueMetrics.Granularity) -> String {
        let name = switch period {
        case .year: bucket.start.formatted(.dateTime.year())
        case .week: "the week of \(bucket.start.formatted(.dateTime.day().month()))"
        case .month: bucket.start.formatted(.dateTime.month(.wide).year())
        case .quarter: bucket.start.formatted(.dateTime.quarter().year())
        case .day: bucket.start.formatted(date: .abbreviated, time: .omitted)
        }
        // The current period runs to today.
        return bucket.end > .now ? "\(name) so far" : name
    }

    var body: some View {
        let points = balance.buckets.flatMap { bucket in
            let total = balance.categories.map { bucket.count($0.key) }.reduce(0, +)
            return categories.map { category in
                let count = bucket.count(category.key)
                return Point(start: bucket.start, name: category.name, count: count, share: total > 0 ? Double(count) / Double(total) * 100 : 0)
            }
        }
        let focus = hovered ?? selected
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { point in
                BarMark(x: .value("Period", point.start, unit: unit), y: asShare ? .value("Share", point.share) : .value("Issues", Double(point.count)))
                    .foregroundStyle(by: .value("Category", point.name))
                    .opacity(focus == nil || focus == point.start ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: categories.map(\.name), range: categories.map { ChartPalette.slot($0.slot) })
            .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
            .chartYScale(domain: asShare ? 0...100 : 0...Double(max(1, balance.buckets.map { bucket in balance.categories.map { bucket.count($0.key) }.reduce(0, +) }.max() ?? 1)))
            .chartYAxis {
                if asShare {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { Text("\(value.as(Double.self).map { Int($0) } ?? 0)%") }
                    }
                } else {
                    AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() }
                }
            }
            .chartXAxis {
                // One label per period (thinned to about ten), so a quarter
                // isn't labelled once per month.
                AxisMarks(values: axisValues) { _ in
                    AxisValueLabel(format: period.axisFormat)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = bucket(at: location, proxy: proxy, geometry: geometry)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            let bucket = bucket(at: location, proxy: proxy, geometry: geometry)
                            selected = selected == bucket ? nil : bucket
                        }
                }
            }
            .frame(height: 220)
            if let focus, let bucket = balance.buckets.first(where: { $0.start == focus }) {
                let total = balance.categories.map { bucket.count($0.key) }.reduce(0, +)
                let parts = balance.categories.filter { bucket.count($0.key) > 0 }.map { category in
                    asShare
                        ? "\(category.name) \((Double(bucket.count(category.key)) / Double(max(total, 1))).formatted(.percent.precision(.fractionLength(0))))"
                        : "\(category.name) \(bucket.count(category.key))"
                }
                Text("\(Self.label(bucket, period: period).prefix(1).uppercased() + Self.label(bucket, period: period).dropFirst()): \(parts.isEmpty ? "nothing completed" : parts.joined(separator: ", "))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover a period for values, click it to see its breakdown above.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func bucket(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame,
              let date: Date = proxy.value(atX: location.x - geometry[plotFrame].origin.x) else { return nil }
        return balance.buckets.last { $0.start <= date }?.start
    }
}

// MARK: - Categorise menu

/// An issue's investment category, as the org tracks it: chosen in Gannin
/// (or back to the rules), or its label or board option on GitHub, which the
/// window confirms before writing.
struct CategoriseMenu: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(InvestmentPrompt.self) private var prompt: InvestmentPrompt?
    @Environment(\.currentOrg) private var currentOrg
    let issueID: String
    /// For windows outside the column browser, which has no current org.
    var org: String?

    var body: some View {
        if let org = org ?? currentOrg, let history = issueStore.history(for: org), let issue = history.issues[issueID] {
            let config = configs.config(for: org).investmentConfig
            let tracking = config.trackedBy
            let current = tracking.writesToGitHub
                ? config.tracked(issue)?.id
                : config.manual[issueID]
            Picker("Investment category", selection: Binding(
                get: { current },
                set: { id in
                    let category = id.flatMap(config.category(id:))
                    if let prompt {
                        prompt.assign([issue], to: category, org: org, configs: configs)
                    } else if !tracking.writesToGitHub {
                        configs.setCategory(id, for: issueID, in: org)
                    }
                }
            )) {
                Text(tracking.writesToGitHub ? "None" : "Use Rules").tag(UUID?.none)
                Divider()
                ForEach(config.categories) { category in
                    Text(category.name).tag(Optional(category.id))
                        .disabled(tracking.writesToGitHub && (category.githubValue ?? "").isEmpty)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
