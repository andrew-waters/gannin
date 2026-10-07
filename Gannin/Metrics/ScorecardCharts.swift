import Charts
import SwiftUI

/// Each measurable's last whole period as a tile: its value, the change,
/// and the periods before as an area along the bottom, coloured by target.
struct ScorecardTiles: View {
    let measurables: [Measurable]
    /// Newest first, the one under way at the front, a dozen or so back.
    let data: Scorecard.Data
    let resolution: ScorecardResolution

    var body: some View {
        let headlines = measurables.map { ScorecardHeadline(measurable: $0, data: data, resolution: resolution) }
        EvenGrid(minWidth: 190, spacing: 12) {
            ForEach(headlines) { headline in
                ScorecardHeadlineTile(headline: headline)
            }
        }
    }
}

/// What a tile shows of a measurable's last whole period.
struct ScorecardHeadline: Identifiable {
    let measurable: Measurable
    let current: Scorecard.Cell?
    let period: DateInterval?
    let previous: Scorecard.Cell?
    let previousPeriod: DateInterval?
    let resolution: ScorecardResolution
    /// The whole periods before it, oldest first, for sparklines.
    let points: [ScorecardPoint]

    var id: UUID { measurable.id }

    init(measurable: Measurable, data: Scorecard.Data, resolution: ScorecardResolution) {
        self.measurable = measurable
        self.resolution = resolution
        let cells = data.cells(for: measurable)
        current = cells.count > 1 ? cells[1] : nil
        period = data.periods.count > 1 ? data.periods[1] : nil
        // By day, the same day last week, so a Monday isn't held to a Sunday.
        let back = resolution == .day ? 8 : 2
        previous = cells.count > back ? cells[back] : nil
        previousPeriod = data.periods.count > back ? data.periods[back] : nil
        points = ScorecardPoint.whole(measurable, data: data)
    }

    var value: Double? { current?.value }
    var valueText: String { value.map(measurable.format) ?? "-" }
    var met: Bool? { current?.meets(measurable) }
    var goal: Double? { current.flatMap { $0.judges ? measurable.goal(share: $0.share) : nil } }

    var statusText: String {
        switch met {
        case true?: "On target"
        case false?: "Off target"
        case nil: measurable.target == nil ? "No target" : current?.judges == false ? "Not judged" : "Nothing yet"
        }
    }

    /// `≥ 2 a day` for a count, `≤ 500` for a median or a rate.
    var targetText: String? {
        let text = current.flatMap { measurable.targetText(share: $0.share) }
        return measurable.metric?.accumulates == true ? text.map { "\($0) a \(resolution.noun)" } : text
    }

    /// On the comparison period, coloured only when off target.
    var change: StatChange? {
        guard let now = current?.value, let before = previous?.value else { return nil }
        let higherIsWorse = measurable.target == nil || met != false ? nil : measurable.comparison == .atMost
        if measurable.effectiveUnit == .percent {
            return StatChange.points(now / 100, before / 100, higherIsWorse: higherIsWorse ?? false)
                .map { higherIsWorse == nil ? StatChange(text: $0.text, isWorse: nil) : $0 }
        }
        return StatChange.percent(now, before, higherIsWorse: higherIsWorse)
    }

    /// `↓ 11% on last Mon`.
    var changeText: String? {
        guard let change, let previousPeriod else { return nil }
        let arrow = change.text.hasPrefix("+") ? "↑ " : change.text.hasPrefix("-") ? "↓ " : ""
        let amount = change.text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        return "\(arrow)\(amount) on \(comparison(previousPeriod))"
    }

    private func comparison(_ period: DateInterval) -> String {
        switch resolution {
        case .day: "last \(period.start.formatted(.dateTime.weekday(.abbreviated)))"
        case .week: "the week before"
        case .month: period.start.formatted(.dateTime.month(.wide))
        case .quarter, .year: resolution.heading(period)
        }
    }

    /// `Yesterday`, `29 Sep to 5 Oct`.
    var periodText: String {
        guard let period else { return "" }
        return resolution == .day && Calendar.metrics.isDateInYesterday(period.start) ? "Yesterday" : resolution.label(period)
    }
}

