import Foundation

/// Median, p75 and 90th percentile, as CI tools quote run times: the
/// typical run and the slow tail people wait on.
nonisolated struct PercentileStat: Hashable {
    let median: TimeInterval?
    let p75: TimeInterval?
    let p90: TimeInterval?
    let count: Int

    init(_ values: [TimeInterval]) {
        let sorted = values.sorted()
        count = sorted.count
        median = Self.percentile(sorted, 0.5)
        p75 = Self.percentile(sorted, 0.75)
        p90 = Self.percentile(sorted, 0.9)
    }

    static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}

/// Counts of how runs ended, and the rates derived from them. Cancelled and
/// skipped runs are counted but left out of the failure rate.
nonisolated struct OutcomeCounts: Hashable {
    var succeeded = 0
    var failed = 0
    var cancelled = 0
    var skipped = 0
    var running = 0

    init() {}

    init(_ runs: some Sequence<WorkflowRun>) {
        for run in runs { add(run.outcome) }
    }

    mutating func add(_ outcome: RunOutcome) {
        switch outcome {
        case .success: succeeded += 1
        case .failure: failed += 1
        case .cancelled: cancelled += 1
        case .skipped: skipped += 1
        case .running: running += 1
        }
    }

    /// Runs that did something: everything but skipped.
    var ran: Int { succeeded + failed + cancelled + running }

    /// Failed out of those that passed or failed.
    var failureRate: Double? {
        let decided = succeeded + failed
        return decided == 0 ? nil : Double(failed) / Double(decided)
    }

    var successRate: Double? { failureRate.map { 1 - $0 } }
}

/// Durations bucketed as CI tools show them: up to a minute, 5, 10, 20 and
/// 60 minutes, and longer.
nonisolated struct DurationHistogram: Hashable {
    static let bounds: [TimeInterval] = [60, 300, 600, 1200, 3600]
    static let labels = ["60s", "5min", "10min", "20min", "60min", "60min+"]

    let counts: [Int]

    init(_ durations: [TimeInterval]) {
        var counts = Array(repeating: 0, count: Self.labels.count)
        for duration in durations {
            counts[Self.bounds.firstIndex { duration <= $0 } ?? Self.bounds.count] += 1
        }
        self.counts = counts
    }

    static func bucket(_ duration: TimeInterval) -> Int {
        bounds.firstIndex { duration <= $0 } ?? bounds.count
    }
}

/// The headline measures over some runs: the window's, or the period
/// before it for comparison.
nonisolated struct PeriodSummary: Hashable {
    let runs: Int
    let runTime: TimeInterval
    let counts: OutcomeCounts
    let duration: PercentileStat

    init(_ runs: some Collection<WorkflowRun>) {
        let durations = runs.compactMap(\.duration)
        self.runs = runs.count
        runTime = durations.reduce(0, +)
        counts = OutcomeCounts(runs)
        duration = PercentileStat(durations)
    }
}

/// How a workflow is doing on the repo's default branch, where a failure
/// means main is broken rather than a PR catching a problem.
nonisolated struct BranchHealth: Hashable {
    /// The latest decided run on the default branch failed.
    let isRed: Bool
    /// The first failure of the current red streak.
    let redSince: Date?
    /// Red streaks that ended in the window: first failure to the next success.
    let recoveries: [TimeInterval]
    let counts: OutcomeCounts
    /// Decided default-branch runs, newest first.
    let recent: [WorkflowRun]

    var timeToGreen: TimeInterval? { PercentileStat(recoveries).median }
}

/// One workflow's runs in the window.
nonisolated struct WorkflowStats: Identifiable, Hashable {
    let id: String
    let repo: String
    let workflowID: Int
    let name: String
    let path: String
    /// Runs created in the window, newest first.
    let runs: [WorkflowRun]
    let counts: OutcomeCounts
    let duration: PercentileStat
    /// Wall-clock time summed over runs: how long this workflow kept
    /// something running, not billed minutes.
    let runTime: TimeInterval
    let retried: Int
    let passedOnRetry: Int
    /// Commits with both a failed and a successful run of this workflow.
    let mixedCommits: Int
    let defaultBranch: BranchHealth?
    /// Median of the later half of the window over the earlier half, when
    /// both have enough runs to compare.
    let durationChange: Double?
    /// The period before the window, for comparison.
    let previous: PeriodSummary
    let histogram: DurationHistogram
    /// Week by week over the window, for the sparklines.
    let weeks: [ActionsBucket]

    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var lastRun: WorkflowRun? { runs.first }
    var events: [String] { Array(Set(runs.map(\.event))).sorted() }

    /// Re-runs that passed plus commits that both failed and passed: the
    /// flakiness that shows without test reports.
    var flakySignals: Int { passedOnRetry + mixedCommits }

    /// The workflow file on GitHub, which lists its runs.
    var url: URL? {
        let file = (path as NSString).lastPathComponent
        guard !file.isEmpty else { return URL(string: "https://github.com/\(repo)/actions") }
        return URL(string: "https://github.com/\(repo)/actions/workflows/\(file)")
    }
}

