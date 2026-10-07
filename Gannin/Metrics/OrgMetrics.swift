import Foundation

/// Median and 75th percentile of a set of durations.
nonisolated struct DurationStat: Hashable {
    let median: TimeInterval?
    let p75: TimeInterval?
    let count: Int

    init(_ values: [TimeInterval]) {
        let sorted = values.sorted()
        count = sorted.count
        median = Self.percentile(sorted, 0.5)
        p75 = Self.percentile(sorted, 0.75)
    }

    private static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}

/// A stage across PRs: its median overall, and how often and how long it
/// takes when it happens at all (rework, say, is zero for most PRs).
struct StageSummary: Hashable {
    /// Anything under a minute counts as not happening.
    static let threshold: TimeInterval = 60

    let overall: DurationStat
    let whenItHappens: DurationStat
    /// Share of PRs where the stage took at least `threshold`.
    let share: Double

    init(_ values: [TimeInterval]) {
        overall = DurationStat(values)
        let happened = values.filter { $0 >= Self.threshold }
        whenItHappens = DurationStat(happened)
        share = values.isEmpty ? 0 : Double(happened.count) / Double(values.count)
    }

    /// Most PRs skip it, so the overall median would read as zero.
    var isOccasional: Bool { share < 0.5 }
}

/// The four stages cycle time is split into, in order.
enum CycleStage: String, CaseIterable, Identifiable {
    case coding = "Coding"
    case waiting = "Waiting for review"
    case rework = "Rework"
    case merging = "Merging"

    var id: Self { self }

    var help: String {
        switch self {
        case .coding: "First commit to PR opened (or marked ready)"
        case .waiting: "Ready for review to first review"
        case .rework: "First review to final approval. Zero when the first review is an approval"
        case .merging: "Approval to merge"
        }
    }
}

extension MetricPullRequest {
    /// Cycle time runs from the earlier of first commit and PR creation.
    var startedAt: Date { min(firstCommitAt ?? createdAt, createdAt) }

    var cycleTime: TimeInterval { mergedAt.timeIntervalSince(startedAt) }

    var timeToFirstReview: TimeInterval? {
        firstReviewAt.map { max(0, $0.timeIntervalSince(reviewableAt)) }
    }

    func duration(of stage: CycleStage) -> TimeInterval? {
        func span(_ from: Date?, _ to: Date?) -> TimeInterval? {
            guard let from, let to else { return nil }
            return max(0, to.timeIntervalSince(from))
        }
        switch stage {
        case .coding: return span(startedAt, reviewableAt)
        case .waiting: return span(reviewableAt, firstReviewAt)
        case .rework: return span(firstReviewAt, approvedAt)
        case .merging: return span(approvedAt, mergedAt)
        }
    }
}

struct WeekMetrics: Identifiable, Hashable {
    let start: Date
    let opened: Int?
    let merged: Int
    let cycleTime: DurationStat

    var id: Date { start }
}

nonisolated struct PersonMetrics: Identifiable, Hashable {
    let person: Person
    let merged: Int
    let cycleTime: DurationStat
    let timeToFirstReview: DurationStat
    /// Merged PRs they reviewed (not their own).
    let reviewsGiven: Int
    /// How big their merged PRs were.
    let size: PullRequestSizes

    var id: String { person.login }
}

