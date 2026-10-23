import Foundation

/// One PR's CI: the workflow runs matched to it, the time they took and
/// what drove it. Time is wall clock summed over runs, as the rest of the
/// CI page counts it, and only a run's latest attempt is listed.
struct PullRequestCI: Identifiable, Hashable {
    struct WorkflowTime: Hashable {
        let name: String
        let time: TimeInterval
    }

    let repo: String
    let number: Int
    let title: String?
    let author: String?
    let isBot: Bool
    /// Set once it's merged and in the merged-PR history, for its size and
    /// when it merged.
    let merged: MetricPullRequest?
    /// Every run matched to it, newest first.
    let runs: [WorkflowRun]
    let runTime: TimeInterval
    /// Commits CI ran on, roughly its pushes.
    let commits: Int
    let failed: Int
    /// Runs re-run at least once.
    let reruns: Int
    /// Time on runs of commits a later one replaced.
    let supersededTime: TimeInterval
    /// Time on failed or cancelled runs of its latest commit.
    let failedTime: TimeInterval
    /// Time per workflow, most first.
    let workflows: [WorkflowTime]
    /// Merged PRs: from the final push to its last run finishing (or the
    /// merge, if that came first).
    let finalWait: TimeInterval?
    /// Merged PRs: from its final CI finishing to the merge; negative when
    /// it merged before CI finished.
    let mergeAfterCI: TimeInterval?

    var id: String { Self.id(repo: repo, number: number) }
    static func id(repo: String, number: Int) -> String { "\(repo)#\(number)" }

    var lastRunAt: Date { runs.first?.createdAt ?? .distantPast }
    /// Time that didn't go on checking the change that merged: superseded
    /// commits and failed runs.
    var wastedTime: TimeInterval { supersededTime + failedTime }
    var lines: Int? { merged?.size }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var url: URL? { merged?.url ?? URL(string: "https://github.com/\(repo)/pull/\(number)") }

    /// CI was the last thing it waited for: merged within a quarter of an
    /// hour of its final run finishing.
    var mergedOnCI: Bool { mergeAfterCI.map { $0 >= 0 && $0 <= Self.mergedOnCIWithin } ?? false }
    static let mergedOnCIWithin: TimeInterval = 15 * 60

    /// Counted as someone's: not excluded, and not a bot unless it's one
    /// brought back in the org's settings.
    static func isPerson(_ pr: PullRequestCI, config: OrgConfig) -> Bool {
        let author = pr.author ?? ""
        return !config.excludes(author) && (!pr.isBot || config.includedAuthors.contains(author))
    }

    /// Lines changed at or under which a PR counts as small.
    static let smallLines = 20

    /// The events whose runs belong to a PR: its own, and pushes to its
    /// branch.
    static let events: Set<String> = ["pull_request", "pull_request_target", "push"]

    /// Runs matched to PRs, by `id`. A run GitHub listed a PR for goes to
    /// that PR. Otherwise (GitHub stops listing a PR once it merges) it goes
    /// to the merged PR whose head branch it ran on, the first merged after
    /// it, since a branch name can be used again. Runs on a default branch,
    /// skipped runs and other events go to none.
    static func match(_ runs: [WorkflowRun], merged: [MetricPullRequest], defaultBranches: [String: String]) -> [String: [WorkflowRun]] {
        var byBranch: [String: [MetricPullRequest]] = [:]
        for pr in merged {
            if let ref = pr.headRef { byBranch["\(pr.repo) \(ref)", default: []].append(pr) }
        }
        for key in byBranch.keys { byBranch[key]?.sort { $0.mergedAt < $1.mergedAt } }
        // Open PRs GitHub listed on some of a branch's runs, for its others.
        var listed: [String: Int] = [:]
        for run in runs {
            if let number = run.pullRequests?.first, let branch = run.branch { listed["\(run.repo) \(branch)"] = number }
        }

        var matched: [String: [WorkflowRun]] = [:]
        for run in runs where events.contains(run.event) && run.outcome != .skipped {
            guard let branch = run.branch, branch != defaultBranches[run.repo] else { continue }
            if let number = run.pullRequests?.first {
                matched[id(repo: run.repo, number: number), default: []].append(run)
                continue
            }
            let key = "\(run.repo) \(branch)"
            // A minute's grace for a run created as the PR merged.
            if let pr = byBranch[key]?.first(where: { $0.mergedAt.addingTimeInterval(60) >= run.createdAt }) {
                matched[id(repo: run.repo, number: pr.number), default: []].append(run)
            } else if let number = listed[key] {
                matched[id(repo: run.repo, number: number), default: []].append(run)
            }
        }
        return matched
    }

