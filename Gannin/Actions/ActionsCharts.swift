import Charts
import SwiftUI

// MARK: - Change on the period before

/// A number's change on the period before the window: "+81%" or "-3 pp",
/// tinted when the direction is good or bad news.
struct StatChange: Hashable {
    let text: String
    /// True when the change is for the worse, false for the better, nil
    /// when neither (more runs, say).
    let isWorse: Bool?

    /// A relative change; nil without a previous value to compare with.
    static func percent(_ current: Double, _ previous: Double, higherIsWorse: Bool?) -> StatChange? {
        guard previous > 0 else { return nil }
        let change = current / previous - 1
        let rounded = (change * 100).rounded()
        guard rounded != 0 else { return StatChange(text: "0%", isWorse: nil) }
        return StatChange(
            text: (rounded > 0 ? "+" : "") + "\(Int(rounded))%",
            isWorse: higherIsWorse.map { $0 == (rounded > 0) }
        )
    }

    /// A change in a rate, in percentage points.
    static func points(_ current: Double?, _ previous: Double?, higherIsWorse: Bool) -> StatChange? {
        guard let current, let previous else { return nil }
        let rounded = ((current - previous) * 100).rounded()
        guard rounded != 0 else { return StatChange(text: "0 pp", isWorse: nil) }
        return StatChange(text: (rounded > 0 ? "+" : "") + "\(Int(rounded)) pp", isWorse: higherIsWorse == (rounded > 0))
    }

    var color: Color {
        switch isWorse {
        case true: ChartPalette.critical
        case false: ChartPalette.good
        case nil: .secondary
        }
    }
}

struct ChangeLabel: View {
    let change: StatChange?

    var body: some View {
        if let change {
            Text(change.text)
                .monospacedDigit()
                .foregroundStyle(change.color)
                .help("Change on the period before")
        }
    }
}

// MARK: - Table cells

/// Durations in six buckets, as small bars; hover for the counts.
struct HistogramCell: View {
    let histogram: DurationHistogram

    var body: some View {
        let top = max(histogram.counts.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(histogram.counts.enumerated()), id: \.offset) { _, count in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(count == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(ChartPalette.blue))
                    .frame(width: 12, height: count == 0 ? 1 : max(2, 22 * CGFloat(count) / CGFloat(top)))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .help(zip(DurationHistogram.labels, histogram.counts).map { "\($0): \($1)" }.joined(separator: "\n"))
    }
}

/// A value per week as small bars, oldest first.
struct SparkBars: View {
    let values: [Double]
    var help: String = ""

    var body: some View {
        let top = max(values.max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(value == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(ChartPalette.blue))
                    .frame(width: 7, height: value == 0 ? 1 : max(2, 22 * value / top))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .help(help)
    }
}

/// A value per week as a small line, gaps where there's none.
struct SparkLine: View {
    let values: [Double?]
    var help: String = ""

    var body: some View {
        let known = values.compactMap { $0 }
        let top = max(known.max() ?? 1, 0.0001)
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            var drawing = false
            for (index, value) in values.enumerated() {
                guard let value else {
                    drawing = false
                    continue
                }
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 2 - (size.height - 4) * value / top)
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(ChartPalette.blue))
            }
            context.stroke(path, with: .color(ChartPalette.blue), lineWidth: 1.5)
        }
        .frame(width: 100, height: 22)
        .help(help)
    }
}

// MARK: - Charts

/// The colour of a stacked series: palette slots in the order given, and
/// Others in neutral grey.
private func seriesColors(_ series: [String]) -> [Color] {
    var slot = 0
    return series.map { name in
        if name == StackedRunTime.others { return ChartPalette.neutral }
        defer { slot += 1 }
        return ChartPalette.slot(slot)
    }
}

/// Run time per day or week, stacked by repo, workflow or job.
struct StackedRunTimeChart: View {
    let title: String
    let data: StackedRunTime
    let granularity: IssueMetrics.Granularity
    @State private var hovered: Date?