/// The size of a set of merged PRs: medians per PR (as the other metrics
/// are, so one huge PR doesn't skew it), p75 and totals.
nonisolated struct PullRequestSizes: Hashable {
    /// Median and p75 lines changed (added plus removed) per PR.
    let medianLines: Int?
    let p75Lines: Int?
    /// Median files changed, over the PRs whose count is known.
    let medianFiles: Int?
    let filesKnown: Int
    let added: Int
    let removed: Int
    /// PRs over `SizeStat.largeLines` lines.
    let large: Int

    /// Each PR's lines added, removed and files changed (nil when not known).
    init(_ prs: [(added: Int, removed: Int, files: Int?)], largeLines: Int) {
        let lines = prs.map { $0.added + $0.removed }.sorted()
        let files = prs.compactMap(\.files).sorted()
        medianLines = lines.isEmpty ? nil : lines[lines.count / 2]
        p75Lines = lines.isEmpty ? nil : lines[min(lines.count - 1, lines.count * 3 / 4)]
        medianFiles = files.isEmpty ? nil : files[files.count / 2]
        filesKnown = files.count
        added = prs.reduce(0) { $0 + $1.added }
        removed = prs.reduce(0) { $0 + $1.removed }
        large = lines.filter { $0 > largeLines }.count
    }
}

/// One review request on a merged PR and how (or whether) it was answered.
struct ReviewRequestOutcome: Identifiable, Hashable {
    let pr: MetricPullRequest
    let login: String
    let requestedAt: Date
    /// Their first review after the request, if any before merge.
    let respondedAt: Date?

    var id: String { "\(pr.id)-\(login)-\(requestedAt.timeIntervalSince1970)" }

    /// Requests made while the PR was a draft start the clock when it was
    /// marked ready.
    var waitingFrom: Date { max(requestedAt, pr.reviewableAt) }

    var responseTime: TimeInterval? {
        respondedAt.map { max(0, $0.timeIntervalSince(waitingFrom)) }
    }
}

/// An open PR currently waiting on someone's review.
struct PendingReview: Identifiable, Hashable {
    let pr: PullRequest
    let login: String
    let since: Date

    var id: String { "\(pr.id)-\(login)" }
}

nonisolated struct ReviewerMetrics: Identifiable, Hashable {
    let person: Person
    /// Requests on PRs merged in the window, withdrawn ones excluded.
    let requested: Int
    let answered: Int
    let responseTime: DurationStat
    /// Open PRs waiting on them now.
    let pending: Int
    let oldestPendingSince: Date?
    /// Reviews on merged PRs they weren't asked for.
    let unrequested: Int

    var id: String { person.login }
    var unanswered: Int { requested - answered }
    var responseRate: Double? { requested > 0 ? Double(answered) / Double(requested) : nil }

    /// Answers fewer than half their requests, or takes over a day at the median.
    var needsAttention: Bool {
        (requested >= 3 && (responseRate ?? 1) < 0.5) || (responseTime.median ?? 0) > 24 * 60 * 60
    }
}

nonisolated struct RepoMetrics: Identifiable, Hashable {
    let repo: String
    let merged: Int
    let cycleTime: DurationStat

    var id: String { repo }
}

/// The headline numbers for a span, to compare the window with the period
/// before it.
struct DeliverySummary: Hashable {
    let merged: Int
    let cycleTime: DurationStat
    let timeToFirstReview: DurationStat
    let stages: [CycleStage: StageSummary]
    let reworkShare: Double?
    let unreviewedShare: Double?
    let prSizeMedian: Int?
    let answeredShare: Double?
    let opened: Int?
    /// By repo and by author, for explaining a change.
    let repos: [String: (count: Int, cycleTime: TimeInterval?)]
    let authors: [String: (count: Int, cycleTime: TimeInterval?)]

    static func == (lhs: DeliverySummary, rhs: DeliverySummary) -> Bool {
        lhs.merged == rhs.merged && lhs.cycleTime == rhs.cycleTime && lhs.timeToFirstReview == rhs.timeToFirstReview
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(merged)
        hasher.combine(cycleTime)
    }
}

/// PR sizes in a span: lines added and deleted.
struct SizeStat: Hashable {
    /// Lines changed above which a PR counts as large.
    static let largeLines = 400

    /// Upper bounds of the distribution's buckets, in lines changed; the
    /// last bucket is everything over the last bound. 400 is a bound, so
    /// the buckets after it are the large PRs.
    static let bucketBounds = [10, 50, 100, 200, 400, 1000]
    static let bucketLabels = ["0-10", "11-50", "51-100", "101-200", "201-400", "401-1,000", "Over 1,000"]

