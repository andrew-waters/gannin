import Charts
import SwiftUI

extension EnvironmentValues {
    /// The org the column browser is showing, for rows that act on its config.
    @Entry var currentOrg: String?
}

/// The Investments page: how merged work splits across investment
/// categories over the chosen window.
struct InvestmentsView: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(MetricsStore.self) private var store
    @AppStorage("investmentUnit") private var unit: InvestmentUnit = .days
    @AppStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    /// Swarmia's rule of thumb for a balance worth reading.
    private static let categorisedTarget = 0.8

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let metrics {
                    let balance = InvestmentBalance(metrics: metrics, config: configs.config(for: org).investmentConfig)
                    Section {
                        summary(balance).sectionContent()
                    } header: {
                        PinnedHeader {
                            HStack(spacing: 12) {
                                Text("Investment balance")
                                Spacer(minLength: 8)
                                Picker("Measure", selection: $unit) {
                                    ForEach(InvestmentUnit.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                                .font(.body)
                                .help(unit.help)
                            }
                        }
                    }
                    Section {
                        InvestmentWeeklyChart(balance: balance, unit: unit, selection: $selection)
                            .sectionContent()
                    } header: {
                        PinnedHeader { Text("By week") }
                    }
                    if let uncategorised = balance.shares.last, !uncategorised.pullRequests.isEmpty {
                        Section {
                            uncategorisedGroups(uncategorised).sectionContent()
                        } header: {
                            PinnedHeader { Text("Uncategorised") }
                        }
                    }
                } else {
                    Group {
                        if store.syncing.contains(org) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Fetching merged PRs for the last \(windowDays) days.").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No metrics yet.").foregroundStyle(.secondary)
                        }
                    }
                    .sectionContent()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Summary

    private func summary(_ balance: InvestmentBalance) -> some View {
        let total = balance.total(unit)
        let categorised = balance.categorised(unit)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text("\(categorised.formatted(.percent.precision(.fractionLength(0)))) categorised")
                    .font(.callout.weight(.medium))
                if total > 0 && categorised < Self.categorisedTarget {
                    Text("· aim for 80% or more for a balance worth reading")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ShareBar(shares: balance.shares, unit: unit)
            VStack(spacing: 0) {
                ForEach(balance.shares) { share in
                    shareRow(share, total: total)
                    Divider()
                }
            }
        }
    }

    private func shareRow(_ share: InvestmentBalance.Share, total: Double) -> some View {
        let value = share.value(unit)
        let isSelected = selection == .metric(.investment(share.key.drillID, share.name))
        return Button {
            selection = .metric(.investment(share.key.drillID, share.name))
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChartPalette.slot(share.slot))
                    .frame(width: 12, height: 12)
                Text(share.name)
                Spacer(minLength: 8)
                Text(Self.format(value, unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(total > 0 ? (value / total).formatted(.percent.precision(.fractionLength(0))) : "-")
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
        .help("\(share.pullRequests.count) merged PRs, about \(Self.format(share.days, .days))")
    }

    static func format(_ value: Double, _ unit: InvestmentUnit) -> String {
        switch unit {
        case .days: "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))) d"
        case .pullRequests: "\(Int(value)) PRs"
        }
    }

    // MARK: Uncategorised

    /// The biggest pockets of uncategorised work, to show which rules would
    /// help most.
    private func uncategorisedGroups(_ share: InvestmentBalance.Share) -> some View {
        let byRepo = Dictionary(grouping: share.pullRequests, by: \.repo)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        let labels = share.pullRequests.flatMap(\.labels)
        let byLabel = Dictionary(grouping: labels, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        let unlabelled = share.pullRequests.filter { $0.labels.isEmpty && $0.linkedIssues.isEmpty }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(share.pullRequests.count) merged PRs didn't match a rule. \(unlabelled) have no labels or linked issues. Add rules in Settings, or right-click a PR to categorise it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 40) {
                group("By repository", Array(byRepo))
                if !byLabel.isEmpty {
                    group("By label", Array(byLabel))
                }
            }
            Button("Show uncategorised PRs") {
                selection = .metric(.investment(share.key.drillID, share.name))
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
    let unit: InvestmentUnit

    var body: some View {
        let visible = shares.filter { $0.value(unit) > 0 }
        let total = visible.map { $0.value(unit) }.reduce(0, +)
        GeometryReader { geometry in
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { share in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ChartPalette.slot(share.slot))
                        .frame(width: max(2, (geometry.size.width - gaps) * share.value(unit) / max(total, 1)))
                        .help("\(share.name): \(InvestmentsView.format(share.value(unit), unit))")
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(visible.map { "\($0.name) \(InvestmentsView.format($0.value(unit), unit))" }.joined(separator: ", "))
    }
}

// MARK: - Weekly chart

private struct InvestmentWeeklyChart: View {
    let balance: InvestmentBalance
    let unit: InvestmentUnit
    @Binding var selection: DetailSelection?
    @State private var hovered: Date?

    private struct Point: Identifiable {
        let week: Date
        let name: String
        let value: Double
        var id: String { "\(week.timeIntervalSince1970)-\(name)" }
    }

    var body: some View {
        let points = balance.weeks.flatMap { week in
            balance.shares.map { Point(week: week.start, name: $0.name, value: week.value($0.key, unit)) }
        }
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { point in
                BarMark(
                    x: .value("Week", point.week, unit: .weekOfYear),
                    y: .value(unit.rawValue, point.value)
                )
                .foregroundStyle(by: .value("Category", point.name))
                .opacity(hovered == nil || hovered == point.week ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: balance.shares.map(\.name), range: balance.shares.map { ChartPalette.slot($0.slot) })
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: balance.weeks.count > 8 ? 2 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in
                WeekHoverOverlay(proxy: proxy, weeks: balance.weeks.map(\.start), hovered: $hovered) { week in
                    selection = .metric(.week(week))
                }
            }
            .frame(height: 200)
            tooltip
        }
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered, let week = balance.weeks.first(where: { $0.start == hovered }) {
            let parts = balance.shares
                .map { ($0.name, week.value($0.key, unit)) }
                .filter { $0.1 > 0 }
                .map { "\($0.0) \(InvestmentsView.format($0.1, unit))" }
            Text("Week of \(week.start.formatted(.dateTime.day().month())): \(parts.isEmpty ? "nothing merged" : parts.joined(separator: ", "))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Hover a week for values, click to see its merged PRs.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Categorise menu

/// "Categorise" for a merged PR's context menu: a category by hand, or back
/// to the rules.
struct CategoriseMenu: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.currentOrg) private var org
    let prID: String

    var body: some View {
        if let org {
            let config = configs.config(for: org).investmentConfig
            Picker("Categorise", selection: Binding(
                get: { config.manual[prID] },
                set: { configs.setCategory($0, for: prID, in: org) }
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
