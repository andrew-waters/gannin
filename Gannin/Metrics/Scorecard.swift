import SwiftUI

// MARK: - Model

/// How often a measurable is looked at, and so the columns it has.
enum ScorecardCadence: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case quarterly
    case annual

    var id: Self { self }

    var title: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .annual: "Annual"
        }
    }

    var noun: String {
        switch self {
        case .weekly: "week"
        case .monthly: "month"
        case .quarterly: "quarter"
        case .annual: "year"
        }
    }

    /// Columns that can be picked; 0 is all time.
    var ranges: [Int] {
        switch self {
        case .weekly: [13, 26, 52, 104, 0]
        case .monthly: [6, 12, 24, 36, 0]
        case .quarterly: [4, 8, 12, 0]
        case .annual: [3, 5, 0]
        }
    }

    var defaultRange: Int {
        switch self {
        case .weekly: 13
        case .monthly: 12
        case .quarterly: 8
        case .annual: 5
        }
    }

    func rangeTitle(_ count: Int) -> String {
        count == 0 ? "All time" : "Last \(count) \(noun)s"
    }

    func start(containing date: Date) -> Date {
        switch self {
        case .weekly: Calendar.metrics.startOfWeek(for: date)
        case .monthly: MetricsWindow.start(of: .month, containing: date)
        case .quarterly: MetricsWindow.start(of: .quarter, containing: date)
        case .annual: MetricsWindow.start(of: .year, containing: date)
        }
    }

    func adding(_ periods: Int, to date: Date) -> Date {
        let calendar = Calendar.metrics
        switch self {
        case .weekly: return calendar.date(byAdding: .day, value: 7 * periods, to: date) ?? date
        case .monthly: return calendar.date(byAdding: .month, value: periods, to: date) ?? date
        case .quarterly: return calendar.date(byAdding: .month, value: 3 * periods, to: date) ?? date
        case .annual: return calendar.date(byAdding: .year, value: periods, to: date) ?? date
        }
    }

    /// The periods, newest (the one under way) first: `count` of them, or
    /// back to `earliest` for all time.
    func periods(count: Int, earliest: Date?, now: Date = .now) -> [DateInterval] {
        var start = start(containing: now)
        let first = earliest.map { self.start(containing: $0) }
        var periods: [DateInterval] = []
        while periods.count < (count == 0 ? 1000 : count) {
            periods.append(DateInterval(start: start, end: adding(1, to: start)))
            if count == 0, start <= first ?? start { break }
            start = adding(-1, to: start)
        }
        return periods
    }

    func heading(_ period: DateInterval) -> String {
        switch self {
        case .weekly:
            let last = Calendar.metrics.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            return "\(period.start.formatted(.dateTime.day().month(.abbreviated)))\n\(last.formatted(.dateTime.day().month(.abbreviated)))"
        case .monthly:
            return period.start.formatted(.dateTime.month(.abbreviated).year())
        case .quarterly:
            let month = Calendar.metrics.component(.month, from: period.start)
            return "Q\((month - 1) / 3 + 1) \(Calendar.metrics.component(.year, from: period.start))"
        case .annual:
            return "\(Calendar.metrics.component(.year, from: period.start))"
        }
    }
}

/// A number Gannin works out from the merged PRs.
enum ScorecardMetric: String, Codable, CaseIterable, Identifiable {
    case throughput
    case cycleTime
    case firstReview
    case rework
    case unreviewed
    case prSize
    case answered

    var id: Self { self }

    var title: String {
        switch self {
        case .throughput: "PRs merged"
        case .cycleTime: "Cycle time"
        case .firstReview: "First review"
        case .rework: "PRs with rework"
        case .unreviewed: "Merged without review"
        case .prSize: "PR size"
        case .answered: "Review requests answered"
        }
    }

    var detail: String {
        switch self {
        case .throughput: "Merged in the period"
        case .cycleTime: "Median, first commit to merge"
        case .firstReview: "Median wait for the first review once ready"
        case .rework: "Changes asked for after the first review"
        case .unreviewed: "In repos that need a review"
        case .prSize: "Median lines changed"
        case .answered: "Before the PR merged, or the request was withdrawn"
        }
    }