    /// Every PR with runs created before `end`, built from the runs (in
    /// repos not excluded) and what's known of the PRs: merged ones from
    /// the history, open ones from the workload.
    static func all(
        runs: some Sequence<WorkflowRun>,
        merged: some Sequence<MetricPullRequest>,
        open: [PullRequest],
        defaultBranches: [String: String],
        config: OrgConfig,
        before end: Date = .distantFuture
    ) -> [PullRequestCI] {
        let runs = runs.filter { !config.repoExclusion.contains($0.repo) && $0.createdAt < end }
        let merged = merged.filter { !config.repoExclusion.contains($0.repo) }
        let mergedByID = Dictionary(merged.map { (id(repo: $0.repo, number: $0.number), $0) }, uniquingKeysWith: { first, _ in first })
        let openByID = Dictionary(open.map { (id(repo: $0.repo, number: $0.number), $0) }, uniquingKeysWith: { first, _ in first })
        return match(runs, merged: merged, defaultBranches: defaultBranches).compactMap { key, runs in
            guard let number = key.split(separator: "#").last.flatMap({ Int($0) }) else { return nil }
            return build(number: number, runs: runs, merged: mergedByID[key], open: openByID[key])
        }
    }

    /// `number` is the PR's, as `match` keyed its runs.
    static func build(number: Int, runs: [WorkflowRun], merged: MetricPullRequest?, open: PullRequest?) -> PullRequestCI {
        let runs = runs.sorted { $0.createdAt > $1.createdAt }
        let first = runs[0]
        let latest = first.headSha
        func time(_ runs: some Sequence<WorkflowRun>) -> TimeInterval { runs.reduce(0) { $0 + ($1.duration ?? 0) } }

        var workflowTimes: [String: TimeInterval] = [:]
        for run in runs { workflowTimes[run.name, default: 0] += run.duration ?? 0 }

        // Who pushed most often to it, when the PR itself isn't known.
        let actors = Dictionary(grouping: runs.compactMap(\.actor), by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
        let author = merged?.author?.login ?? open?.author?.login ?? actors
        // Run actors only when the PR isn't known: automation can push to a
        // person's branch.
        let isBot = merged?.authorIsBot == true
            || author.map(OrgConfig.looksLikeBot) == true
            || (merged == nil && open == nil && runs.allSatisfy { $0.actor.map(OrgConfig.looksLikeBot) ?? false })

        var finalWait: TimeInterval?
        var mergeAfterCI: TimeInterval?
        let final = runs.filter { $0.headSha == latest }
        if let merged, let pushed = final.map(\.createdAt).min() {
            let finishes = final.map(\.finishedAt)
            if !finishes.contains(nil), let finished = finishes.compactMap({ $0 }).max() {
                finalWait = max(0, min(finished, merged.mergedAt).timeIntervalSince(pushed))
                mergeAfterCI = merged.mergedAt.timeIntervalSince(finished)
            }
        }

        return PullRequestCI(
            repo: first.repo,
            number: number,
            title: merged?.title ?? open?.title,
            author: author,
            isBot: isBot,
            merged: merged,
            runs: runs,
            runTime: time(runs),
            commits: Set(runs.map(\.headSha)).count,
            failed: runs.filter { $0.outcome == .failure }.count,
            reruns: runs.filter { $0.attempt > 1 }.count,
            supersededTime: time(runs.filter { $0.headSha != latest }),
            failedTime: time(final.filter { $0.outcome == .failure || $0.outcome == .cancelled }),
            workflows: workflowTimes.map { WorkflowTime(name: $0.key, time: $0.value) }.sorted { ($0.time, $1.name) > ($1.time, $0.name) },
            finalWait: finalWait,
            mergeAfterCI: mergeAfterCI
        )
    }
}

/// One author's PRs and the CI they took, against everyone's.
struct PersonCI: Identifiable, Hashable {
    let login: String
    let pullRequests: [PullRequestCI]
    let runTime: TimeInterval
    let perPR: PercentileStat
    /// Of everyone's PR CI time, and of their PRs.
    let shareOfTime: Double
    let shareOfPRs: Double
    /// Medians per PR: what drives it.
    let commits: Double?
    let failed: Double?
    let reruns: Double?
    let wastedTime: TimeInterval