/// A day or week of runs, for the trend charts and sparklines.
nonisolated struct ActionsBucket: Identifiable, Hashable {
    let start: Date
    let counts: OutcomeCounts
    let duration: PercentileStat
    let runTime: TimeInterval

    var id: Date { start }

    /// Runs by day, or by week from Mondays, across `[from, to]`.
    @MainActor static func buckets(_ runs: some Sequence<WorkflowRun>, _ granularity: IssueMetrics.Granularity, from: Date, to: Date) -> [ActionsBucket] {
        let byStart = Dictionary(grouping: runs) { granularity.start(of: $0.createdAt) }
        var buckets: [ActionsBucket] = []
        var start = granularity.start(of: from)
        while start <= to {
            let runs = byStart[start] ?? []
            let durations = runs.compactMap(\.duration)
            buckets.append(ActionsBucket(start: start, counts: OutcomeCounts(runs), duration: PercentileStat(durations), runTime: durations.reduce(0, +)))
            start = granularity.next(after: start)
        }
        return buckets
    }
}

/// One repo's workflows in the window, summed.
nonisolated struct RepoStats: Identifiable, Hashable {
    let repo: String
    let workflows: [WorkflowStats]
    let current: PeriodSummary
    let previous: PeriodSummary
    let histogram: DurationHistogram
    let weeks: [ActionsBucket]
    /// Its share of the org's run time.
    let share: Double

    var id: String { repo }
    var shortName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var red: Int { workflows.filter { $0.defaultBranch?.isRed == true }.count }
}

/// Run time per period split by some grouping (repo, workflow or job), for
/// a stacked chart: the biggest few by name and the rest as Others.
nonisolated struct StackedRunTime: Hashable {
    struct Point: Hashable {
        let start: Date
        let series: String
        let value: TimeInterval
    }

    static let others = "Others"
    /// Series in order, biggest first, Others last when there are any.
    let series: [String]
    let points: [Point]

    /// `items` are (when, group, duration); at most `top` groups keep
    /// their own series.
    @MainActor init(_ items: [(at: Date, group: String, duration: TimeInterval)], granularity: IssueMetrics.Granularity, top: Int = 7) {
        let totals = Dictionary(grouping: items, by: \.group).mapValues { $0.reduce(0) { $0 + $1.duration } }
        let ranked = totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let kept = Set(ranked.prefix(top))
        series = Array(ranked.prefix(top)) + (ranked.count > top ? [Self.others] : [])
        var sums: [Date: [String: TimeInterval]] = [:]
        for item in items {
            let key = kept.contains(item.group) ? item.group : Self.others
            sums[granularity.start(of: item.at), default: [:]][key, default: 0] += item.duration
        }
        points = sums.flatMap { start, values in values.map { Point(start: start, series: $0.key, value: $0.value) } }
    }
}