    /// What a target is entered in.
    var unit: Measurable.Unit {
        switch self {
        case .throughput, .prSize: .number
        case .cycleTime, .firstReview: .hours
        case .rework, .unreviewed, .answered: .percent
        }
    }

    var higherIsBetter: Bool { self == .throughput || self == .answered }

    /// A count, so a period under way is held to its share of the target.
    var accumulates: Bool { self == .throughput }

    /// The raw number (seconds, a 0 to 1 share) in the target's unit.
    func display(_ raw: Double) -> Double {
        switch unit {
        case .hours: raw / 3600
        case .percent: raw * 100
        default: raw
        }
    }
}

/// One line on the scorecard: a Gannin metric or a number entered by hand
/// (costs, say), looked at weekly, monthly, quarterly or annually, with a
/// target for that period, and optionally a team and an owner.
struct Measurable: Codable, Identifiable, Hashable {
    enum Unit: String, Codable, CaseIterable, Identifiable {
        case number, currency, percent, hours, days

        var id: Self { self }

        var title: String {
            switch self {
            case .number: "Number"
            case .currency: "Money"
            case .percent: "Percentage"
            case .hours: "Hours"
            case .days: "Days"
            }
        }
    }

    enum Comparison: String, Codable, CaseIterable, Identifiable {
        case atLeast
        case atMost

        var id: Self { self }
        var symbol: String { self == .atLeast ? "≥" : "≤" }
        var title: String { self == .atLeast ? "At least" : "At most" }
    }

    var id = UUID()
    var name: String
    var cadence: ScorecardCadence
    /// Nil for one entered by hand.
    var metric: ScorecardMetric?
    /// For one entered by hand; a metric's is its own.
    var unit: Unit = .number
    /// ISO code, for money.
    var currency: String?
    /// A team's slug: a metric counts its people; nil is the org.
    var team: String?
    var owner: String?
    var comparison: Comparison = .atLeast
    /// In the unit: hours, a percentage (12 for 12%), an amount.
    var target: Double?
    /// Entered by hand, by the period's first day (`2026-10-01`).
    var values: [String: Double] = [:]
    var notes: String?

    var isManual: Bool { metric == nil }
    var effectiveUnit: Unit { metric?.unit ?? unit }

    static func key(_ date: Date) -> String {
        let parts = Calendar.metrics.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.metrics.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A value in the unit, as shown.
    func format(_ value: Double) -> String {
        switch effectiveUnit {
        case .number: return value.formatted(.number.precision(.fractionLength(0...1)))
        case .currency: return value.formatted(.currency(code: currency ?? Locale.current.currency?.identifier ?? "GBP").precision(.fractionLength(0)))
        case .percent: return "\((value / 100).formatted(.percent.precision(.fractionLength(0...1))))"
        case .hours: return metric != nil ? (value * 3600).compactDuration : "\(value.formatted(.number.precision(.fractionLength(0...1))))h"
        case .days: return "\(value.formatted(.number.precision(.fractionLength(0...1))))d"
        }
    }

    var targetText: String? {
        target.map { "\(comparison.symbol) \(format($0))" }
    }

    /// Whether a value met the target; `share` is how much of the period
    /// has passed, for a count still adding up.
    func meets(_ value: Double, share: Double = 1) -> Bool? {
        guard let target else { return nil }
        let goal = (metric?.accumulates ?? false) ? (target * share).rounded(.down) : target
        return comparison == .atLeast ? value >= goal : value <= goal
    }
}

extension OrgConfig {
    /// The scorecard's measurables: as set, else the goals from Settings ›
    /// Goals as weekly ones, so the scorecard starts from them.
    var measurables: [Measurable] {
        scorecard ?? Self.seeded(goals ?? MetricGoals())
    }