    let median: Int?
    let p75: Int?
    /// Large PRs, biggest first.
    let large: [MetricPullRequest]
    let smallest: MetricPullRequest?
    let largest: MetricPullRequest?
    /// Median files changed, over the PRs whose count is known.
    let medianFiles: Int?
    /// PRs in each of `bucketLabels`.
    let buckets: [Int]

    init(_ prs: [MetricPullRequest]) {
        let sizes = prs.map(\.size).sorted()
        median = sizes.isEmpty ? nil : sizes[sizes.count / 2]
        p75 = sizes.isEmpty ? nil : sizes[min(sizes.count - 1, sizes.count * 3 / 4)]
        large = prs.filter { $0.size > Self.largeLines }.sorted { $0.size > $1.size }
        smallest = prs.min { $0.size < $1.size }
        largest = prs.max { $0.size < $1.size }
        let files = prs.compactMap(\.changedFiles).sorted()
        medianFiles = files.isEmpty ? nil : files[files.count / 2]
        var buckets = Array(repeating: 0, count: Self.bucketLabels.count)
        for size in sizes { buckets[Self.bucket(size)] += 1 }
        self.buckets = buckets
    }

    static func bucket(_ lines: Int) -> Int {
        bucketBounds.firstIndex { lines <= $0 } ?? bucketBounds.count
    }
}

extension MetricPullRequest {
    var size: Int { additions + deletions }

    /// A large PR approved quickly with no changes asked for, or merged
    /// without review: more change than its review could have covered.
    var isRushed: Bool {
        guard size > SizeStat.largeLines else { return false }
        guard let first = firstReviewAt else { return true }
        let quick = first.timeIntervalSince(reviewableAt) < 15 * 60
        let approvedFirst = reviewsBeforeMerge.first?.state == "APPROVED"
        return quick && approvedFirst
    }
}

/// A repo's large PRs and how many were rushed through review.
struct RepoRisk: Identifiable, Hashable {
    let repo: String
    let large: Int
    let rushed: [MetricPullRequest]
    let medianSize: Int

    var id: String { repo }
}

/// Metrics for one window over an org's merged-PR history, optionally
/// scoped to a team. Bot-authored PRs are left out.
struct OrgMetrics {
    let window: MetricsWindow
    let interval: DateInterval
    let windowStart: Date
    /// The period before, when the history reaches back that far.
    let previous: DeliverySummary?
    let prSize: SizeStat
    let repoRisks: [RepoRisk]
    let answeredShare: Double?
    let syncedAt: Date
    let merged: [MetricPullRequest]
    /// PRs opened across the org; search can't scope this to a team.
    let opened: Int
    let cycleTime: DurationStat
    let timeToFirstReview: DurationStat
    let stages: [CycleStage: StageSummary]
    let mergedWithoutReview: [MetricPullRequest]
    let weeks: [WeekMetrics]
    let people: [PersonMetrics]
    let repos: [RepoMetrics]
    let reviewers: [ReviewerMetrics]
    /// Answered and unanswered requests on PRs merged in the window.
    let reviewOutcomes: [ReviewRequestOutcome]
    let pendingReviews: [PendingReview]
    let isTeamScoped: Bool

    /// Team-scoped merged PRs across the whole stored range (whole weeks).
    let coverage: [MetricPullRequest]
    private let byID: [String: MetricPullRequest]