    var id: String { login }
    /// Their share of CI time over their share of PRs: over 1 costs more
    /// than their count of PRs suggests.
    var weight: Double? { shareOfPRs > 0 ? shareOfTime / shareOfPRs : nil }
}

/// How CI time follows the amount of change: per merged PR, by size band,
/// and week by week across the org.
struct CIScaling: Hashable {
    struct Band: Identifiable, Hashable {
        let label: String
        let count: Int
        let time: PercentileStat
        /// Median per PR of CI time for each 100 lines changed.
        let perHundredLines: TimeInterval?

        var id: String { label }
    }

    struct Week: Identifiable, Hashable {
        let start: Date
        /// CI time of PR runs created in the week.
        let runTime: TimeInterval
        /// Lines changed by PRs merged in the week, in repos CI is fetched for.
        let lines: Int

        var id: Date { start }
        /// CI minutes per 1,000 lines changed.
        var minutesPerThousand: Double? { lines > 0 ? runTime / 60 / Double(lines) * 1000 : nil }
    }

    /// Merged PRs with CI: lines changed against CI time.
    let points: [PullRequestCI]
    /// Spearman rank correlation of lines changed and CI time: 1 when bigger
    /// PRs always take longer, 0 when size says nothing.
    let correlation: Double?
    let bands: [Band]
    let weeks: [Week]
    /// CI minutes per 1,000 lines changed over the window and the period
    /// before.
    let minutesPerThousand: Double?
    let previousMinutesPerThousand: Double?

    /// Needs this many PRs before a correlation says anything.
    static let minimumPoints = 8

    static func bands(_ prs: [PullRequestCI]) -> [Band] {
        let byBucket = Dictionary(grouping: prs.filter { $0.lines != nil }) { SizeStat.bucket($0.lines ?? 0) }
        return SizeStat.bucketLabels.indices.compactMap { index in
            guard let prs = byBucket[index], !prs.isEmpty else { return nil }
            let perHundred = prs.compactMap { pr in pr.lines.flatMap { $0 > 0 ? pr.runTime / Double($0) * 100 : nil } }
            return Band(label: SizeStat.bucketLabels[index], count: prs.count, time: PercentileStat(prs.map(\.runTime)), perHundredLines: PercentileStat(perHundred).median)
        }
    }

