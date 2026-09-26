import Foundation

/// How the balance is measured.
enum InvestmentUnit: String, CaseIterable, Identifiable {
    case days = "Engineer-days"
    case pullRequests = "PRs"

    var id: Self { self }

    var help: String {
        switch self {
        case .days: "Approximate effort. Each merged PR counts its author's working days from first commit to merge (at most \(InvestmentBalance.maxDaysPerPullRequest)), and a day is shared between PRs the same author had open."
        case .pullRequests: "Merged PRs, each counting once."
        }
    }
}

/// Where effort went over a metrics window, by investment category.
struct InvestmentBalance {
    enum Key: Hashable {
        case category(UUID)
        case uncategorised

        /// For `MetricDrill`, which needs plain hashable values.
        var drillID: String {
            switch self {
            case .category(let id): id.uuidString
            case .uncategorised: "uncategorised"
            }
        }
    }

    struct Share: Identifiable {
        let key: Key
        let name: String
        /// Palette slot; nil for uncategorised.
        let slot: Int?
        var pullRequests: [MetricPullRequest] = []
        var days: Double = 0

        var id: Key { key }

        func value(_ unit: InvestmentUnit) -> Double {
            unit == .days ? days : Double(pullRequests.count)
        }
    }

    struct Week: Identifiable {
        let start: Date
        var pullRequests: [Key: Int] = [:]
        var days: [Key: Double] = [:]

        var id: Date { start }

        func value(_ key: Key, _ unit: InvestmentUnit) -> Double {
            unit == .days ? days[key] ?? 0 : Double(pullRequests[key] ?? 0)
        }
    }

    /// A PR open for months with the odd commit isn't months of work; like
    /// Swarmia's cut-off for idle work, only the last working days count.
    static let maxDaysPerPullRequest = 10

    /// Categories in their configured order, then uncategorised.
    let shares: [Share]
    let weeks: [Week]
    /// Where each PR in the stored range landed, and why.
    let placements: [String: (key: Key, source: InvestmentConfig.Source?)]

    init(metrics: OrgMetrics, config: InvestmentConfig, now: Date = .now) {
        let calendar = Calendar.metrics
        var placements: [String: (key: Key, source: InvestmentConfig.Source?)] = [:]
        for pr in metrics.coverage {
            if let (category, source) = config.categorise(pr) {
                placements[pr.id] = (.category(category.id), source)
            } else {
                placements[pr.id] = (.uncategorised, nil)
            }
        }
        self.placements = placements

        var shares = config.categories.map { Share(key: .category($0.id), name: $0.name, slot: $0.slot) }
        shares.append(Share(key: .uncategorised, name: "Uncategorised", slot: nil))
        let index = Dictionary(uniqueKeysWithValues: shares.enumerated().map { ($1.key, $0) })
        func key(_ pr: MetricPullRequest) -> Key { placements[pr.id]?.key ?? .uncategorised }

        for pr in metrics.merged {
            if let i = index[key(pr)] { shares[i].pullRequests.append(pr) }
        }

        var weeks = Dictionary(uniqueKeysWithValues: metrics.weeks.map { ($0.start, Week(start: $0.start)) })
        for pr in metrics.coverage {
            weeks[calendar.startOfWeek(for: pr.mergedAt)]?.pullRequests[key(pr), default: 0] += 1
        }

        // Engineer-days: each author's working day is split evenly across
        // the PRs they had on the go that day.
        var workingDays: [String: [Date]] = [:]
        var byAuthorDay: [String: [Date: Int]] = [:]
        for pr in metrics.coverage {
            let days = Self.workingDays(of: pr, calendar: calendar)
            workingDays[pr.id] = days
            let author = pr.author?.login ?? ""
            for day in days { byAuthorDay[author, default: [:]][day, default: 0] += 1 }
        }
        let windowStart = calendar.startOfDay(for: metrics.windowStart)
        for pr in metrics.coverage {
            let author = pr.author?.login ?? ""
            let prKey = key(pr)
            for day in workingDays[pr.id] ?? [] {
                let share = 1 / Double(byAuthorDay[author]?[day] ?? 1)
                weeks[calendar.startOfWeek(for: day)]?.days[prKey, default: 0] += share
                if day >= windowStart, day <= now, let i = index[prKey] {
                    shares[i].days += share
                }
            }
        }

        self.shares = shares
        self.weeks = weeks.values.sorted { $0.start < $1.start }
    }

    func total(_ unit: InvestmentUnit) -> Double {
        shares.map { $0.value(unit) }.reduce(0, +)
    }

    /// Share of the total that has a category, 0-1.
    func categorised(_ unit: InvestmentUnit) -> Double {
        let total = total(unit)
        guard total > 0 else { return 0 }
        let uncategorised = shares.first { $0.key == .uncategorised }?.value(unit) ?? 0
        return (total - uncategorised) / total
    }

    /// Weekdays from first commit (or creation, if earlier) to merge, the
    /// last `maxDaysPerPullRequest` of them.
    static func workingDays(of pr: MetricPullRequest, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: min(pr.firstCommitAt ?? pr.createdAt, pr.createdAt))
        var day = calendar.startOfDay(for: pr.mergedAt)
        var days: [Date] = []
        while day >= start && days.count < maxDaysPerPullRequest {
            if !calendar.isDateInWeekend(day) { days.append(day) }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        // A PR opened and merged at the weekend still took a day.
        return days.isEmpty ? [calendar.startOfDay(for: pr.mergedAt)] : days
    }
}