    init(
        history: MetricsHistory,
        window: MetricsWindow,
        team: Team?,
        members: [Person],
        hidden: Set<String>,
        config: OrgConfig = OrgConfig(),
        openPullRequests: [PullRequest] = [],
        now: Date = .now
    ) {
        let interval = window.interval(now: now)
        let previousInterval = window.previous(now: now)
        let windowStart = interval.start
        let now = interval.end
        self.window = window
        self.interval = interval
        self.windowStart = windowStart
        syncedAt = history.syncedAt
        isTeamScoped = team != nil

        let teamLogins = team.map { Set($0.members) }
        func inTeam(_ login: String?) -> Bool {
            guard let teamLogins else { return true }
            return login.map(teamLogins.contains) ?? false
        }

        let coverageStart = Calendar.metrics.startOfWeek(for: windowStart)
        // Excluded authors lose their PRs and their reviews, so a review by
        // an excluded account never counts as a PR's first review.
        let considered = history.pullRequests.values
            .filter {
                !$0.authorIsBot && !hidden.contains($0.id) && $0.mergedAt >= min(coverageStart, previousInterval.start)
                    && $0.mergedAt < now
                    && !config.repoExclusion.contains($0.repo)
                    && !config.excludes($0.author?.login ?? "")
            }
            .map { pr in
                var pr = pr
                pr.reviews.removeAll { config.excludes($0.login) }
                pr.reviewRequests.removeAll { config.excludes($0.login) }
                return pr
            }
        let inRange = considered.filter { $0.mergedAt >= coverageStart }
        let merged = inRange
            .filter { $0.mergedAt >= windowStart && inTeam($0.author?.login) }
            .sorted { $0.mergedAt > $1.mergedAt }
        self.merged = merged
        let coverage = inRange.filter { inTeam($0.author?.login) }
        self.coverage = coverage
        byID = Dictionary(coverage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        opened = history.openedPerWeek
            .filter { $0.key >= Calendar.metrics.startOfWeek(for: windowStart) && $0.key < now }
            .map(\.value)
            .reduce(0, +)
        cycleTime = DurationStat(merged.map(\.cycleTime))
        timeToFirstReview = DurationStat(merged.compactMap(\.timeToFirstReview))
        stages = Dictionary(uniqueKeysWithValues: CycleStage.allCases.map { stage in
            (stage, StageSummary(merged.compactMap { $0.duration(of: stage) }))
        })
        // Repos that don't need a review aren't counted against.
        mergedWithoutReview = merged.filter { $0.firstReviewAt == nil && config.needsReview($0.repo) }

        // Weekly buckets cover whole weeks, so they use the full stored range.
        let weekly = Dictionary(grouping: coverage) {
            Calendar.metrics.startOfWeek(for: $0.mergedAt)
        }
        weeks = MetricsStore.weeks(from: coverageStart, to: now).map { week in
            let prs = weekly[week] ?? []
            return WeekMetrics(
                start: week,
                opened: history.openedPerWeek[week],
                merged: prs.count,
                cycleTime: DurationStat(prs.map(\.cycleTime))
            )
        }

        let membersByLogin = Dictionary(members.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })
        let authored = Dictionary(grouping: merged) { $0.author?.login ?? "" }
        var reviewed: [String: Int] = [:]
        for pr in inRange where pr.mergedAt >= windowStart {
            for login in pr.reviewers where inTeam(login) { reviewed[login, default: 0] += 1 }
        }
        let logins = Set(authored.keys).union(reviewed.keys).subtracting([""])
            .filter { !hidden.contains(HiddenStore.personKey($0)) }
        people = logins.map { login in
            let prs = authored[login] ?? []
            let person = membersByLogin[login] ?? prs.first?.author ?? Person(login: login, name: nil, avatarUrl: nil)
            return PersonMetrics(
                person: person,
                merged: prs.count,
                cycleTime: DurationStat(prs.map(\.cycleTime)),
                timeToFirstReview: DurationStat(prs.compactMap(\.timeToFirstReview)),
                reviewsGiven: reviewed[login] ?? 0,
                size: PullRequestSizes(prs.map { ($0.additions, $0.deletions, $0.changedFiles) }, largeLines: SizeStat.largeLines)
            )
        }
        .sorted { ($0.merged + $0.reviewsGiven, $1.person.login) > ($1.merged + $1.reviewsGiven, $0.person.login) }

        // Reviewer stats follow the reviewer, so the team filter applies to
        // them rather than to the PR author.
        var outcomes: [ReviewRequestOutcome] = []
        var unrequested: [String: Int] = [:]
        for pr in inRange where pr.mergedAt >= windowStart {
            for request in pr.reviewRequests where inTeam(request.login) {
                let deadline = request.removedAt ?? pr.mergedAt
                let response = pr.reviews.first {
                    $0.login == request.login && $0.submittedAt >= request.requestedAt && $0.submittedAt <= deadline
                }
                // Withdrawn before they got to it: not theirs to answer.
                if response == nil && request.removedAt != nil { continue }
                outcomes.append(ReviewRequestOutcome(
                    pr: pr,
                    login: request.login,
                    requestedAt: request.requestedAt,
                    respondedAt: response?.submittedAt
                ))
            }
            let requestedLogins = Set(pr.reviewRequests.map(\.login))
            for login in pr.reviewers where !requestedLogins.contains(login) && inTeam(login) {
                unrequested[login, default: 0] += 1
            }
        }
        reviewOutcomes = outcomes

        let pending = openPullRequests.filter { !$0.isDraft }.flatMap { pr in
            pr.requestedReviewers
                .filter { inTeam($0.login) && !config.excludes($0.login) }
                .map { PendingReview(pr: pr, login: $0.login, since: pr.reviewRequestedAt[$0.login] ?? pr.createdAt) }
        }
        .sorted { $0.since < $1.since }
        pendingReviews = pending

        let outcomesByLogin = Dictionary(grouping: outcomes, by: \.login)
        let pendingByLogin = Dictionary(grouping: pending, by: \.login)
        let reviewerLogins = Set(outcomesByLogin.keys).union(pendingByLogin.keys)
            .filter { !hidden.contains(HiddenStore.personKey($0)) }
        reviewers = reviewerLogins.map { login in
            let requests = outcomesByLogin[login] ?? []
            let waiting = pendingByLogin[login] ?? []
            return ReviewerMetrics(
                person: membersByLogin[login] ?? waiting.first?.pr.requestedReviewers.first { $0.login == login }
                    ?? Person(login: login, name: nil, avatarUrl: nil),
                requested: requests.count,
                answered: requests.filter { $0.respondedAt != nil }.count,
                responseTime: DurationStat(requests.compactMap(\.responseTime)),
                pending: waiting.count,
                oldestPendingSince: waiting.first?.since,
                unrequested: unrequested[login] ?? 0
            )
        }
        .sorted { ($0.requested + $0.pending, $1.person.login) > ($1.requested + $1.pending, $0.person.login) }

        repos = Dictionary(grouping: merged, by: \.repo)
            .map { RepoMetrics(repo: $0.key, merged: $0.value.count, cycleTime: DurationStat($0.value.map(\.cycleTime))) }
            .sorted { ($0.merged, $1.repo) > ($1.merged, $0.repo) }

        prSize = SizeStat(merged)
        repoRisks = Dictionary(grouping: merged.filter { $0.size > SizeStat.largeLines }, by: \.repo)
            .map { repo, large in
                let sizes = (merged.filter { $0.repo == repo }.map(\.size)).sorted()
                return RepoRisk(repo: repo, large: large.count, rushed: large.filter(\.isRushed), medianSize: sizes.isEmpty ? 0 : sizes[sizes.count / 2])
            }
            .sorted { ($0.rushed.count, $0.large) > ($1.rushed.count, $1.large) }
        answeredShare = outcomes.isEmpty ? nil : Double(outcomes.filter { $0.respondedAt != nil }.count) / Double(outcomes.count)

        // The period before, from what the history holds, when it reaches
        // back that far.
        if history.coveredFrom <= previousInterval.start {
            let before = considered.filter { previousInterval.contains($0.mergedAt) && $0.mergedAt < previousInterval.end && inTeam($0.author?.login) }
            var requests = 0
            var answered = 0
            for pr in considered where previousInterval.contains(pr.mergedAt) {
                for request in pr.reviewRequests where inTeam(request.login) {
                    let deadline = request.removedAt ?? pr.mergedAt
                    let response = pr.reviews.first { $0.login == request.login && $0.submittedAt >= request.requestedAt && $0.submittedAt <= deadline }
                    if response == nil && request.removedAt != nil { continue }
                    requests += 1
                    if response != nil { answered += 1 }
                }
            }
            let rework = StageSummary(before.compactMap { $0.duration(of: .rework) })
            let sizes = before.map(\.size).sorted()
            func breakdown(_ key: (MetricPullRequest) -> String) -> [String: (count: Int, cycleTime: TimeInterval?)] {
                Dictionary(grouping: before, by: key).mapValues { ($0.count, DurationStat($0.map(\.cycleTime)).median) }
            }
            previous = DeliverySummary(
                merged: before.count,
                cycleTime: DurationStat(before.map(\.cycleTime)),
                timeToFirstReview: DurationStat(before.compactMap(\.timeToFirstReview)),
                stages: Dictionary(uniqueKeysWithValues: CycleStage.allCases.map { stage in
                    (stage, StageSummary(before.compactMap { $0.duration(of: stage) }))
                }),
                reworkShare: before.isEmpty ? nil : rework.share,
                unreviewedShare: before.isEmpty ? nil : Double(before.filter { $0.firstReviewAt == nil && config.needsReview($0.repo) }.count) / Double(before.count),
                prSizeMedian: sizes.isEmpty ? nil : sizes[sizes.count / 2],
                answeredShare: requests == 0 ? nil : Double(answered) / Double(requests),
                opened: {
                    let weeks = history.openedPerWeek.filter { $0.key >= Calendar.metrics.startOfWeek(for: previousInterval.start) && $0.key < Calendar.metrics.startOfWeek(for: windowStart) }
                    return weeks.isEmpty ? nil : weeks.values.reduce(0, +)
                }(),
                repos: breakdown(\.repo),
                authors: breakdown { $0.author?.login ?? "" }
            )
        } else {
            previous = nil
        }
    }