/// Runs grouped by what triggered them.
nonisolated struct EventStats: Identifiable, Hashable {
    let event: String
    let counts: OutcomeCounts
    let duration: PercentileStat
    let runTime: TimeInterval

    var id: String { event }

    var title: String { Self.title(event) }

    /// GitHub's event names, in words.
    static func title(_ event: String) -> String {
        switch event {
        case "push": "Push"
        case "pull_request": "Pull request"
        case "pull_request_target": "Pull request (target)"
        case "schedule": "Schedule"
        case "workflow_dispatch": "Manual"
        case "merge_group": "Merge queue"
        case "workflow_run": "After another workflow"
        case "workflow_call": "Called"
        case "release": "Release"
        case "dynamic": "GitHub (Dependabot, Pages)"
        default: event.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Something worth a look, most urgent first.
nonisolated struct ActionsAttention: Identifiable, Hashable {
    enum Kind: Int, Comparable {
        case red, flaky, slower, failing

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    let workflow: WorkflowStats
    let message: String

    var id: String { "\(kind.rawValue)-\(workflow.id)" }
}

/// Actions insights for an org over the metrics window: per workflow, per
/// week and per trigger, from the stored runs.
struct ActionsMetrics {
    let window: MetricsWindow
    let windowStart: Date
    /// The start of the period before the window, as long as it.
    let previousStart: Date
    let workflows: [WorkflowStats]
    /// Repos by run time, most first.
    let repos: [RepoStats]
    /// The period before the window, for comparison.
    let previous: PeriodSummary
    /// Every repo's runs reach back to the previous period's start, so
    /// changes on it mean something.
    let hasPrevious: Bool
    let counts: OutcomeCounts
    let duration: PercentileStat
    let runTime: TimeInterval
    let retried: Int
    let passedOnRetry: Int
    /// Decided runs on default branches.
    let defaultBranchCounts: OutcomeCounts
    let events: [EventStats]
    let attention: [ActionsAttention]
    let repoCount: Int
    /// Runs created in the window, for bucketing.
    private let windowRuns: [WorkflowRun]
    private let now: Date

    var runCount: Int { counts.ran + counts.skipped }
    var red: [WorkflowStats] { workflows.filter { $0.defaultBranch?.isRed == true } }

    init(history: ActionsHistory, window: MetricsWindow, config: OrgConfig, now: Date = .now) {
        self.window = window
        let interval = window.interval(now: now)
        let previousInterval = window.previous(now: now)
        let now = interval.end
        let windowStart = interval.start
        self.windowStart = windowStart

        let previousStart = previousInterval.start
        let previousEnd = previousInterval.end
        self.previousStart = previousStart
        // A whole period in the past leaves out what came after it.
        let included = history.runs.values.filter { !config.excludedRepos.contains($0.repo) && $0.createdAt < now }
        let inWindow = included.filter { $0.createdAt >= windowStart }
        let before = included.filter { $0.createdAt >= previousStart && $0.createdAt < previousEnd }
        let byWorkflow = Dictionary(grouping: included, by: \.workflowKey)
        let halfway = windowStart.addingTimeInterval(now.timeIntervalSince(windowStart) / 2)

        var workflows: [WorkflowStats] = []
        for (key, all) in byWorkflow {
            let runs = all.filter { $0.createdAt >= windowStart && $0.createdAt < now }.sorted { $0.createdAt > $1.createdAt }
            guard let latest = runs.first else { continue }
            let durations = runs.compactMap(\.duration)
            let early = runs.filter { $0.createdAt < halfway }.compactMap(\.duration)
            let late = runs.filter { $0.createdAt >= halfway }.compactMap(\.duration)
            var change: Double?
            if early.count >= 5, late.count >= 5,
               let before = PercentileStat(early).median, let after = PercentileStat(late).median, before >= 30 {
                change = after / before - 1
            }
            let bySha = Dictionary(grouping: runs.filter { $0.outcome == .success || $0.outcome == .failure }, by: \.headSha)
            let mixed = bySha.values.filter { group in
                group.contains { $0.outcome == .failure } && group.contains { $0.outcome == .success }
            }.count
            let defaultBranch = history.repositories[latest.repo]?.defaultBranch
            workflows.append(WorkflowStats(
                id: key,
                repo: latest.repo,
                workflowID: latest.workflowID,
                name: latest.name,
                path: latest.path,
                runs: runs,
                counts: OutcomeCounts(runs),
                duration: PercentileStat(durations),
                runTime: durations.reduce(0, +),
                retried: runs.filter { $0.attempt > 1 }.count,
                passedOnRetry: runs.filter(\.passedOnRetry).count,
                mixedCommits: mixed,
                defaultBranch: defaultBranch.flatMap { Self.health(all, branch: $0, windowStart: windowStart) },
                durationChange: change,
                previous: PeriodSummary(all.filter { $0.createdAt >= previousStart && $0.createdAt < previousEnd }),
                histogram: DurationHistogram(durations),
                weeks: ActionsBucket.buckets(runs, .week, from: windowStart, to: now)
            ))
        }
        workflows.sort { ($0.runs.count, $1.id) > ($1.runs.count, $0.id) }
        self.workflows = workflows

        previous = PeriodSummary(before)
        hasPrevious = !history.repositories.isEmpty && history.repositories.values.allSatisfy { $0.coveredFrom <= previousStart }
        let beforeByRepo = Dictionary(grouping: before, by: \.repo)
        let totalRunTime = inWindow.compactMap(\.duration).reduce(0, +)
        repos = Dictionary(grouping: workflows, by: \.repo)
            .map { repo, workflows in
                let runs = workflows.flatMap(\.runs)
                let current = PeriodSummary(runs)
                return RepoStats(
                    repo: repo,
                    workflows: workflows,
                    current: current,
                    previous: PeriodSummary(beforeByRepo[repo] ?? []),
                    histogram: DurationHistogram(runs.compactMap(\.duration)),
                    weeks: ActionsBucket.buckets(runs, .week, from: windowStart, to: now),
                    share: totalRunTime > 0 ? current.runTime / totalRunTime : 0
                )
            }
            .sorted { ($0.current.runTime, $1.repo) > ($1.current.runTime, $0.repo) }
        counts = OutcomeCounts(inWindow)
        let durations = inWindow.compactMap(\.duration)
        duration = PercentileStat(durations)
        runTime = durations.reduce(0, +)
        retried = inWindow.filter { $0.attempt > 1 }.count
        passedOnRetry = inWindow.filter(\.passedOnRetry).count
        var branchCounts = OutcomeCounts()
        for workflow in workflows {
            for run in workflow.defaultBranch?.recent ?? [] where run.createdAt >= windowStart { branchCounts.add(run.outcome) }
        }
        defaultBranchCounts = branchCounts
        repoCount = Set(inWindow.map(\.repo)).count
        windowRuns = Array(inWindow)
        self.now = now

        events = Dictionary(grouping: inWindow, by: \.event)
            .map { event, runs in
                let durations = runs.compactMap(\.duration)
                return EventStats(event: event, counts: OutcomeCounts(runs), duration: PercentileStat(durations), runTime: durations.reduce(0, +))
            }
            .sorted { ($0.counts.ran, $1.event) > ($1.counts.ran, $0.event) }

        attention = Self.attention(workflows, now: now)
    }

    func workflow(_ key: String) -> WorkflowStats? { workflows.first { $0.id == key } }

    /// Runs by day, or by week from the Monday the window starts in.
    func buckets(_ granularity: IssueMetrics.Granularity) -> [ActionsBucket] {
        ActionsBucket.buckets(windowRuns, granularity, from: windowStart, to: now)
    }

    func repo(_ name: String) -> RepoStats? { repos.first { $0.repo == name } }

    /// Run time per period by repo, across the org.
    func runTimeByRepo(_ granularity: IssueMetrics.Granularity) -> StackedRunTime {
        StackedRunTime(windowRuns.compactMap { run in run.duration.map { (at: run.createdAt, group: run.shortName, duration: $0) } }, granularity: granularity)
    }

    /// Run time per period by workflow, in one repo.
    func runTimeByWorkflow(_ granularity: IssueMetrics.Granularity, repo: String) -> StackedRunTime {
        let runs = windowRuns.filter { $0.repo == repo }
        return StackedRunTime(runs.compactMap { run in run.duration.map { (at: run.createdAt, group: run.name, duration: $0) } }, granularity: granularity)
    }

    /// The end of the window, for charts that run up to now.
    var end: Date { now }

    /// Default-branch runs outside PRs, over the whole history so a streak
    /// that began before the window still dates from its first failure.
    private static func health(_ runs: [WorkflowRun], branch: String, windowStart: Date) -> BranchHealth? {
        let decided = runs
            .filter { $0.branch == branch && !$0.event.hasPrefix("pull_request") && ($0.outcome == .success || $0.outcome == .failure) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !decided.isEmpty else { return nil }
        var recoveries: [TimeInterval] = []
        var streakStart: Date?
        for run in decided {
            if run.outcome == .failure {
                if streakStart == nil { streakStart = run.createdAt }
            } else if let start = streakStart {
                let end = run.startedAt.flatMap { started in run.duration.map { started.addingTimeInterval($0) } } ?? run.updatedAt
                if end >= windowStart { recoveries.append(end.timeIntervalSince(start)) }
                streakStart = nil
            }
        }
        let inWindow = decided.filter { $0.createdAt >= windowStart }
        return BranchHealth(
            isRed: decided.last?.outcome == .failure,
            redSince: streakStart,
            recoveries: recoveries,
            counts: OutcomeCounts(inWindow),
            recent: Array(decided.reversed())
        )
    }

    /// Red on the default branch, flaky, getting slower, and failing on the
    /// default branch more than now and then. Failures on PRs alone are CI
    /// doing its job, so they're not flagged.
    private static func attention(_ workflows: [WorkflowStats], now: Date) -> [ActionsAttention] {
        var items: [ActionsAttention] = []
        for workflow in workflows {
            if let health = workflow.defaultBranch, health.isRed, let since = health.redSince {
                items.append(ActionsAttention(kind: .red, workflow: workflow, message: "Failing on the default branch for \(now.timeIntervalSince(since).compactDuration)"))
            } else if let health = workflow.defaultBranch, let rate = health.counts.failureRate, rate >= 0.2, health.counts.failed >= 3 {
                items.append(ActionsAttention(kind: .failing, workflow: workflow, message: "\(rate.formatted(.percent.precision(.fractionLength(0)))) of default-branch runs failed"))
            }
            let decided = workflow.counts.succeeded + workflow.counts.failed
            if workflow.flakySignals >= 3, decided > 0, Double(workflow.flakySignals) / Double(decided) >= 0.05 {
                items.append(ActionsAttention(kind: .flaky, workflow: workflow, message: "\(workflow.passedOnRetry) passed on a re-run, \(workflow.mixedCommits) commits both failed and passed"))
            }
            if let change = workflow.durationChange, change >= 0.25, let median = workflow.duration.median, median >= 60 {
                items.append(ActionsAttention(kind: .slower, workflow: workflow, message: "\(change.formatted(.percent.precision(.fractionLength(0)))) slower in the second half of the window"))
            }
        }
        return items.sorted { ($0.kind, $1.workflow.runs.count) < ($1.kind, $0.workflow.runs.count) }
    }
}

/// Jobs across a workflow's recent runs, from the jobs fetched when it's
/// opened: how long each takes, how long it waits for a runner, and how
/// often it fails.
nonisolated struct JobStats: Identifiable, Hashable {
    let name: String
    let counts: OutcomeCounts
    let duration: PercentileStat
    let queue: PercentileStat
    /// Failed in an earlier attempt of a run, then passed in its latest.
    let passedOnRetry: Int
    let labels: [String]
    let runTime: TimeInterval
    let histogram: DurationHistogram
    /// Median, p75 and p90 per week, for the sparkline.
    let weeks: [(start: Date, duration: PercentileStat)]
    /// Its share of the workflow's job time.
    var share: Double = 0

    var id: String { name }

    static func == (a: JobStats, b: JobStats) -> Bool { a.name == b.name && a.counts == b.counts && a.runTime == b.runTime }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Latest-attempt jobs grouped by name (matrix values folded together),
    /// by run time, most first.
    @MainActor static func stats(runs: [WorkflowRun], jobs: [Int: [WorkflowJob]], from: Date = .distantPast, to: Date = .now) -> [JobStats] {
        var latest: [String: [WorkflowJob]] = [:]
        var retried: [String: Int] = [:]
        for run in runs {
            guard let all = jobs[run.id] else { continue }
            let current = all.filter { $0.runAttempt == run.attempt }
            for job in current { latest[job.baseName, default: []].append(job) }
            let earlierFailures = Set(all.filter { $0.runAttempt < run.attempt && $0.outcome == .failure }.map(\.name))
            for job in current where job.outcome == .success && earlierFailures.contains(job.name) {
                retried[job.baseName, default: 0] += 1
            }
        }
        let weekStarts = from == .distantPast ? [] : MetricsStore.weeks(from: from, to: to)
        var stats = latest.map { name, jobs in
            var counts = OutcomeCounts()
            for job in jobs { counts.add(job.outcome) }
            let durations = jobs.compactMap(\.duration)
            let byWeek = Dictionary(grouping: jobs) { Calendar.metrics.startOfWeek(for: $0.startedAt ?? $0.createdAt ?? .distantPast) }
            return JobStats(
                name: name,
                counts: counts,
                duration: PercentileStat(durations),
                queue: PercentileStat(jobs.compactMap(\.queueTime)),
                passedOnRetry: retried[name] ?? 0,
                labels: Array(Set(jobs.flatMap(\.labels))).sorted(),
                runTime: durations.reduce(0, +),
                histogram: DurationHistogram(durations),
                weeks: weekStarts.map { ($0, PercentileStat((byWeek[$0] ?? []).compactMap(\.duration))) }
            )
        }
        let total = stats.reduce(0) { $0 + $1.runTime }
        for index in stats.indices { stats[index].share = total > 0 ? stats[index].runTime / total : 0 }
        return stats.sorted { ($0.runTime, $1.name) > ($1.runTime, $0.name) }
    }
}
