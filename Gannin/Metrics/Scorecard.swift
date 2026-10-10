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

    var noun: String { resolution.noun }

    /// The periods its targets are for.
    var resolution: ScorecardResolution {
        switch self {
        case .weekly: .week
        case .monthly: .month
        case .quarterly: .quarter
        case .annual: .year
        }
    }

    func heading(_ period: DateInterval) -> String { resolution.heading(period) }
}

/// What the scorecard's columns, tiles and charts are by, whatever the
/// measurables' cadence: a weekly target looked at day by day, say.
enum ScorecardResolution: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case quarter
    case year

    var id: Self { self }

    var title: String { noun.capitalized }

    var noun: String { rawValue }

    /// Its usual length, for holding a count's target to it: a weekly
    /// target of 20 PRs is about 87 a month.
    var days: Double {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 365.25 / 12
        case .quarter: 365.25 / 4
        case .year: 365.25
        }
    }

    /// Columns that can be picked; 0 is all time, 2 the last whole one
    /// and the one under way.
    var ranges: [Int] {
        switch self {
        case .day: [2, 14, 30, 60, 90, 0]
        case .week: [2, 13, 26, 52, 104, 0]
        case .month: [2, 6, 12, 24, 36, 0]
        case .quarter: [2, 4, 8, 12, 0]
        case .year: [2, 3, 5, 0]
        }
    }

    var defaultRange: Int {
        switch self {
        case .day: 14
        case .week: 13
        case .month: 12
        case .quarter: 8
        case .year: 5
        }
    }

    func rangeTitle(_ count: Int) -> String {
        switch count {
        case 0: "All time"
        case 2: lastTitle
        default: "Last \(count) \(noun)s"
        }
    }

    /// The last whole one: Yesterday, Last week.
    var lastTitle: String { self == .day ? "Yesterday" : "Last \(noun)" }

    func start(containing date: Date) -> Date {
        switch self {
        case .day: Calendar.metrics.startOfDay(for: date)
        case .week: Calendar.metrics.startOfWeek(for: date)
        case .month: MetricsWindow.start(of: .month, containing: date)
        case .quarter: MetricsWindow.start(of: .quarter, containing: date)
        case .year: MetricsWindow.start(of: .year, containing: date)
        }
    }

    func adding(_ periods: Int, to date: Date) -> Date {
        let calendar = Calendar.metrics
        switch self {
        case .day: return calendar.date(byAdding: .day, value: periods, to: date) ?? date
        case .week: return calendar.date(byAdding: .day, value: 7 * periods, to: date) ?? date
        case .month: return calendar.date(byAdding: .month, value: periods, to: date) ?? date
        case .quarter: return calendar.date(byAdding: .month, value: 3 * periods, to: date) ?? date
        case .year: return calendar.date(byAdding: .year, value: periods, to: date) ?? date
        }
    }

    /// The periods, newest (the one under way) first: `count` of them, or
    /// back to `earliest` for all time.
    func periods(count: Int, earliest: Date?, now: Date = .now) -> [DateInterval] {
        var start = start(containing: now)
        let first = earliest.map { self.start(containing: $0) }
        var periods: [DateInterval] = []
        while periods.count < (count == 0 ? 2000 : count) {
            periods.append(DateInterval(start: start, end: adding(1, to: start)))
            if count == 0, start <= first ?? start { break }
            start = adding(-1, to: start)
        }
        return periods
    }

    func heading(_ period: DateInterval) -> String {
        switch self {
        case .day:
            return "\(period.start.formatted(.dateTime.weekday(.abbreviated)))\n\(period.start.formatted(.dateTime.day().month(.abbreviated)))"
        case .week:
            let last = Calendar.metrics.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            return "\(period.start.formatted(.dateTime.day().month(.abbreviated)))\n\(last.formatted(.dateTime.day().month(.abbreviated)))"
        case .month:
            return period.start.formatted(.dateTime.month(.abbreviated).year())
        case .quarter:
            let month = Calendar.metrics.component(.month, from: period.start)
            return "Q\((month - 1) / 3 + 1) \(Calendar.metrics.component(.year, from: period.start))"
        case .year:
            return "\(Calendar.metrics.component(.year, from: period.start))"
        }
    }

    /// A period on one line: Mon 6 Oct, 29 Sep to 5 Oct, Oct 2026.
    func label(_ period: DateInterval) -> String {
        switch self {
        case .day: period.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        default: heading(period).replacingOccurrences(of: "\n", with: " to ")
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
    case prFiles
    case answered
    case slowReviews
    case openPullRequests
    case issueCycleTime
    case flakyRuns

    var id: Self { self }

    /// What it's about, for grouping where they're picked.
    var group: String {
        switch self {
        case .throughput, .cycleTime, .prSize, .prFiles, .openPullRequests: "Pull requests"
        case .firstReview, .rework, .unreviewed, .answered, .slowReviews: "Reviews"
        case .issueCycleTime: "Issues"
        case .flakyRuns: "CI"
        }
    }

    /// By group, in order.
    static func groups() -> [(title: String, metrics: [ScorecardMetric])] {
        var groups: [(title: String, metrics: [ScorecardMetric])] = []
        for metric in allCases {
            if let index = groups.firstIndex(where: { $0.title == metric.group }) {
                groups[index].metrics.append(metric)
            } else {
                groups.append((metric.group, [metric]))
            }
        }
        return groups
    }

    /// What its rows expand into: people, or repos for CI runs, which
    /// aren't anyone's.
    var byRepo: Bool { self == .flakyRuns }

    var title: String {
        switch self {
        case .throughput: "PRs merged"
        case .cycleTime: "Cycle time"
        case .firstReview: "First review"
        case .rework: "PRs with rework"
        case .unreviewed: "Merged without review"
        case .prSize: "PR size"
        case .prFiles: "Files changed"
        case .answered: "Review requests answered"
        case .slowReviews: "Reviews waiting over a day"
        case .openPullRequests: "Open PRs"
        case .issueCycleTime: "Issue cycle time"
        case .flakyRuns: "Flaky CI runs"
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
        case .prFiles: "Median files changed per PR"
        case .answered: "Before the PR merged, or the request was withdrawn"
        case .slowReviews: "Requests made in the period not answered within a day"
        case .openPullRequests: "Open at the period's end, or now"
        case .issueCycleTime: "Median time in progress, of issues completed"
        case .flakyRuns: "Passed only on a re-run, or a commit both failed and passed"
        }
    }

    /// What a target is entered in.
    var unit: Measurable.Unit {
        switch self {
        case .throughput, .prSize, .prFiles, .slowReviews, .openPullRequests, .flakyRuns: .number
        case .cycleTime, .firstReview, .issueCycleTime: .hours
        case .rework, .unreviewed, .answered: .percent
        }
    }

    /// What a count is of, beside its target: "PRs a week", "lines".
    func countUnit(per cadence: ScorecardCadence) -> String {
        switch self {
        case .throughput: "PRs a \(cadence.noun)"
        case .prSize: "lines"
        case .prFiles: "files"
        case .slowReviews: "requests a \(cadence.noun)"
        case .openPullRequests: "PRs"
        case .flakyRuns: "runs a \(cadence.noun)"
        case .cycleTime, .firstReview, .rework, .unreviewed, .answered, .issueCycleTime: ""
        }
    }

    var higherIsBetter: Bool { self == .throughput || self == .answered }

    /// A count, so a period under way is held to its share of the target.
    var accumulates: Bool { self == .throughput || self == .slowReviews || self == .flakyRuns }

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

    /// The same measurable held to its target per person: a count (PRs
    /// merged) is the team's, so a person isn't judged on it.
    var personal: Measurable {
        guard metric?.accumulates == true else { return self }
        var copy = self
        copy.target = nil
        return copy
    }

    var targetText: String? {
        target.map { "\(comparison.symbol) \(format($0))" }
    }

    /// Whether a value met the target; `share` is how much of the period
    /// has passed, for a count still adding up.
    func meets(_ value: Double, share: Double = 1) -> Bool? {
        guard let goal = goal(share: share) else { return nil }
        return comparison == .atLeast ? value >= goal : value <= goal
    }

    /// The target held to a share of the period (a count's, so far, or in
    /// a shorter period than its cadence's); whole ones only.
    /// `≥ 20`, held to a share as `goal(share:)` is.
    func targetText(share: Double) -> String? {
        goal(share: share).map { "\(comparison.symbol) \(format($0))" }
    }

    func goal(share: Double = 1) -> Double? {
        guard let target else { return nil }
        return (metric?.accumulates ?? false) ? (target * share).rounded(.down) : target
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
                (.prSize, targets.prSizeLines.map(Double.init)), (.prFiles, targets.prSizeFiles.map(Double.init)), (.answered, targets.answeredShare.map { $0 * 100 }),
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
        /// How much of the target the cell is held to: the share of the
        /// period passed, times the period's length against the cadence's
        /// (a count's weekly target is a seventh a day).
        let share: Double
        /// Whether it's held to the target: not a hand-entered number
        /// looked at by other periods than its own.
        var judges = true

        func meets(_ measurable: Measurable) -> Bool? {
            judges ? value.flatMap { measurable.meets($0, share: share) } : nil
        }
    }

    /// The merged PRs a scorecard's metrics come from, by period, filtered
    /// as the metrics are: bots, hidden PRs, excluded repos and people
    /// (and their reviews) left out.
    /// What the scorecard works out from besides the merged PRs: the open
    /// PRs, CI runs and the issue history, each nil until it's fetched.
    struct Sources {
        var openPullRequests: [PullRequest] = []
        var runs: [WorkflowRun]?
        var issues: IssueHistory?
    }

    struct Data {
        let periods: [DateInterval]
        let resolution: ScorecardResolution
        let buckets: [[MetricPullRequest]]
        /// Every merged PR considered, for numbers that aren't by merge date
        /// (review waits, PRs open at a time).
        let pullRequests: [MetricPullRequest]
        let openPullRequests: [PullRequest]
        let runs: [WorkflowRun]?
        /// The first run fetched: periods before it aren't covered.
        let runsFrom: Date?
        let issues: [IssueTiming]?
        let issuesFrom: Date?
        let coveredFrom: Date?
        let config: OrgConfig
        let teams: [String: Team]

        init(history: MetricsHistory?, periods: [DateInterval], resolution: ScorecardResolution, config: OrgConfig, hidden: Set<String>, teams: [Team], sources: Sources = Sources(), now: Date = .now) {
            self.periods = periods
            self.resolution = resolution
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
            pullRequests = considered
            // One pass, newest period first, as the periods are.
            var buckets = Array(repeating: [MetricPullRequest](), count: periods.count)
            for pr in considered {
                if let index = periods.firstIndex(where: { pr.mergedAt >= $0.start && pr.mergedAt < $0.end }) { buckets[index].append(pr) }
            }
            self.buckets = buckets
            openPullRequests = sources.openPullRequests.filter {
                !hidden.contains($0.id) && !config.repoExclusion.contains($0.repo) && !config.excludes($0.author?.login ?? "")
            }
            let runs = sources.runs?.filter { !config.repoExclusion.contains($0.repo) && $0.createdAt >= earliest }
            self.runs = runs
            runsFrom = sources.runs?.map(\.createdAt).min()
            let workflow = config.workflow
            issues = sources.issues.map { history in
                history.issues.values
                    .filter { $0.isCompleted && ($0.closedAt ?? .distantPast) >= earliest && !config.repoExclusion.contains($0.repo) }
                    .map { IssueTiming($0, workflow: workflow, now: now) }
            }
            issuesFrom = sources.issues?.coveredFrom
        }

        /// How much of a period's target a cell is held to.
        private func share(_ period: DateInterval, _ measurable: Measurable, now: Date) -> Double {
            min(max(now.timeIntervalSince(period.start) / period.duration, 0), 1) * resolution.days / measurable.cadence.resolution.days
        }

        /// A hand-entered number: as entered by its own periods; added up
        /// (or averaged, for a percentage) in longer ones, unjudged; nothing
        /// in shorter ones.
        private func entered(_ measurable: Measurable, _ period: DateInterval, share: Double) -> Cell {
            let own = measurable.cadence.resolution
            if resolution == own {
                return Cell(value: measurable.values[Measurable.key(period.start)], count: nil, covered: true, share: share)
            }
            guard resolution.days > own.days else { return Cell(value: nil, count: nil, covered: true, share: share, judges: false) }
            let values = measurable.values.compactMap { key, value in Measurable.date(key).flatMap { period.contains($0) && $0 < period.end ? value : nil } }
            let total = values.reduce(0, +)
            let value = values.isEmpty ? nil : measurable.effectiveUnit == .percent ? total / Double(values.count) : total
            return Cell(value: value, count: nil, covered: true, share: share, judges: false)
        }

        func cells(for measurable: Measurable, now: Date = .now) -> [Cell] {
            let logins = measurable.team.flatMap { teams[$0] }.map { Set($0.members) }
            return periods.indices.map { index in
                let period = periods[index]
                let share = share(period, measurable, now: now)
                guard let metric = measurable.metric else { return entered(measurable, period, share: share) }
                return cell(metric, index: index, logins: logins, share: share, now: now)
            }
        }

        private func cell(_ metric: ScorecardMetric, index: Int, logins: Set<String>?, repo: String? = nil, share: Double, now: Date) -> Cell {
            guard let (raw, count) = measure(metric, index: index, logins: logins, repo: repo, now: now) else {
                return Cell(value: nil, count: nil, covered: false, share: share)
            }
            return Cell(value: raw.map(metric.display), count: count, covered: true, share: share)
        }

        /// One metric for one period, or nil when its source doesn't reach
        /// back that far (or hasn't been fetched).
        private func measure(_ metric: ScorecardMetric, index: Int, logins: Set<String>?, repo: String?, now: Date) -> (Double?, Int)? {
            let period = periods[index]
            func inTeam(_ login: String?) -> Bool { logins.map { login.map($0.contains) ?? false } ?? true }
            switch metric {
            case .flakyRuns:
                guard let runs, let runsFrom, runsFrom <= period.start else { return nil }
                let inPeriod = runs.filter { $0.createdAt >= period.start && $0.createdAt < period.end && (repo == nil || $0.repo == repo) }
                let retried = inPeriod.filter(\.passedOnRetry).count
                let decided = inPeriod.filter { $0.outcome == .success || $0.outcome == .failure }
                let mixed = Dictionary(grouping: decided) { "\($0.workflowKey) \($0.headSha)" }.values.filter { group in
                    group.contains { $0.outcome == .failure } && group.contains { $0.outcome == .success }
                }.count
                return (Double(retried + mixed), inPeriod.count)
            case .issueCycleTime:
                guard let issues, let issuesFrom, issuesFrom <= period.start else { return nil }
                let done = issues.filter { issue in
                    guard let closed = issue.record.closedAt, closed >= period.start, closed < period.end else { return false }
                    return logins.map { team in issue.record.assignees.contains(where: team.contains) } ?? true
                }
                let times = done.compactMap(\.cycleTime)
                return (DurationStat(times).median, times.count)
            case .slowReviews:
                guard coveredFrom.map({ $0 <= period.start }) ?? false else { return nil }
                var requests = 0
                var slow = 0
                for pr in pullRequests {
                    for request in pr.reviewRequests where request.requestedAt >= period.start && request.requestedAt < period.end && inTeam(request.login) {
                        let deadline = request.removedAt ?? pr.mergedAt
                        let response = pr.reviews.first { $0.login == request.login && $0.submittedAt >= request.requestedAt && $0.submittedAt <= deadline }
                        // Withdrawn before they got to it: not theirs to answer.
                        if response == nil && request.removedAt != nil { continue }
                        requests += 1
                        if (response?.submittedAt ?? deadline).timeIntervalSince(request.requestedAt) > Self.slowReview { slow += 1 }
                    }
                }
                // Still waiting on open PRs.
                for pr in openPullRequests {
                    for reviewer in pr.requestedReviewers where inTeam(reviewer.login) {
                        guard let asked = pr.reviewRequestedAt[reviewer.login], asked >= period.start, asked < period.end else { continue }
                        requests += 1
                        if now.timeIntervalSince(asked) > Self.slowReview { slow += 1 }
                    }
                }
                return (Double(slow), requests)
            case .openPullRequests:
                guard coveredFrom.map({ $0 <= period.start }) ?? false else { return nil }
                let at = min(period.end, now)
                let merged = pullRequests.filter { $0.createdAt <= at && $0.mergedAt > at && inTeam($0.author?.login) }.count
                let open = openPullRequests.filter { $0.createdAt <= at && inTeam($0.author?.login) }.count
                return (Double(merged + open), merged + open)
            default:
                guard coveredFrom.map({ $0 <= period.start }) ?? false else { return nil }
                let (raw, count) = Self.measure(metric, all: buckets[index], logins: logins, config: config)
                return (raw, count)
            }
        }

        /// Longer than this, a review request has waited too long.
        static let slowReview: TimeInterval = 24 * 60 * 60

        /// Who a metric's people are: authors for PR numbers and open PRs,
        /// reviewers for requests, assignees for issues; nobody for CI.
        private func logins(for metric: ScorecardMetric) -> Set<String> {
            var logins: Set<String> = []
            switch metric {
            case .flakyRuns:
                break
            case .issueCycleTime:
                for issue in issues ?? [] { logins.formUnion(issue.record.assignees) }
            case .answered, .slowReviews:
                for pr in pullRequests { logins.formUnion(pr.reviewRequests.map(\.login)) }
                if metric == .slowReviews {
                    for pr in openPullRequests { logins.formUnion(pr.requestedReviewers.map(\.login)) }
                }
            case .openPullRequests:
                logins.formUnion(pullRequests.compactMap { $0.author?.login })
                logins.formUnion(openPullRequests.compactMap { $0.author?.login })
            default:
                for bucket in buckets { logins.formUnion(bucket.compactMap { $0.author?.login }) }
            }
            return logins
        }

        /// A measurable's cells for each person behind it (within its team)
        /// with anything in the periods, or each repo with a flaky run for
        /// CI, in no particular order: the table sorts them by name.
        func people(for measurable: Measurable, now: Date = .now) -> [(key: String, cells: [Cell])] {
            guard let metric = measurable.metric else { return [] }
            if metric.byRepo {
                return Set(runs?.map(\.repo) ?? []).map { repo in
                    (key: repo, cells: periods.indices.map { index -> Cell in
                        cell(metric, index: index, logins: nil, repo: repo, share: share(periods[index], measurable, now: now), now: now)
                    })
                }
                .filter { row in row.cells.contains { ($0.value ?? 0) > 0 } }
            }
            var logins = logins(for: metric)
            if let team = measurable.team.flatMap({ teams[$0] }) { logins.formIntersection(team.members) }
            let rows = logins.map { login in
                (key: login, cells: periods.indices.map { index -> Cell in
                    cell(metric, index: index, logins: [login], share: share(periods[index], measurable, now: now), now: now)
                })
            }
            .filter { row in row.cells.contains { ($0.count ?? 0) > 0 } }
            return rows
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
                let needing = prs.filter { config.needsReview($0.repo) }
                return (needing.isEmpty ? nil : Double(needing.filter { $0.firstReviewAt == nil }.count) / Double(needing.count), needing.count)
            case .prSize:
                return (SizeStat(prs).median.map(Double.init), prs.count)
            case .prFiles:
                return (SizeStat(prs).medianFiles.map(Double.init), prs.filter { $0.changedFiles != nil }.count)
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
            case .slowReviews, .openPullRequests, .issueCycleTime, .flakyRuns:
                // Not from the PRs merged in the period: `measure(_:index:)`.
                return (nil, 0)
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
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    @Environment(AuthStore.self) private var auth
    let org: String
    @AppStorage("scorecardCadence") private var cadence: ScorecardCadence = .weekly
    @AppStorage("scorecardResolution") private var resolution: ScorecardResolution = .week
    @AppStorage("scorecardRanges") private var storedRanges = ""
    @AppStorage("scorecardGrouping") private var grouping: Grouping = .team
    @State private var editing: Measurable?
    @State private var adding = false
    @State private var search = ""
    @SceneStorage("scorecard.teams") private var teamFilter = ""
    @SceneStorage("scorecard.owners") private var ownerFilter = ""
    /// How far the table has scrolled sideways, so the name, target and
    /// hit columns stay put. Only they read it, so scrolling doesn't redraw
    /// the page.
    @State private var sticky = StickyScroll()

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
        let ofCadence = all.filter { $0.cadence == cadence }
        let measurables = ofCadence.filter { matches($0) }
        let range = self.range
        let usesMetrics = measurables.contains { !$0.isManual }
        let earliest = earliest(measurables)
        let periods = resolution.periods(count: range, earliest: earliest)
        let teams = orgs.snapshot(for: org)?.teams ?? []
        VStack(spacing: 0) {
            bar(all, ofCadence: ofCadence, teams: teams)
            Divider()
            if ofCadence.isEmpty {
                ContentUnavailableView {
                    Label("No \(cadence.title.lowercased()) goals", systemImage: "target")
                } description: {
                    Text("Add what the team looks at each \(cadence.noun): one of Gannin's delivery numbers with a target, or one you enter yourself, like costs.")
                } actions: {
                    Button("Add Goal") { adding = true }
                }
                .frame(maxHeight: .infinity)
            } else if measurables.isEmpty {
                ContentUnavailableView("No goals match", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxHeight: .infinity)
            } else {
                let history = metricsStore.history(for: org)
                let sources = Scorecard.Sources(
                    openPullRequests: orgs.snapshot(for: org)?.openPullRequests ?? [],
                    runs: actionsStore.history(for: org).map { Array($0.runs.values) },
                    issues: issueStore.history(for: org)
                )
                let data = Scorecard.Data(history: history, periods: periods, resolution: resolution, config: config, hidden: hidden.keys, teams: teams, sources: sources)
                // The tiles' last whole period, what it's compared with and
                // their sparklines, whatever the range.
                let latest = Scorecard.Data(history: history, periods: resolution.periods(count: 13, earliest: nil), resolution: resolution, config: config, hidden: hidden.keys, teams: teams, sources: sources)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        ScorecardTiles(measurables: measurables, data: latest, resolution: resolution)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 28) {
                                let sections = sections(measurables, teams: teams)
                                ForEach(sections) { section in
                                    sectionView(section, data: data, titled: sections.count > 1)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .scrollIndicators(.automatic)
                        .padding(.horizontal, -20)
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            geometry.contentOffset.x + geometry.contentInsets.leading
                        } action: { _, x in
                            sticky.x = max(0, x)
                        }
                        if usesMetrics, let note = coverageNote(periods) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .syncOffNotice(.metrics)
        .outsideReposNotice(org: org)
        .sheet(isPresented: $adding) {
            MeasurableEditor(org: org, measurable: nil, cadence: cadence)
        }
        .sheet(item: $editing) { measurable in
            MeasurableEditor(org: org, measurable: measurable, cadence: measurable.cadence)
        }
        .task(id: "\(org) \(resolution.rawValue) \(range) \(usesMetrics) \(Set(measurables.compactMap(\.metric)).map(\.rawValue).sorted())") {
            guard usesMetrics else { return }
            // All time reaches back to the org's first issue.
            if range == 0 { await issueStore.loadEarliestIssue(org) }
            let tiles = resolution.periods(count: 13, earliest: nil).last?.start ?? .now
            let start = min(range == 0 ? (issueStore.earliestIssue(org) ?? periods.last?.start ?? .now) : (periods.last?.start ?? .now), tiles)
            let days = Int(Date.now.timeIntervalSince(start) / 86_400) + 2
            let metrics = Set(measurables.compactMap(\.metric))
            async let merged: Void = metricsStore.sync(org, windowDays: days)
            // CI runs and the issue history only when a goal needs them.
            async let runs: Void = metrics.contains(.flakyRuns) ? actionsStore.sync(org, windowDays: days, excluding: config.unfetchedRepos) : ()
            async let issues: Void = metrics.contains(.issueCycleTime) ? issueStore.sync(org, windowDays: days) : ()
            _ = await (merged, runs, issues)
        }
    }

    /// The columns picked for this resolution, kept per resolution.
    private var range: Int {
        let saved = Dictionary(storedRanges.split(separator: ",").compactMap { pair -> (String, Int)? in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), Int(parts[1]) ?? 0) : nil
        }, uniquingKeysWith: { _, last in last })
        return saved[resolution.rawValue].flatMap { resolution.ranges.contains($0) ? $0 : nil } ?? resolution.defaultRange
    }

    private func setRange(_ value: Int) {
        var saved = Dictionary(storedRanges.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        saved[resolution.rawValue] = "\(value)"
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

    private var isNarrowed: Bool { !search.isEmpty || !teamFilter.isEmpty || !ownerFilter.isEmpty }

    /// Whether the search and the Team and Owner filters let it through.
    private func matches(_ measurable: Measurable, except key: String? = nil) -> Bool {
        let teams = StoredSet.set(teamFilter)
        let owners = StoredSet.set(ownerFilter)
        if key != "team", !teams.isEmpty, !teams.contains(measurable.team ?? "") { return false }
        if key != "owner", !owners.isEmpty, !owners.contains(measurable.owner ?? "") { return false }
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = [measurable.name, measurable.notes ?? "", measurable.metric?.title ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// The controls, as the PR and issue pages have them: search and
    /// filters, then the cadence, range, grouping and Add.
    private func bar(_ all: [Measurable], ofCadence: [Measurable], teams: [Team]) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Name or notes")
            teamMenu(ofCadence, teams: teams)
            ownerMenu(ofCadence)
            if isNarrowed {
                Button("Clear All") {
                    search = ""
                    teamFilter = ""
                    ownerFilter = ""
                }
                .linkButton()
            }
            Spacer(minLength: 0)
            Menu {
                Picker("Goals", selection: $cadence) {
                    ForEach(ScorecardCadence.allCases) { cadence in
                        let count = all.filter { $0.cadence == cadence }.count
                        Text("\(cadence.title) (\(count))").tag(cadence)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text("\(cadence.title) goals")
            }
            .fixedSize()
            .help("Goals with targets each week, month, quarter or year; the number is how many there are")
            Menu {
                Picker("View by", selection: $resolution) {
                    ForEach(ScorecardResolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("View by \(resolution.title)")
            }
            .fixedSize()
            .help("What the columns, tiles and trends are by. A count's target is held to the period: 20 a week is 2 a day.")
            Picker("Range", selection: Binding(get: { range }, set: { setRange($0) })) {
                ForEach(resolution.ranges, id: \.self) { Text(resolution.rangeTitle($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("How far back. All time goes back to the org's first issue, which takes a while to fetch the first time.")
            Menu {
                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(grouping == .none ? "No grouping" : "Group by \(grouping.rawValue)")
            }
            .fixedSize()
            Button {
                adding = true
            } label: {
                Label("Add Goal", systemImage: "plus")
            }
            .help("Something to track each \(cadence.noun): a delivery number or one you enter")
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Only when there's a choice: measurables in more than one team, or
    /// one already picked.
    @ViewBuilder
    private func teamMenu(_ measurables: [Measurable], teams: [Team]) -> some View {
        let counts = Dictionary(grouping: measurables.filter { matches($0, except: "team") }) { $0.team ?? "" }.mapValues(\.count)
        let orgName = orgs.org(login: org)?.displayName ?? org
        let options = counts.map { slug, count in
            FilterOption(value: slug, title: slug.isEmpty ? orgName : teams.first { $0.slug == slug }?.name ?? slug, count: count)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if options.count > 1 || !teamFilter.isEmpty {
            FilterMenu(title: "Team", options: options, picked: Binding(get: { StoredSet.set(teamFilter) }, set: { teamFilter = StoredSet.string($0) }))
        }
    }

    /// Only when there's a choice, as with teams.
    @ViewBuilder
    private func ownerMenu(_ measurables: [Measurable]) -> some View {
        let counts = Dictionary(grouping: measurables.filter { matches($0, except: "owner") }) { $0.owner ?? "" }.mapValues(\.count)
        let members = orgs.snapshot(for: org)?.members ?? []
        let me = auth.viewer?.login
        let leading = [
            me.flatMap { me in counts[me].map { FilterOption(value: me, title: "Me", count: $0) } },
            counts[""].map { FilterOption(value: "", title: "No owner", count: $0) },
        ].compactMap { $0 }
        let options = counts.filter { !$0.key.isEmpty && $0.key != me }
            .map { login, count in FilterOption(value: login, title: members.first { $0.login == login }?.displayName ?? login, count: count) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if leading.count + options.count > 1 || !ownerFilter.isEmpty {
            FilterMenu(title: "Owner", leading: leading, options: options, picked: Binding(get: { StoredSet.set(ownerFilter) }, set: { ownerFilter = StoredSet.string($0) }))
        }
    }

    /// A group's table, under its name when there's more than one.
    private func sectionView(_ section: Section, data: Scorecard.Data, titled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if titled {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol).foregroundStyle(.secondary)
                    Text(section.title).font(.title3.weight(.semibold))
                }
                .following(sticky)
            }
            VStack(spacing: 0) {
                headerRow(data.periods)
                ForEach(section.measurables) { measurable in
                    Divider()
                    MeasurableRow(org: org, measurable: measurable, data: data, members: orgs.snapshot(for: org)?.members ?? [], teamName: teamName(measurable), sticky: sticky) {
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
            HStack(spacing: 0) {
                Text("NAME").frame(width: Self.nameWidth - 14, alignment: .leading).padding(.leading, 28)
                Text("TARGET").frame(width: Self.targetWidth, alignment: .leading)
                Text("HIT").frame(width: Self.hitWidth).help("Whole periods on target, of those measured")
            }
            .frame(height: 40)
            .stuck(sticky)
            ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                Text(resolution.heading(period))
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

/// How far the scorecard's table has scrolled sideways. Its own object,
/// read only by the modifiers below, so a scroll moves the left columns
/// without working out the rest of the page again.
@Observable
final class StickyScroll {
    var x: CGFloat = 0
}

/// The left columns, shifted along as the table scrolls so they stay in
/// view, over the cells they pass, with an edge once they've moved.
private struct Stuck: ViewModifier {
    let scroll: StickyScroll

    func body(content: Content) -> some View {
        let x = scroll.x
        content
            .background(.background)
            .overlay(alignment: .trailing) {
                if x > 0 { Color.separatorLine.frame(width: 1) }
            }
            .offset(x: x)
            .zIndex(1)
    }
}

/// Shifted along as the table scrolls, with nothing behind it.
private struct Following: ViewModifier {
    let scroll: StickyScroll

    func body(content: Content) -> some View {
        content.offset(x: scroll.x)
    }
}

private extension View {
    func stuck(_ scroll: StickyScroll) -> some View { modifier(Stuck(scroll: scroll)) }
    func following(_ scroll: StickyScroll) -> some View { modifier(Following(scroll: scroll)) }
}

/// A measurable's row: its name, target and hit rate, then a cell per
/// period; a hand-entered one's cells take a value when clicked.
private struct MeasurableRow: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    let org: String
    let measurable: Measurable
    let data: Scorecard.Data
    let members: [Person]
    let teamName: String?
    /// How far to shift the name, target and hit columns to keep them in
    /// view.
    let sticky: StickyScroll
    let edit: () -> Void
    /// Showing a row per person beneath, for one of Gannin's numbers.
    @State private var expanded = false

    private static let disclosureWidth: CGFloat = 22

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
    }

    var body: some View {
        let cells = data.cells(for: measurable)
        VStack(spacing: 0) {
            row(cells)
            if expanded {
                people()
            }
        }
    }

    private func row(_ cells: [Scorecard.Cell]) -> some View {
        // Whole periods only: the one under way is still moving.
        let judged = cells.dropFirst().compactMap { $0.meets(measurable) }
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if measurable.isManual {
                        Color.clear
                    } else {
                        Button(action: toggle) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: Self.disclosureWidth, height: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide people" : "Show each person")
                    }
                }
                .frame(width: Self.disclosureWidth)
                .padding(.leading, 6)
                Button(action: measurable.isManual ? edit : toggle) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(measurable.name)
                            if measurable.isManual {
                                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary).help("Entered by hand")
                            }
                        }
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: ScorecardView.nameWidth + 8 - Self.disclosureWidth, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(measurable.notes ?? (measurable.isManual ? "Edit this goal" : expanded ? "Hide the breakdown" : "Show each \(measurable.metric?.byRepo == true ? "repo" : "person"); right-click to edit"))
                Text(target ?? "No target")
                    .foregroundStyle(measurable.target == nil ? .secondary : .primary)
                    .frame(width: ScorecardView.targetWidth, alignment: .leading)
                    .help(measurable.targetText.map { "\($0) each \(measurable.cadence.noun)" } ?? "")
                Text(judged.isEmpty ? "" : "\(judged.filter { $0 }.count)/\(judged.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: ScorecardView.hitWidth)
            }
            .frame(height: 48)
            .stuck(sticky)
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if measurable.isManual {
                    ManualCell(org: org, measurable: measurable, period: data.periods[index], cell: cell, isCurrent: index == 0)
                } else {
                    MetricCell(measurable: measurable, cell: cell, isCurrent: index == 0)
                }
            }
        }
        .font(.callout)
        .contextMenu {
            Button("Edit") { edit() }
            if let metric = measurable.metric {
                Button(expanded ? "Hide \(metric.byRepo ? "Repos" : "People")" : "Show \(metric.byRepo ? "Repos" : "People")", action: toggle)
            }
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

    /// A row per person behind the number (the author, the reviewer for
    /// requests, the assignee for issues) by name, held to the target as a
    /// person would be: a count like PRs merged is the team's, so not judged.
    @ViewBuilder
    private func people() -> some View {
        let byLogin = Dictionary(members.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        let byRepo = measurable.metric?.byRepo == true
        let name: (String) -> String = { key in byRepo ? Self.shortRepo(key) : byLogin[key]?.displayName ?? key }
        let rows = data.people(for: measurable).sorted {
            name($0.key).localizedCaseInsensitiveCompare(name($1.key)) == .orderedAscending
        }
        let personal = measurable.personal
        if rows.isEmpty {
            Divider()
            Text(measurable.metric?.byRepo == true ? "No flaky runs in these periods." : "Nobody to show in these periods yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 34)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .stuck(sticky)
        }
        ForEach(rows, id: \.key) { entry in
            Divider()
            let person = byLogin[entry.key] ?? Person(login: entry.key, name: nil, avatarUrl: nil)
            let judged = entry.cells.dropFirst().compactMap { $0.meets(personal) }
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        navigate?(byRepo ? .actionsRepository(entry.key) : .metric(.personStats(entry.key)))
                    } label: {
                        HStack(spacing: 8) {
                            if byRepo {
                                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                            } else {
                                Avatar(url: person.avatarUrl, size: 18)
                            }
                            Text(name(entry.key)).lineLimit(1)
                        }
                        .frame(width: ScorecardView.nameWidth - 20, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 34)
                    .help(byRepo ? "Open \(entry.key)'s CI" : "Open \(person.displayName)'s PRs and reviews")
                    Text(personal.target == nil ? "" : (target ?? ""))
                        .foregroundStyle(.secondary)
                        .frame(width: ScorecardView.targetWidth, alignment: .leading)
                    Text(judged.isEmpty ? "" : "\(judged.filter { $0 }.count)/\(judged.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: ScorecardView.hitWidth)
                }
                .frame(height: 36)
                .stuck(sticky)
                ForEach(Array(entry.cells.enumerated()), id: \.offset) { index, cell in
                    MetricCell(measurable: personal, cell: cell, isCurrent: index == 0, height: 36)
                }
            }
            .font(.callout)
            .background(Color.secondary.opacity(0.04))
        }
    }

    static func shortRepo(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    /// Held to the columns' periods: a weekly 20 is 2 a day.
    private var target: String? {
        let cells = data.cells(for: measurable)
        guard cells.count > 1, cells[1].judges else { return measurable.targetText }
        return measurable.targetText(share: cells[1].share)
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
    var height: CGFloat = 48

    var body: some View {
        let met = cell.meets(measurable)
        Text(cell.value.map(measurable.format) ?? (cell.covered ? "N/A" : "-"))
            .fontWeight(met == nil ? .regular : .semibold)
            .foregroundStyle(met.map { $0 ? ChartPalette.good : ChartPalette.critical } ?? .secondary)
            .monospacedDigit()
            .frame(width: ScorecardView.cellWidth, height: height)
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
        let met = cell.meets(measurable)
        if !cell.judges {
            Text(cell.value.map(measurable.format) ?? "-")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ScorecardView.cellWidth, height: 48)
                .background(isCurrent ? Color.secondary.opacity(0.1) : .clear)
                .help("Entered each \(measurable.cadence.noun)\(cell.value == nil ? "" : ", added up"): view by \(measurable.cadence.noun) to enter or judge it")
        } else {
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