    /// Now, as the summary for comparing with `previous`.
    var current: DeliverySummary {
        func breakdown(_ key: (MetricPullRequest) -> String) -> [String: (count: Int, cycleTime: TimeInterval?)] {
            Dictionary(grouping: merged, by: key).mapValues { ($0.count, DurationStat($0.map(\.cycleTime)).median) }
        }
        return DeliverySummary(
            merged: merged.count, cycleTime: cycleTime, timeToFirstReview: timeToFirstReview, stages: stages,
            reworkShare: merged.isEmpty ? nil : stages[.rework]?.share,
            unreviewedShare: merged.isEmpty ? nil : Double(mergedWithoutReview.count) / Double(merged.count),
            prSizeMedian: prSize.median, answeredShare: answeredShare, opened: opened,
            repos: breakdown(\.repo), authors: breakdown { $0.author?.login ?? "" }
        )
    }

    func pullRequest(id: String) -> MetricPullRequest? { byID[id] }

    func mergedInRange(_ range: Range<Date>) -> [MetricPullRequest] {
        coverage.filter { range.contains($0.mergedAt) }
    }
}

extension TimeInterval {
    /// Compact duration: seconds under a minute, minutes under an hour,
    /// hours under two days, else days.
    var compactDuration: String {
        if self < 59.5 { return "\(Int(max(self, 0).rounded()))s" }
        let minutes = self / 60
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        let hours = minutes / 60
        if hours < 48 { return hours.formatted(.number.precision(.fractionLength(hours < 10 ? 1 : 0))) + "h" }
        let days = hours / 24
        return days.formatted(.number.precision(.fractionLength(days < 10 ? 1 : 0))) + "d"
    }
}