    var body: some View {
        let starts = Array(Set(data.points.map(\.start))).sorted()
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart(data.points, id: \.self) { point in
                BarMark(
                    x: .value("Period", point.start, unit: granularity.chartUnit),
                    y: .value("Hours", point.value / 3600)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .opacity(hovered == nil || hovered == point.start ? 1 : 0.4)
            }
            .chartForegroundStyleScale(domain: data.series, range: seriesColors(data.series))
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let hours = value.as(Double.self) { Text((hours * 3600).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in ActionsBucketHover(proxy: proxy, starts: starts, hovered: $hovered) }
            .frame(height: 200)
            if let hovered {
                let values = data.points.filter { $0.start == hovered }.sorted { $0.value > $1.value }
                Text("\(granularity.label(hovered)): \(values.reduce(0) { $0 + $1.value }.compactDuration) in all · " + values.prefix(4).map { "\($0.series) \($0.value.compactDuration)" }.joined(separator: ", "))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Wall-clock run time, summed. Hover for values.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

/// How many runs took how long, in the six buckets, stacked by group.
struct DistributionChart: View {
    let title: String
    /// (group, duration) per run or job.
    let items: [(group: String, duration: TimeInterval)]

    private struct Point: Hashable {
        let bucket: String
        let series: String
        let count: Int
    }

    var body: some View {
        let stacked = StackedRunTime(items.map { (at: Date.distantPast, group: $0.group, duration: $0.duration) }, granularity: .day)
        let kept = Set(stacked.series)
        var counts: [String: [String: Int]] = [:]
        for item in items {
            let series = kept.contains(item.group) ? item.group : StackedRunTime.others
            counts[DurationHistogram.labels[DurationHistogram.bucket(item.duration)], default: [:]][series, default: 0] += 1
        }
        let points = counts.flatMap { bucket, values in values.map { Point(bucket: bucket, series: $0.key, count: $0.value) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart(points, id: \.self) { point in
                BarMark(x: .value("Took", point.bucket), y: .value("Runs", point.count))
                    .foregroundStyle(by: .value("Series", point.series))
            }
            .chartXScale(domain: DurationHistogram.labels)
            .chartForegroundStyleScale(domain: stacked.series, range: seriesColors(stacked.series))
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .frame(height: 200)
            Text("Up to a minute, 5, 10, 20 and 60 minutes, and longer.").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

/// p50, p75 and p90 per week, on one duration axis.
struct PercentileTrendChart: View {
    let title: String
    let buckets: [ActionsBucket]
    let granularity: IssueMetrics.Granularity
    @State private var hovered: Date?

    private static let series: [(String, KeyPath<PercentileStat, TimeInterval?>)] = [("p50", \.median), ("p75", \.p75), ("p90", \.p90)]

    var body: some View {
        let points = buckets.flatMap { bucket in
            Self.series.compactMap { name, path in bucket.duration[keyPath: path].map { (start: bucket.start, series: name, minutes: $0 / 60) } }
        }
        let top = max(points.map(\.minutes).max() ?? 1, 1) * 1.15
        let unit = granularity.chartUnit
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Period", point.start, unit: unit), y: .value("Minutes", point.minutes), series: .value("Series", point.series))
                        .foregroundStyle(by: .value("Series", point.series))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    if granularity == .week || hovered == point.start {
                        PointMark(x: .value("Period", point.start, unit: unit), y: .value("Minutes", point.minutes))
                            .foregroundStyle(by: .value("Series", point.series))
                            .symbolSize(hovered == point.start ? 70 : 36)
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Period", hovered, unit: unit))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(["p50": ChartPalette.blue, "p75": ChartPalette.orange, "p90": ChartPalette.aqua])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in ActionsBucketHover(proxy: proxy, starts: buckets.map(\.start), hovered: $hovered) }
            .frame(height: 170)
            if let hovered, let bucket = buckets.first(where: { $0.start == hovered }) {
                Text("\(granularity.label(bucket.start)): p50 \(bucket.duration.median?.compactDuration ?? "-"), p75 \(bucket.duration.p75?.compactDuration ?? "-"), p90 \(bucket.duration.p90?.compactDuration ?? "-") over \(bucket.duration.count) runs")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover for values.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Maps the pointer to the bucket under it.
struct ActionsBucketHover: View {
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
