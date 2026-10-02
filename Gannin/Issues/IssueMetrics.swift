import Foundation

/// One issue's time in progress under the org's workflow.
struct IssueTiming: Identifiable {
    let record: IssueRecord
    /// Spells in an in-progress status (or, falling back, from the first
    /// linked PR to the close). An open spell runs to now.
    let intervals: [DateInterval]
    /// In progress right now (open issues only).
    let isInProgress: Bool
    /// The latest status on the counted project, if any.
    let currentStatus: String?

    var id: String { record.id }

    var start: Date? { intervals.first?.start }

    /// Total time in progress, Swarmia style: pauses don't count.
    var cycleTime: TimeInterval? {
        intervals.isEmpty ? nil : intervals.map(\.duration).reduce(0, +)
    }

    var leadTime: TimeInterval? {
        record.closedAt.map { $0.timeIntervalSince(record.createdAt) }
    }

    /// Share of in-progress days with a commit or review on a linked PR;
    /// nil without linked PRs to judge by.
    var flowEfficiency: Double? {
        guard !intervals.isEmpty, !record.linkedPullRequests.isEmpty else { return nil }
        let calendar = Calendar.current
        var spanned = Set<Date>()
        for interval in intervals {
            var day = calendar.startOfDay(for: interval.start)
            while day <= interval.end {
                spanned.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        guard !spanned.isEmpty else { return nil }
        let active = Set(record.linkedPullRequests.flatMap(\.activityAt).map { calendar.startOfDay(for: $0) })
        return Double(spanned.intersection(active).count) / Double(spanned.count)
    }

    /// Share of sub-issues added after work started; nil without sub-issues.
    var scopeCreep: Double? {
        guard let start, !record.subIssuesAddedAt.isEmpty else { return nil }
        let late = record.subIssuesAddedAt.filter { $0 > start }.count
        return Double(late) / Double(record.subIssuesAddedAt.count)
    }

    init(_ record: IssueRecord, workflow: IssueWorkflow, now: Date) {
        self.record = record
        let end = record.closedAt ?? now
        let changes = record.statusChanges.filter(workflow.counts)
        currentStatus = changes.last?.status

        var intervals: [DateInterval] = []
        var openedAt: Date?
        for change in changes {
            if workflow.isInProgress(change.status) {
                if openedAt == nil { openedAt = change.at }
            } else if let started = openedAt {
                intervals.append(DateInterval(start: started, end: max(started, change.at)))
                openedAt = nil
            }
        }
        if let started = openedAt, started < end {
            intervals.append(DateInterval(start: started, end: end))
        }

        var inProgress = record.isOpen && openedAt != nil
        if intervals.isEmpty, workflow.fallBackToPullRequests,
           let first = record.linkedPullRequests.map(\.createdAt).min(), first < end {
            // Open issues only count as in progress while a linked PR is open.
            if record.isOpen {
                inProgress = record.linkedPullRequests.contains { $0.state == "OPEN" }
                if inProgress { intervals = [DateInterval(start: first, end: end)] }
            } else {
                intervals = [DateInterval(start: first, end: end)]
            }
        }
        self.intervals = intervals
        isInProgress = inProgress
    }
}

/// Issue metrics for one window, optionally scoped to a team (by assignee).
struct IssueMetrics {
    enum Grouping: String, CaseIterable, Identifiable {
        case type = "Type"
        case label = "Label"
        case repository = "Repository"

        var id: Self { self }
    }

    enum Granularity: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case quarter = "Quarter"
        /// Investments over all time only.
        case year = "Year"

        var id: Self { self }

        func start(of date: Date) -> Date {
            switch self {
            case .day: return Calendar.current.startOfDay(for: date)
            case .week: return Calendar.metrics.startOfWeek(for: date)
            case .month: return Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
            case .quarter:
                let calendar = Calendar.current
                var parts = calendar.dateComponents([.year, .month], from: date)
                parts.month = ((parts.month ?? 1) - 1) / 3 * 3 + 1
                return calendar.date(from: parts) ?? date
            case .year: return Calendar.current.dateInterval(of: .year, for: date)?.start ?? date
            }
        }

        /// Axis labels for a period.
        var axisFormat: Date.FormatStyle {
            switch self {
            case .quarter: .dateTime.quarter().year(.twoDigits)
            case .year: .dateTime.year()
            case .month: .dateTime.month(.abbreviated).year(.twoDigits)
            default: .dateTime.day().month()
            }
        }

        func next(after start: Date) -> Date {
            let (component, value): (Calendar.Component, Int) = switch self {
            case .day: (.day, 1)
            case .week: (.weekOfYear, 1)
            case .month: (.month, 1)
            case .quarter: (.month, 3)
            case .year: (.year, 1)
            }
            return Calendar.current.date(byAdding: component, value: value, to: start) ?? start.addingTimeInterval(86_400)
        }
    }

    /// Issues opened and closed in a period, and how many were open at its end.
    struct Bucket: Identifiable {
        let start: Date
        let opened: Int
        let closed: Int
        let openAtEnd: Int

        var id: Date { start }
    }

    struct Group: Identifiable {
        let name: String
        let completed: Int
        let cycleTime: DurationStat
        let inProgress: Int
        let notPlanned: Int

        var id: String { name }
    }

    let windowStart: Date
    let completed: [IssueTiming]
    let notPlanned: [IssueRecord]
    let reopened: Int
    let inProgress: [IssueTiming]
    let cycleTime: DurationStat
    let leadTime: DurationStat
    let flowEfficiency: Double?
    let scopeCreep: Double?
    /// Issues in progress at midday on each day of the window.
    let wip: [(day: Date, count: Int)]
    /// Statuses seen on the counted project, with how many changes into each.
    let statusesSeen: [(status: String, count: Int)]
    let projectsSeen: [(number: Int, title: String)]
    private let all: [IssueTiming]
    private let records: [IssueRecord]

    init(history: IssueHistory, window: MetricsWindow, team: Team?, config: OrgConfig, now: Date = .now) {
        let workflow = config.workflow
        let calendar = Calendar.current
        let interval = window.interval(now: now)
        let windowStart = interval.start
        let end = interval.end
        self.windowStart = windowStart
        let teamLogins = team.map { Set($0.members) }

        let records = history.issues.values.filter { record in
            !config.excludedRepos.contains(record.repo)
                && (teamLogins.map { logins in record.assignees.contains(where: logins.contains) } ?? true)
        }
        let all = records.map { IssueTiming($0, workflow: workflow, now: now) }
        self.all = all
        self.records = records

        completed = all
            .filter { $0.record.isCompleted && interval.contains($0.record.closedAt ?? .distantPast) && ($0.record.closedAt ?? .distantPast) < end }
            .sorted { ($0.record.closedAt ?? .distantPast) > ($1.record.closedAt ?? .distantPast) }
        notPlanned = records.filter { $0.isNotPlanned && interval.contains($0.closedAt ?? .distantPast) && ($0.closedAt ?? .distantPast) < end }
        reopened = records.flatMap(\.reopenedAt).filter { $0 >= windowStart && $0 < end }.count
        inProgress = all.filter(\.isInProgress).sorted { ($0.start ?? now) < ($1.start ?? now) }
        cycleTime = DurationStat(completed.compactMap(\.cycleTime))
        leadTime = DurationStat(completed.compactMap(\.leadTime))
        flowEfficiency = DurationStat(completed.compactMap(\.flowEfficiency)).median
        let creep = completed.compactMap(\.scopeCreep)
        scopeCreep = creep.isEmpty ? nil : creep.reduce(0, +) / Double(creep.count)

        var wip: [(Date, Int)] = []
        var day = calendar.startOfDay(for: windowStart)
        while day <= end {
            let noon = day.addingTimeInterval(12 * 60 * 60)
            wip.append((day, all.filter { $0.intervals.contains { $0.contains(noon) } }.count))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.wip = wip

        let changes = records.flatMap(\.statusChanges)
        statusesSeen = Dictionary(grouping: changes.filter(workflow.counts), by: \.status)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        var projects: [Int: String] = [:]
        for change in changes {
            if let number = change.projectNumber { projects[number] = change.projectTitle ?? "Project \(number)" }
        }
        projectsSeen = projects.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 }
    }

    /// Opened, closed (for any reason) and open at the end of each period
    /// since the window started. Open counts are exact from the window's
    /// start: the history holds every open issue and all closed since then.
    func buckets(_ granularity: Granularity, now: Date = .now) -> [Bucket] {
        var buckets: [Bucket] = []
        var start = granularity.start(of: windowStart)
        while start <= now {
            let end = granularity.next(after: start)
            let at = min(end, now)
            buckets.append(Bucket(
                start: start,
                opened: records.filter { $0.createdAt >= start && $0.createdAt < end }.count,
                closed: records.filter { ($0.closedAt ?? .distantFuture) >= start && ($0.closedAt ?? .distantFuture) < end }.count,
                openAtEnd: records.filter { $0.createdAt <= at && ($0.closedAt.map { $0 > at } ?? true) }.count
            ))
            start = end
        }
        return buckets
    }

    var notPlannedShare: Double? {
        let closed = completed.count + notPlanned.count
        return closed == 0 ? nil : Double(notPlanned.count) / Double(closed)
    }

    /// Completed, cycle time, in progress and not planned per type, label or
    /// repo. An issue with several labels counts under each.
    func groups(by grouping: Grouping) -> [Group] {
        func keys(_ record: IssueRecord) -> [String] {
            switch grouping {
            case .type: [record.issueType ?? "No type"]
            case .label: record.labels.isEmpty ? ["No label"] : record.labels
            case .repository: [record.repo.split(separator: "/").last.map(String.init) ?? record.repo]
            }
        }
        var completedBy: [String: [IssueTiming]] = [:]
        for timing in completed { for key in keys(timing.record) { completedBy[key, default: []].append(timing) } }
        var inProgressBy: [String: Int] = [:]
        for timing in inProgress { for key in keys(timing.record) { inProgressBy[key, default: 0] += 1 } }
        var notPlannedBy: [String: Int] = [:]
        for record in notPlanned { for key in keys(record) { notPlannedBy[key, default: 0] += 1 } }
        let names = Set(completedBy.keys).union(inProgressBy.keys).union(notPlannedBy.keys)
        return names.map { name in
            Group(
                name: name,
                completed: completedBy[name]?.count ?? 0,
                cycleTime: DurationStat((completedBy[name] ?? []).compactMap(\.cycleTime)),
                inProgress: inProgressBy[name] ?? 0,
                notPlanned: notPlannedBy[name] ?? 0
            )
        }
        .sorted { ($0.completed + $0.inProgress, $1.name) > ($1.completed + $1.inProgress, $0.name) }
    }
}
