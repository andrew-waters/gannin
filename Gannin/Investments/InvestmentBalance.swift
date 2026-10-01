import Foundation

/// A span of time for the Investments page.
enum InvestmentRange: String, CaseIterable, Identifiable {
    case last30 = "Last 30 days"
    case last90 = "Last 90 days"
    case thisQuarter = "This quarter"
    case lastQuarter = "Last quarter"
    case thisYear = "This year"
    /// From the org's first issue.
    case allTime = "All time"
    case custom = "Custom"

    var id: Self { self }

    /// The span, ending today for the rolling ones. Custom uses the dates given.
    /// `earliest` is the org's first issue, for All time (a year back until
    /// it's known).
    func interval(customFrom: Date, customTo: Date, earliest: Date? = nil, now exactly: Date = .now) -> DateInterval {
        // To the minute, so a rolling range (and the drill-down it opens)
        // stays equal across redraws.
        let now = Date(timeIntervalSince1970: (exactly.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let calendar = Calendar.current
        let quarter = IssueMetrics.Granularity.quarter
        switch self {
        case .last30: return DateInterval(start: calendar.date(byAdding: .day, value: -30, to: now) ?? now, end: now)
        case .last90: return DateInterval(start: calendar.date(byAdding: .day, value: -90, to: now) ?? now, end: now)
        case .thisQuarter: return DateInterval(start: quarter.start(of: now), end: now)
        case .lastQuarter:
            let thisStart = quarter.start(of: now)
            let lastStart = calendar.date(byAdding: .month, value: -3, to: thisStart) ?? thisStart
            return DateInterval(start: lastStart, end: thisStart)
        case .thisYear:
            return DateInterval(start: calendar.dateInterval(of: .year, for: now)?.start ?? now, end: now)
        case .allTime:
            let start = calendar.startOfDay(for: earliest ?? calendar.date(byAdding: .year, value: -1, to: now) ?? now)
            return DateInterval(start: min(start, now), end: now)
        case .custom:
            let start = calendar.startOfDay(for: min(customFrom, customTo))
            let end = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo))) ?? now, now)
            return DateInterval(start: start, end: max(start, end))
        }
    }
}

/// Issues by investment category over a range: those completed in it, and
/// those in progress at its end, bucketed by week, month or quarter.
struct InvestmentBalance {
    enum Key: Hashable {
        case category(UUID)
        case uncategorised
    }

    /// What a drill-down column shows: one category's issues for a scope,
    /// range and (optionally) period. It's recomputed from the live history
    /// and config, so edits move issues between lists at once.
    struct Drill: Hashable {
        let key: Key
        let scope: Scope
        let range: DateInterval
        let period: IssueMetrics.Granularity
        let bucket: Date?
        let title: String
    }

    /// The issues a drill shows, as things stand.
    func issues(for drill: Drill) -> [IssueRecord] {
        shares(drill.scope, bucket: drill.bucket).first { $0.key == drill.key }?.issues ?? []
    }

    enum Scope: String, CaseIterable, Identifiable {
        case completed = "Completed"
        case inProgress = "In progress"
        /// Both: completed in the range, and in progress at its end.
        case all = "All"

        var id: Self { self }

        /// Its issues include those completed, so the chart applies.
        var hasCompleted: Bool { self != .inProgress }
    }

    /// The scope's issues by category. For All, those completed and those in
    /// progress, each once; a period picked on the chart narrows it to what
    /// was completed in that period.
    func shares(_ scope: Scope, bucket: Date?) -> [Share] {
        switch scope {
        case .completed: return completed(in: bucket)
        case .inProgress: return inProgress
        case .all:
            guard bucket == nil else { return completed(in: bucket) }
            return zip(completed(), inProgress).map { done, going in
                var share = done
                let ids = Set(done.issues.map(\.id))
                share.issues += going.issues.filter { !ids.contains($0.id) }
                return share
            }
        }
    }

    struct Share: Identifiable {
        let key: Key
        let name: String
        /// Palette slot; nil for uncategorised.
        let slot: Int?
        var issues: [IssueRecord] = []

        var id: Key { key }
    }

    struct Bucket: Identifiable {
        let start: Date
        let end: Date
        var completed: [Key: [IssueRecord]] = [:]

        var id: Date { start }

        func count(_ key: Key) -> Int { completed[key]?.count ?? 0 }
        var total: Int { completed.values.map(\.count).reduce(0, +) }
    }

    let range: DateInterval
    let categories: [(key: Key, name: String, slot: Int?)]
    let buckets: [Bucket]
    /// In progress at the range's end, by category.
    let inProgress: [Share]
    /// Why each issue landed where it did.
    let placements: [String: (key: Key, source: InvestmentConfig.Source?)]

    init(history: IssueHistory, config: OrgConfig, team: Team?, range: DateInterval, granularity: IssueMetrics.Granularity, now: Date = .now) {
        self.range = range
        let investments = config.investmentConfig
        let teamLogins = team.map { Set($0.members) }
        let records = history.issues.values.filter { record in
            !config.excludedRepos.contains(record.repo)
                && (teamLogins.map { logins in record.assignees.contains(where: logins.contains) } ?? true)
        }

        var placements: [String: (key: Key, source: InvestmentConfig.Source?)] = [:]
        for record in records {
            let parent = record.parentID.flatMap { history.issues[$0] }
            if let (category, source) = investments.categorise(record, parent: parent) {
                placements[record.id] = (.category(category.id), source)
            } else {
                placements[record.id] = (.uncategorised, nil)
            }
        }
        self.placements = placements
        func key(_ record: IssueRecord) -> Key { placements[record.id]?.key ?? .uncategorised }

        categories = investments.categories.map { (Key.category($0.id), $0.name, Optional($0.slot)) }
            + [(Key.uncategorised, "Uncategorised", nil)]

        var buckets: [Bucket] = []
        var start = granularity.start(of: range.start)
        while start < range.end {
            let end = granularity.next(after: start)
            buckets.append(Bucket(start: start, end: end))
            start = end
        }
        for record in records where record.isCompleted {
            guard let closedAt = record.closedAt, range.contains(closedAt),
                  let index = buckets.lastIndex(where: { $0.start <= closedAt }) else { continue }
            buckets[index].completed[key(record), default: []].append(record)
        }
        self.buckets = buckets

        // In progress at the range's end, under the org's workflow.
        let at = min(range.end, now)
        var inProgress = categories.map { Share(key: $0.key, name: $0.name, slot: $0.slot) }
        let index = Dictionary(uniqueKeysWithValues: inProgress.enumerated().map { ($1.key, $0) })
        for record in records {
            let timing = IssueTiming(record, workflow: config.workflow, now: now)
            let isInProgress = at >= now ? timing.isInProgress : timing.intervals.contains { $0.contains(at) }
            if isInProgress, let i = index[key(record)] { inProgress[i].issues.append(record) }
        }
        self.inProgress = inProgress
    }

    /// Completed issues by category, over the whole range or one bucket.
    func completed(in bucket: Date? = nil) -> [Share] {
        let chosen = bucket.map { start in buckets.filter { $0.start == start } } ?? buckets
        return categories.map { category in
            Share(key: category.key, name: category.name, slot: category.slot, issues: chosen.flatMap { $0.completed[category.key] ?? [] })
        }
    }
}