    static func seeded(_ goals: MetricGoals) -> [Measurable] {
        func lines(_ targets: MetricGoals.Targets, team: String?) -> [Measurable] {
            let pairs: [(ScorecardMetric, Double?)] = [
                (.throughput, targets.mergedPerWeek), (.cycleTime, targets.cycleTimeHours), (.firstReview, targets.firstReviewHours),
                (.rework, targets.reworkShare.map { $0 * 100 }), (.unreviewed, targets.unreviewedShare.map { $0 * 100 }),
                (.prSize, targets.prSizeLines.map(Double.init)), (.answered, targets.answeredShare.map { $0 * 100 }),
            ]
            return pairs.compactMap { metric, target in
                target.map {
                    Measurable(
                        id: Scorecard.stableID("\(team ?? "")|\(metric.rawValue)"), name: metric.title, cadence: .weekly, metric: metric,
                        team: team, comparison: metric.higherIsBetter ? .atLeast : .atMost, target: $0
                    )
                }
            }
        }
        return lines(goals.org, team: nil) + goals.teams.sorted { $0.key < $1.key }.flatMap { lines($0.value, team: $0.key) }
    }
}

extension OrgConfigStore {
    /// Changes the measurables, starting from the seeded ones the first
    /// time.
    func updateMeasurables(_ org: String, _ change: (inout [Measurable]) -> Void) {
        update(org) { config in
            var measurables = config.measurables
            change(&measurables)
            config.scorecard = measurables
        }
    }
}

// MARK: - Numbers

enum Scorecard {
    /// The same ID for the same text, so seeded measurables keep theirs.
    static func stableID(_ text: String) -> UUID {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100_0000_01b3
            second = (second &* 0x100_0000_01b3) ^ UInt64(byte)
        }
        let bytes = withUnsafeBytes(of: first.bigEndian) { Array($0) } + withUnsafeBytes(of: second.bigEndian) { Array($0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    struct Cell: Hashable {
        /// In the measurable's unit; nil with nothing to show.
        let value: Double?
        /// What a metric's from: PRs or review requests.
        let count: Int?
        /// The history reaches the period (always, for one entered by hand).
        let covered: Bool
        /// How much of the period has passed, 0 to 1.
        let share: Double
    }

    /// The merged PRs a scorecard's metrics come from, by period, filtered
    /// as the metrics are: bots, hidden PRs, excluded repos and people
    /// (and their reviews) left out.
    struct Data {
        let periods: [DateInterval]
        let buckets: [[MetricPullRequest]]
        let coveredFrom: Date?
        let config: OrgConfig
        let teams: [String: Team]

        init(history: MetricsHistory?, periods: [DateInterval], config: OrgConfig, hidden: Set<String>, teams: [Team]) {
            self.periods = periods
            self.config = config
            self.teams = Dictionary(teams.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
            coveredFrom = history?.coveredFrom
            let earliest = periods.last?.start ?? .now
            let considered = (history?.pullRequests.values.map { $0 } ?? [])
                .filter {
                    !$0.authorIsBot && !hidden.contains($0.id) && $0.mergedAt >= earliest
                        && !config.repoExclusion.contains($0.repo) && !config.excludes($0.author?.login ?? "")
                }
                .map { pr in
                    var pr = pr
                    pr.reviews.removeAll { config.excludes($0.login) }
                    pr.reviewRequests.removeAll { config.excludes($0.login) }
                    return pr
                }
            // One pass, newest period first, as the periods are.
            var buckets = Array(repeating: [MetricPullRequest](), count: periods.count)
            for pr in considered {
                if let index = periods.firstIndex(where: { pr.mergedAt >= $0.start && pr.mergedAt < $0.end }) { buckets[index].append(pr) }
            }
            self.buckets = buckets
        }

        func cells(for measurable: Measurable, now: Date = .now) -> [Cell] {
            periods.indices.map { index in
                let period = periods[index]
                let share = min(max(now.timeIntervalSince(period.start) / period.duration, 0), 1)
                guard let metric = measurable.metric else {
                    return Cell(value: measurable.values[Measurable.key(period.start)], count: nil, covered: true, share: share)
                }
                let covered = coveredFrom.map { $0 <= period.start } ?? false
                guard covered else { return Cell(value: nil, count: nil, covered: false, share: share) }
                let logins = measurable.team.flatMap { teams[$0] }.map { Set($0.members) }
                let (raw, count) = Self.measure(metric, all: buckets[index], logins: logins, config: config)
                return Cell(value: raw.map(metric.display), count: count, covered: true, share: share)
            }
        }

        /// One metric for one period, as `OrgMetrics` works it out: PR
        /// numbers follow the author, requests answered the reviewer.
        static func measure(_ metric: ScorecardMetric, all: [MetricPullRequest], logins: Set<String>?, config: OrgConfig) -> (Double?, Int) {
            func inTeam(_ login: String?) -> Bool { logins.map { login.map($0.contains) ?? false } ?? true }
            let prs = all.filter { inTeam($0.author?.login) }
            switch metric {
            case .throughput:
                return (Double(prs.count), prs.count)
            case .cycleTime:
                return (DurationStat(prs.map(\.cycleTime)).median, prs.count)
            case .firstReview:
                let waits = prs.compactMap(\.timeToFirstReview)
                return (DurationStat(waits).median, waits.count)
            case .rework:
                return (prs.isEmpty ? nil : StageSummary(prs.compactMap { $0.duration(of: .rework) }).share, prs.count)
            case .unreviewed:
                return (prs.isEmpty ? nil : Double(prs.filter { $0.firstReviewAt == nil && config.needsReview($0.repo) }.count) / Double(prs.count), prs.count)
            case .prSize:
                return (SizeStat(prs).median.map(Double.init), prs.count)
            case .answered:
                var requests = 0
                var answered = 0
                for pr in all {
                    for request in pr.reviewRequests where inTeam(request.login) {
                        let deadline = request.removedAt ?? pr.mergedAt
                        let response = pr.reviews.first { $0.login == request.login && $0.submittedAt >= request.requestedAt && $0.submittedAt <= deadline }
                        // Withdrawn before they got to it: not theirs to answer.
                        if response == nil && request.removedAt != nil { continue }
                        requests += 1
                        if response != nil { answered += 1 }
                    }
                }
                return (requests == 0 ? nil : Double(answered) / Double(requests), requests)
            }
        }
    }
}

// MARK: - The page

/// Delivery › Scorecard, in the spirit of Strety's: measurables for each
/// cadence (weekly, monthly, quarterly, annual), each a row with its
/// target, a column per period newest first (the one under way shaded),
/// green on target and red off it, and how often it hit. Gannin's metrics
/// fill themselves in; the rest (costs, say) are entered in their cells.
struct ScorecardView: View {
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    let org: String
    @AppStorage("scorecardCadence") private var cadence: ScorecardCadence = .weekly
    @AppStorage("scorecardRanges") private var storedRanges = ""
    @AppStorage("scorecardGrouping") private var grouping: Grouping = .team
    @State private var editing: Measurable?
    @State private var adding = false

    enum Grouping: String, CaseIterable, Identifiable {
        case team = "Team"
        case owner = "Owner"
        case none = "None"
        var id: Self { self }
    }

    private struct Section: Identifiable {
        let title: String
        let symbol: String
        let measurables: [Measurable]
        var id: String { title }
    }

    static let nameWidth: CGFloat = 250
    static let targetWidth: CGFloat = 100
    static let cellWidth: CGFloat = 86
    static let hitWidth: CGFloat = 70

    var body: some View {
        let config = configs.config(for: org)
        let all = config.measurables
        let measurables = all.filter { $0.cadence == cadence }
        let range = self.range
        let usesMetrics = measurables.contains { !$0.isManual }
        let earliest = earliest(measurables)
        let periods = cadence.periods(count: range, earliest: earliest)
        let teams = orgs.snapshot(for: org)?.teams ?? []
        Group {
            if measurables.isEmpty {
                ContentUnavailableView {
                    Label("No \(cadence.title.lowercased()) measurables", systemImage: "target")
                } description: {
                    Text("Add what the team looks at each \(cadence.noun): one of Gannin's delivery numbers with a target, or one you enter yourself, like costs.")
                } actions: {
                    Button("Add Measurable") { adding = true }
                }
            } else {
                let data = Scorecard.Data(history: metricsStore.history(for: org), periods: periods, config: config, hidden: hidden.keys, teams: teams)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(sections(measurables, teams: teams)) { section in
                            sectionView(section, data: data)
                        }
                        if usesMetrics, let note = coverageNote(periods) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .toolbar { toolbar(all) }
        .syncOffNotice(.metrics)
        .sheet(isPresented: $adding) {
            MeasurableEditor(org: org, measurable: nil, cadence: cadence)
        }
        .sheet(item: $editing) { measurable in
            MeasurableEditor(org: org, measurable: measurable, cadence: measurable.cadence)
        }
        .task(id: "\(org) \(cadence.rawValue) \(range) \(usesMetrics)") {
            guard usesMetrics else { return }
            // All time reaches back to the org's first issue.
            if range == 0 { await issueStore.loadEarliestIssue(org) }
            let start = range == 0 ? (issueStore.earliestIssue(org) ?? periods.last?.start ?? .now) : (periods.last?.start ?? .now)
            await metricsStore.sync(org, windowDays: Int(Date.now.timeIntervalSince(start) / 86_400) + 2)
        }
    }

    /// The columns picked for this cadence, kept per cadence.
    private var range: Int {
        let saved = Dictionary(storedRanges.split(separator: ",").compactMap { pair -> (String, Int)? in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), Int(parts[1]) ?? 0) : nil
        }, uniquingKeysWith: { _, last in last })
        return saved[cadence.rawValue].flatMap { cadence.ranges.contains($0) ? $0 : nil } ?? cadence.defaultRange
    }

    private func setRange(_ value: Int) {
        var saved = Dictionary(storedRanges.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        saved[cadence.rawValue] = "\(value)"
        storedRanges = saved.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
    }

    /// For all time: the first value entered, or the first PR the history
    /// holds (or the org's first issue, while it's fetched back that far).
    private func earliest(_ measurables: [Measurable]) -> Date? {
        let entered = measurables.flatMap(\.values.keys).compactMap(Measurable.date).min()
        let metrics = measurables.contains { !$0.isManual }
            ? [issueStore.earliestIssue(org), metricsStore.history(for: org)?.coveredFrom].compactMap { $0 }.min()
            : nil
        return [entered, metrics].compactMap { $0 }.min()
    }

    private func coverageNote(_ periods: [DateInterval]) -> String? {
        guard let first = periods.last?.start else { return nil }
        guard let history = metricsStore.history(for: org) else { return "Fetching merged PRs." }
        guard history.coveredFrom > first else { return nil }
        let syncing = metricsStore.syncing.contains(org)
        return "Merged PRs go back to \(history.coveredFrom.formatted(date: .abbreviated, time: .omitted)) so far\(syncing ? ", and Gannin is fetching further back a week at a time" : ""). Earlier periods fill in as they arrive."
    }

    private func sections(_ measurables: [Measurable], teams: [Team]) -> [Section] {
        switch grouping {
        case .none:
            return [Section(title: orgs.org(login: org)?.displayName ?? org, symbol: "building.2", measurables: measurables)]
        case .team:
            let byTeam = Dictionary(grouping: measurables) { $0.team ?? "" }
            let orgSection = byTeam[""].map { [Section(title: orgs.org(login: org)?.displayName ?? org, symbol: "building.2", measurables: $0)] } ?? []
            let teamSections = byTeam.filter { !$0.key.isEmpty }
                .map { slug, items in Section(title: teams.first { $0.slug == slug }?.name ?? slug, symbol: "person.3", measurables: items) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return orgSection + teamSections
        case .owner:
            let members = orgs.snapshot(for: org)?.members ?? []
            let byOwner = Dictionary(grouping: measurables) { $0.owner ?? "" }
            let owned = byOwner.filter { !$0.key.isEmpty }
                .map { login, items in Section(title: members.first { $0.login == login }?.displayName ?? login, symbol: "person.crop.circle", measurables: items) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return owned + (byOwner[""].map { [Section(title: "No owner", symbol: "person.crop.circle.badge.questionmark", measurables: $0)] } ?? [])
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ all: [Measurable]) -> some ToolbarContent {
        ToolbarItem {
            Picker("Cadence", selection: $cadence) {
                ForEach(ScorecardCadence.allCases) { cadence in
                    let count = all.filter { $0.cadence == cadence }.count
                    Text(count > 0 ? "\(cadence.title) \(count)" : cadence.title).tag(cadence)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Each cadence has its own measurables and targets")
        }
        ToolbarItem {
            Picker("Range", selection: Binding(get: { range }, set: { setRange($0) })) {
                ForEach(cadence.ranges, id: \.self) { Text(cadence.rangeTitle($0)).tag($0) }
            }
            .fixedSize()
            .help("How far back. All time goes back to the org's first issue, which takes a while to fetch the first time.")
        }
        ToolbarItem {
            Picker("Group by", selection: $grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
        ToolbarItem {
            Button {
                adding = true
            } label: {
                Label("Add Measurable", systemImage: "plus")
            }
            .help("Something to track each \(cadence.noun): a delivery number or one you enter")
        }
    }

    private func sectionView(_ section: Section, data: Scorecard.Data) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).foregroundStyle(.secondary)
                Text(section.title).font(.title3.weight(.semibold))
            }
            VStack(spacing: 0) {
                headerRow(data.periods)
                ForEach(section.measurables) { measurable in
                    Divider()
                    MeasurableRow(org: org, measurable: measurable, cells: data.cells(for: measurable), periods: data.periods, teamName: teamName(measurable)) {
                        editing = measurable
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separatorLine))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .fixedSize()
        }
    }

    private func teamName(_ measurable: Measurable) -> String? {
        guard grouping != .team, let slug = measurable.team else { return nil }
        return orgs.snapshot(for: org)?.teams.first { $0.slug == slug }?.name ?? slug
    }

    private func headerRow(_ periods: [DateInterval]) -> some View {
        HStack(spacing: 0) {
            Text("NAME").frame(width: Self.nameWidth, alignment: .leading).padding(.leading, 14)
            Text("TARGET").frame(width: Self.targetWidth, alignment: .leading)
            Text("HIT").frame(width: Self.hitWidth).help("Whole periods on target, of those measured")
            ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                Text(cadence.heading(period))
                    .multilineTextAlignment(.center)
                    .frame(width: Self.cellWidth, height: 40)
                    .background(index == 0 ? Color.secondary.opacity(0.1) : .clear)
                    .help(index == 0 ? "So far" : "")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

/// A measurable's row: its name, target and hit rate, then a cell per
/// period; a hand-entered one's cells take a value when clicked.
private struct MeasurableRow: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let measurable: Measurable
    let cells: [Scorecard.Cell]
    let periods: [DateInterval]
    let teamName: String?
    let edit: () -> Void

    var body: some View {
        // Whole periods only: the one under way is still moving.
        let judged = cells.dropFirst().compactMap { cell in cell.value.flatMap { measurable.meets($0) } }
        HStack(spacing: 0) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(measurable.name)
                        if measurable.isManual {
                            Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary).help("Entered by hand")
                        }
                    }
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: ScorecardView.nameWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .help(measurable.notes ?? "Edit this measurable")
            Text(measurable.targetText ?? "No target")
                .foregroundStyle(measurable.target == nil ? .secondary : .primary)
                .frame(width: ScorecardView.targetWidth, alignment: .leading)
            Text(judged.isEmpty ? "" : "\(judged.filter { $0 }.count)/\(judged.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ScorecardView.hitWidth)
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if measurable.isManual {
                    ManualCell(org: org, measurable: measurable, period: periods[index], cell: cell, isCurrent: index == 0)
                } else {
                    MetricCell(measurable: measurable, cell: cell, isCurrent: index == 0)
                }
            }
        }
        .font(.callout)
        .contextMenu {
            Button("Edit") { edit() }
            Button("Duplicate") {
                configs.updateMeasurables(org) { list in
                    var copy = measurable
                    copy.id = UUID()
                    copy.name += " copy"
                    copy.values = [:]
                    list.insert(copy, at: (list.firstIndex { $0.id == measurable.id } ?? list.count - 1) + 1)
                }
            }
            Button("Delete", role: .destructive) {
                configs.updateMeasurables(org) { $0.removeAll { $0.id == measurable.id } }
            }
        }
    }

    private var caption: String {
        var parts = [measurable.metric?.detail ?? "Entered by hand"]
        if let teamName { parts.append(teamName) }
        return parts.joined(separator: " · ")
    }
}

private struct MetricCell: View {
    let measurable: Measurable
    let cell: Scorecard.Cell
    let isCurrent: Bool

    var body: some View {
        let met = cell.value.flatMap { measurable.meets($0, share: cell.share) }
        Text(cell.value.map(measurable.format) ?? (cell.covered ? "N/A" : "-"))
            .fontWeight(met == nil ? .regular : .semibold)
            .foregroundStyle(met.map { $0 ? ChartPalette.good : ChartPalette.critical } ?? .secondary)
            .monospacedDigit()
            .frame(width: ScorecardView.cellWidth, height: 48)
            .background(isCurrent ? Color.secondary.opacity(0.1) : .clear)
            .help(help(met))
    }

    private func help(_ met: Bool?) -> String {
        guard cell.covered else { return "Before the history Gannin has" }
        guard cell.value != nil else { return "Nothing to measure" + (isCurrent ? " yet" : "") }
        let verdict = met.map { $0 ? "On target" : "Off target" } ?? "No target"
        let from = cell.count.map { measurable.metric == .answered ? ", from \($0) review request\($0 == 1 ? "" : "s")" : ", from \($0) PR\($0 == 1 ? "" : "s")" } ?? ""
        if measurable.metric?.accumulates == true, isCurrent, let target = measurable.target {
            return "\(verdict) so far: expected \(Int((target * cell.share).rounded(.down))) by now"
        }
        return verdict + from + (isCurrent ? ", so far" : "")
    }
}

/// A hand-entered value: click to set or change it, Clear to remove it.
private struct ManualCell: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let measurable: Measurable
    let period: DateInterval
    let cell: Scorecard.Cell
    let isCurrent: Bool
    @State private var entering = false
    @State private var draft: Double?
    @State private var hovering = false

    var body: some View {
        let met = cell.value.flatMap { measurable.meets($0) }
        Button {
            draft = cell.value
            entering = true
        } label: {
            Text(cell.value.map(measurable.format) ?? (hovering ? "Add" : "N/A"))
                .fontWeight(met == nil ? .regular : .semibold)
                .foregroundStyle(met.map { $0 ? ChartPalette.good : ChartPalette.critical } ?? (hovering ? Color.accentColor : .secondary))
                .monospacedDigit()
                .frame(width: ScorecardView.cellWidth, height: 48)
                .background(isCurrent ? Color.secondary.opacity(0.1) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(cell.value == nil ? "Enter this \(measurable.cadence.noun)'s value" : "Change this \(measurable.cadence.noun)'s value")
        .popover(isPresented: $entering) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(measurable.name), \(measurable.cadence.heading(period).replacingOccurrences(of: "\n", with: " - "))")
                    .font(.headline)
                HStack {
                    TextField("Value", value: $draft, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(save)
                    Text(unitLabel).foregroundStyle(.secondary)
                }
                HStack {
                    if cell.value != nil {
                        Button("Clear", role: .destructive) {
                            draft = nil
                            save()
                        }
                    }
                    Spacer()
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    private var unitLabel: String {
        switch measurable.effectiveUnit {
        case .currency: measurable.currency ?? Locale.current.currency?.identifier ?? "GBP"
        case .percent: "%"
        case .hours: "hours"
        case .days: "days"
        case .number: ""
        }
    }

    private func save() {
        let key = Measurable.key(period.start)
        let value = draft
        configs.updateMeasurables(org) { list in
            guard let index = list.firstIndex(where: { $0.id == measurable.id }) else { return }
            list[index].values[key] = value
        }
        entering = false
    }
}