    /// Spearman's rank correlation: Pearson's over ranks, ties sharing
    /// their average rank.
    static func spearman(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 2 else { return nil }
        func ranks(_ values: [Double]) -> [Double] {
            let order = values.indices.sorted { values[$0] < values[$1] }
            var ranks = Array(repeating: 0.0, count: values.count)
            var start = 0
            while start < order.count {
                var end = start
                while end + 1 < order.count && values[order[end + 1]] == values[order[start]] { end += 1 }
                let rank = Double(start + end) / 2 + 1
                for position in start...end { ranks[order[position]] = rank }
                start = end + 1
            }
            return ranks
        }
        let x = ranks(pairs.map(\.0))
        let y = ranks(pairs.map(\.1))
        let n = Double(pairs.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for index in x.indices {
            covariance += (x[index] - meanX) * (y[index] - meanY)
            varianceX += (x[index] - meanX) * (x[index] - meanX)
            varianceY += (y[index] - meanY) * (y[index] - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}

/// CI time per PR over the metrics window: each PR's, the averages, who
/// uses it, what drives it and how it follows the amount of change. A PR
/// belongs to the period its latest run was created in, with all its runs.
/// PRs by bots are counted apart, and excluded authors left out.
struct PullRequestCIMetrics {
    /// People's PRs in the window, most CI time first.
    let pullRequests: [PullRequestCI]
    /// Bots' PRs in the window.
    let bots: [PullRequestCI]
    let perPR: PercentileStat
    let previousPerPR: PercentileStat
    let runTime: TimeInterval
    let wastedTime: TimeInterval
    let previousWastedShare: Double?
    /// Small PRs that took more CI than the median PR.
    let smallButCostly: [PullRequestCI]
    /// Merged PRs: the final push to CI finishing, and that wait's share of
    /// the PR's cycle time.
    let finalWait: PercentileStat
    let finalWaitShare: Double?
    /// Merged PRs whose merge followed CI finishing within a quarter hour.
    let mergedOnCI: Int
    let mergedWithWait: Int
    let people: [PersonCI]
    let scaling: CIScaling
    /// PR-event runs in the window matched to no PR: from forks, or PRs not
    /// fetched.
    let unmatchedTime: TimeInterval

    var wastedShare: Double? { runTime > 0 ? wastedTime / runTime : nil }
    var botTime: TimeInterval { bots.reduce(0) { $0 + $1.runTime } }

    func pullRequest(_ id: String) -> PullRequestCI? { (pullRequests + bots).first { $0.id == id } }
    func person(_ login: String) -> PersonCI? { people.first { $0.login == login } }

    init(history: ActionsHistory, merged: [MetricPullRequest], open: [PullRequest], window: MetricsWindow, config: OrgConfig, now: Date = .now) {
        let interval = window.interval(now: now)
        let previousInterval = window.previous(now: now)
        let end = interval.end
        let defaultBranches = history.repositories.compactMapValues(\.defaultBranch)
        let all = PullRequestCI.all(runs: history.runs.values, merged: merged, open: open, defaultBranches: defaultBranches, config: config, before: end)
        func isPerson(_ pr: PullRequestCI) -> Bool { PullRequestCI.isPerson(pr, config: config) }
        func isBot(_ pr: PullRequestCI) -> Bool { pr.isBot && !isPerson(pr) }
        let inWindow = all.filter { $0.lastRunAt >= interval.start }
        let before = all.filter { $0.lastRunAt >= previousInterval.start && $0.lastRunAt < previousInterval.end && isPerson($0) }

        let people = inWindow.filter(isPerson).sorted { ($0.runTime, $1.id) > ($1.runTime, $0.id) }
        pullRequests = people
        bots = inWindow.filter(isBot).sorted { ($0.runTime, $1.id) > ($1.runTime, $0.id) }
        perPR = PercentileStat(people.map(\.runTime))
        previousPerPR = PercentileStat(before.map(\.runTime))
        runTime = people.reduce(0) { $0 + $1.runTime }
        wastedTime = people.reduce(0) { $0 + $1.wastedTime }
        let previousTime = before.reduce(0) { $0 + $1.runTime }
        previousWastedShare = previousTime > 0 ? before.reduce(0) { $0 + $1.wastedTime } / previousTime : nil
        let median = perPR.median ?? .infinity
        smallButCostly = people.filter { ($0.lines ?? .max) <= PullRequestCI.smallLines && $0.runTime > median }

        let waited = people.filter { $0.finalWait != nil }
        finalWait = PercentileStat(waited.compactMap(\.finalWait))
        finalWaitShare = PercentileStat(waited.compactMap { pr in
            pr.merged.flatMap { merged in merged.cycleTime > 0 ? pr.finalWait.map { $0 / merged.cycleTime } : nil }
        }).median
        mergedOnCI = waited.filter(\.mergedOnCI).count
        mergedWithWait = waited.count

        let total = runTime
        self.people = Dictionary(grouping: people.filter { $0.author != nil }) { $0.author ?? "" }
            .map { login, prs in
                let time = prs.reduce(0) { $0 + $1.runTime }
                return PersonCI(
                    login: login,
                    pullRequests: prs,
                    runTime: time,
                    perPR: PercentileStat(prs.map(\.runTime)),
                    shareOfTime: total > 0 ? time / total : 0,
                    shareOfPRs: Double(prs.count) / Double(max(people.count, 1)),
                    commits: PercentileStat(prs.map { Double($0.commits) }).median,
                    failed: PercentileStat(prs.map { Double($0.failed) }).median,
                    reruns: PercentileStat(prs.map { Double($0.reruns) }).median,
                    wastedTime: prs.reduce(0) { $0 + $1.wastedTime }
                )
            }
            .sorted { ($0.runTime, $1.login) > ($1.runTime, $0.login) }

        // Lines merged across the repos CI is fetched for, against the CI
        // time of PR runs, week by week.
        let tracked = Set(history.repositories.keys)
        let mergedPeople = merged.filter {
            tracked.contains($0.repo) && !config.repoExclusion.contains($0.repo) && !$0.authorIsBot && !config.excludes($0.author?.login ?? "")
        }
        let personRuns = all.filter(isPerson).flatMap(\.runs)
        func lines(_ from: Date, _ to: Date) -> Int {
            mergedPeople.filter { $0.mergedAt >= from && $0.mergedAt < to }.reduce(0) { $0 + $1.size }
        }
        func time(_ from: Date, _ to: Date) -> TimeInterval {
            personRuns.filter { $0.createdAt >= from && $0.createdAt < to }.reduce(0) { $0 + ($1.duration ?? 0) }
        }
        func ratio(_ from: Date, _ to: Date) -> Double? {
            let changed = lines(from, to)
            return changed > 0 ? time(from, to) / 60 / Double(changed) * 1000 : nil
        }
        let weeks = MetricsStore.weeks(from: interval.start, to: end).map { start in
            let next = Calendar.metrics.date(byAdding: .day, value: 7, to: start) ?? end
            let from = max(start, interval.start)
            let to = min(next, end)
            return CIScaling.Week(start: start, runTime: time(from, to), lines: lines(from, to))
        }
        let points = people.filter { $0.lines != nil && $0.runTime > 0 }
        scaling = CIScaling(
            points: points,
            correlation: points.count >= CIScaling.minimumPoints ? CIScaling.spearman(points.map { (Double($0.lines ?? 0), $0.runTime) }) : nil,
            bands: CIScaling.bands(points),
            weeks: weeks,
            minutesPerThousand: ratio(interval.start, end),
            previousMinutesPerThousand: ratio(previousInterval.start, previousInterval.end)
        )

        let matchedIDs = Set(all.flatMap(\.runs).map(\.id))
        unmatchedTime = history.runs.values
            .filter {
                ($0.event == "pull_request" || $0.event == "pull_request_target") && $0.outcome != .skipped
                    && $0.createdAt >= interval.start && $0.createdAt < end
                    && !config.repoExclusion.contains($0.repo) && !matchedIDs.contains($0.id)
            }
            .reduce(0) { $0 + ($1.duration ?? 0) }
    }
}