/// A goal's tile. Whether it's on target is in the line's colours (and
/// the tooltip), so there's no status badge.
struct ScorecardHeadlineTile: View {
    let headline: ScorecardHeadline
    /// The period under the pointer, which the tile shows instead.
    @State private var hovered: Date?

    var body: some View {
        let point = hovered.flatMap { date in headline.points.last { $0.start <= date } }
        VStack(alignment: .leading, spacing: 2) {
            Text(headline.measurable.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(point.map { headline.measurable.format($0.value) } ?? headline.valueText)
                    .font(.title.weight(.semibold).monospacedDigit())
                if point == nil {
                    ChangeLabel(change: headline.change).font(.callout.weight(.medium))
                }
            }
            Group {
                Text(caption(point))
                if let target = headline.targetText {
                    Text("Target \(target)")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            Spacer(minLength: 0)
            ScorecardSparkline(points: headline.points, goal: headline.goal, filled: true, hovered: $hovered)
                .frame(height: 44)
                .padding(.horizontal, -14)
                .padding(.bottom, -14)
        }
        .frame(height: 150, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help([headline.statusText, headline.changeText].compactMap { $0 }.joined(separator: ", "))
    }

    /// The period, or the hovered period and how it did.
    private func caption(_ point: ScorecardPoint?) -> String {
        guard let point else { return headline.periodText }
        let resolution = headline.resolution
        let period = resolution.label(DateInterval(start: point.start, end: resolution.adding(1, to: point.start)))
        return [period, point.met.map { $0 ? "on target" : "off target" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A period's value, for trend lines and sparklines.
struct ScorecardPoint: Hashable {
    let start: Date
    let value: Double
    /// Against the target held to the period; nil with none.
    var met: Bool?
    var goal: Double?

    /// Whole periods with a value, oldest first.
    static func whole(_ measurable: Measurable, data: Scorecard.Data) -> [ScorecardPoint] {
        zip(data.periods, data.cells(for: measurable)).dropFirst().compactMap { period, cell in
            guard cell.covered, let value = cell.value else { return nil }
            return ScorecardPoint(start: period.start, value: value, met: cell.meets(measurable), goal: cell.judges ? measurable.goal(share: cell.share) : nil)
        }
        .reversed()
    }

    /// Runs on one side of the target, split where the line crosses it, so
    /// each is one colour.
    static func runs(_ points: [ScorecardPoint], goal: Double?) -> [(points: [ScorecardPoint], color: Color)] {
        func color(_ met: Bool?) -> Color { met.map { $0 ? ChartPalette.good : ChartPalette.critical } ?? ChartPalette.blue }
        guard let target = goal, let first = points.first else { return [(points, ChartPalette.blue)] }
        var runs: [(points: [ScorecardPoint], color: Color)] = [([first], color(first.met))]
        for (previous, point) in zip(points, points.dropFirst()) {
            if (previous.met ?? true) != (point.met ?? true), previous.value != point.value {
                let fraction = (target - previous.value) / (point.value - previous.value)
                let crossing = ScorecardPoint(start: previous.start.addingTimeInterval(point.start.timeIntervalSince(previous.start) * fraction), value: target)
                runs[runs.count - 1].points.append(crossing)
                runs.append(([crossing, point], color(point.met)))
            } else {
                runs[runs.count - 1].points.append(point)
            }
        }
        return runs
    }
}

/// A run of whole periods, no axes, green on target and red off it.
struct ScorecardSparkline: View {
    let points: [ScorecardPoint]
    let goal: Double?
    var filled = false
    /// With a binding, hovering marks a period and sets it.
    var hovered: Binding<Date?>?

    var body: some View {
        let runs = ScorecardPoint.runs(points, goal: goal)
        Chart {
            if filled {
                ForEach(points, id: \.start) { point in
                    AreaMark(x: .value("Period", point.start), y: .value("Value", point.value))
                        .foregroundStyle(ChartPalette.blue.opacity(0.12))
                }
            }
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                ForEach(run.points, id: \.start) { point in
                    LineMark(x: .value("Period", point.start), y: .value("Value", point.value), series: .value("Run", index))
                        .foregroundStyle(run.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            if let goal {
                RuleMark(y: .value("Target", goal))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if let date = hovered?.wrappedValue, let point = points.last(where: { $0.start <= date }) {
                RuleMark(x: .value("Period", point.start))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Period", point.start), y: .value("Value", point.value))
                    .foregroundStyle(point.met.map { $0 ? ChartPalette.good : ChartPalette.critical } ?? ChartPalette.blue)
                    .symbolSize(48)
            }
        }
        .chartOverlay { proxy in
            if let hovered {
                ActionsBucketHover(proxy: proxy, starts: points.map(\.start), hovered: hovered)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: true))
    }
}

/// Tiles in even rows that fill the width: as many to a row as fit at
/// `minWidth`, then spread over the fewest rows so each row has the same
/// number (six are 6, 3 and 3, or 2, 2 and 2), the last short only when
/// they don't divide.
struct EvenGrid: Layout {
    let minWidth: CGFloat
    let spacing: CGFloat

    private func columns(_ count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = max(1, Int((width + spacing) / (minWidth + spacing)))
        let rows = Int((Double(count) / Double(fit)).rounded(.up))
        return Int((Double(count) / Double(rows)).rounded(.up))
    }

    private func tileWidth(_ columns: Int, width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minWidth * CGFloat(max(subviews.count, 1))
        let columns = columns(subviews.count, width: width)
        let tile = tileWidth(columns, width: width)
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            height += row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
        }
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: height + spacing * CGFloat(max(rows - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(subviews.count, width: bounds.width)
        let tile = tileWidth(columns, width: bounds.width)
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            let height = row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            for (offset, subview) in row.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(offset) * (tile + spacing), y: y), proposal: ProposedViewSize(width: tile, height: height))
            }
            y += height + spacing
        }
    }
}

extension ScorecardHeadline {
    /// Every goal's last whole period at its own cadence (a weekly goal's
    /// last week, a monthly one's last month), for the Overview.
    static func latest(_ measurables: [Measurable], history: MetricsHistory?, config: OrgConfig, hidden: Set<String>, teams: [Team], sources: Scorecard.Sources) -> [ScorecardHeadline] {
        Dictionary(grouping: measurables, by: \.cadence)
            .sorted { a, b in (ScorecardCadence.allCases.firstIndex(of: a.key) ?? 0) < (ScorecardCadence.allCases.firstIndex(of: b.key) ?? 0) }
            .flatMap { cadence, measurables in
                let resolution = cadence.resolution
                let data = Scorecard.Data(
                    history: history, periods: resolution.periods(count: 13, earliest: nil), resolution: resolution,
                    config: config, hidden: hidden, teams: teams, sources: sources
                )
                return measurables.map { ScorecardHeadline(measurable: $0, data: data, resolution: resolution) }
            }
    }
}

/// The Overview's Scorecards section: how many goals are on track, then
/// a tile for each one off track, which opens Scorecards.
struct ScorecardStanding: View {
    @Environment(\.showSidebarItem) private var showSidebarItem
    let headlines: [ScorecardHeadline]

    var body: some View {
        let judged = headlines.filter { $0.met != nil }
        let offTrack = judged.filter { $0.met == false }
        VStack(alignment: .leading, spacing: 12) {
            if judged.isEmpty {
                Text("Nothing to judge yet: no goal has a whole period measured.")
                    .foregroundStyle(.secondary)
            } else {
                let met = judged.count - offTrack.count
                Label(
                    offTrack.isEmpty ? "All \(judged.count) goals on track" : "\(met) of \(judged.count) goals on track",
                    systemImage: offTrack.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(offTrack.isEmpty ? ChartPalette.good : ChartPalette.warning)
            }
            if !offTrack.isEmpty {
                EvenGrid(minWidth: 190, spacing: 12) {
                    ForEach(offTrack) { headline in
                        Button { showSidebarItem?(.tab(.scorecard)) } label: { ScorecardHeadlineTile(headline: headline) }
                            .buttonStyle(.plain)
                            .help("Open Scorecards")
                    }
                }
            }
        }
    }
}
