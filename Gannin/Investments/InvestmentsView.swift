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

    let org: String
    let team: Team?
    @Binding var selection: DetailSelection?

    /// Swarmia's rule of thumb for a balance worth reading.
    private static let categorisedTarget = 0.8

    private var range: DateInterval {
        rangePreset.interval(customFrom: Date(timeIntervalSince1970: customFrom), customTo: Date(timeIntervalSince1970: customTo))
    }

    var body: some View {
        let range = range
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let history = store.history(for: org), history.coveredFrom <= range.start || !store.syncing.contains(org) {
                    let balance = InvestmentBalance(history: history, config: configs.config(for: org), team: team, range: range, granularity: period)
                    Section {
                        summary(balance).sectionContent()
                    } header: {
                        PinnedHeader { header }
                    }
                    if scope == .completed {
                        Section {
                            InvestmentChart(balance: balance, period: period, selected: $selectedBucket)
                                .sectionContent()
                        } header: {
                            PinnedHeader { Text("Completed per \(period.rawValue.lowercased())") }
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
                } else {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Fetching issues back to \(range.start.formatted(date: .abbreviated, time: .omitted)).").foregroundStyle(.secondary)
                        }
                        .sectionContent()
                    } header: {
                        PinnedHeader { header }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(org) \(Int(range.start.timeIntervalSince1970))") {
            let days = max(1, Int(Date.now.timeIntervalSince(range.start) / 86_400) + 1)
            await store.sync(org, windowDays: days)
        }
        .onChange(of: period) { selectedBucket = nil }
        .onChange(of: rangePreset) { selectedBucket = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Investment balance")
            if store.syncing.contains(org) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating").font(.callout.weight(.regular)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Group {
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
                        ForEach([IssueMetrics.Granularity.week, .month, .quarter]) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .font(.body)
            .controlSize(.small)
        }
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
                ForEach(shares) { share in
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
        let drill = MetricDrill.investment(InvestmentBalance.Drill(
            key: share.key, scope: scope, range: balance.range, period: period,
            bucket: scope == .completed ? selectedBucket : nil,
            title: "\(share.name) · \(scope.rawValue.lowercased())"
        ))
        let isSelected = selection == .metric(drill)
        return Button {
            selection = .metric(drill)
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
                Image(systemName: "chevron.right")
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
            Text("\(share.issues.count) issues didn't match a rule. \(unlabelled) have no labels, type or board fields. Add rules in Settings, or right-click an issue to categorise it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 40) {
                group("By repository", Array(byRepo))
                if !byLabel.isEmpty { group("By label", Array(byLabel)) }
            }
            Button("Show Uncategorised Issues") {
                selection = .metric(.investment(InvestmentBalance.Drill(
                    key: .uncategorised, scope: scope, range: balance.range, period: period,
                    bucket: scope == .completed ? selectedBucket : nil,
                    title: "Uncategorised · \(scope.rawValue.lowercased())"
                )))
            }
            .buttonStyle(.link)
        }
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
    @Binding var selected: Date?
    @State private var hovered: Date?

    private struct Point: Identifiable {
        let start: Date
        let name: String
        let count: Int
        var id: String { "\(start.timeIntervalSince1970)-\(name)" }
    }

    private var unit: Calendar.Component {
        switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .quarter: .quarter
        }
    }

    static func label(_ bucket: InvestmentBalance.Bucket, period: IssueMetrics.Granularity) -> String {
        switch period {
        case .week: "the week of \(bucket.start.formatted(.dateTime.day().month()))"
        case .month: bucket.start.formatted(.dateTime.month(.wide).year())
        case .quarter: bucket.start.formatted(.dateTime.quarter().year())
        case .day: bucket.start.formatted(date: .abbreviated, time: .omitted)
        }
    }

    var body: some View {
        let points = balance.buckets.flatMap { bucket in
            balance.categories.map { Point(start: bucket.start, name: $0.name, count: bucket.count($0.key)) }
        }
        let focus = hovered ?? selected
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { point in
                BarMark(x: .value("Period", point.start, unit: unit), y: .value("Issues", point.count))
                    .foregroundStyle(by: .value("Category", point.name))
                    .opacity(focus == nil || focus == point.start ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: balance.categories.map(\.name), range: balance.categories.map { ChartPalette.slot($0.slot) })
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
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
                let parts = balance.categories.filter { bucket.count($0.key) > 0 }.map { "\($0.name) \(bucket.count($0.key))" }
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

/// An issue's investment category: by hand, or back to the rules.
struct CategoriseMenu: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.currentOrg) private var currentOrg
    let issueID: String
    /// For windows outside the column browser, which has no current org.
    var org: String?

    var body: some View {
        if let org = org ?? currentOrg {
            let config = configs.config(for: org).investmentConfig
            Picker("Investment category", selection: Binding(
                get: { config.manual[issueID] },
                set: { configs.setCategory($0, for: issueID, in: org) }
            )) {
                Text("Use Rules").tag(UUID?.none)
                Divider()
                ForEach(config.categories) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
            .pickerStyle(.menu)
        }
    }
}
