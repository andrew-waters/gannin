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

    var id: String { person.login }
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

/// Metrics for one window over an org's merged-PR history, optionally
/// scoped to a team. Bot-authored PRs are left out.
struct OrgMetrics {
    let windowDays: Int
    let windowStart: Date
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
        windowDays: Int,
        team: Team?,
        members: [Person],
        hidden: Set<String>,
        config: OrgConfig = OrgConfig(),
        openPullRequests: [PullRequest] = [],
        now: Date = .now
    ) {
        let windowStart = Calendar.metrics.date(byAdding: .day, value: -windowDays, to: now) ?? now
        self.windowDays = windowDays
        self.windowStart = windowStart
        syncedAt = history.syncedAt
        isTeamScoped = team != nil

        let teamLogins = team.map { Set($0.members) }
        func inTeam(_ login: String?) -> Bool {
            guard let teamLogins else { return true }
            return login.map(teamLogins.contains) ?? false
        }

        let coverageStart = MetricsStore.coverageStart(windowDays: windowDays, now: now)
        // Excluded authors lose their PRs and their reviews, so a review by
        // an excluded account never counts as a PR's first review.
        let inRange = history.pullRequests.values
            .filter {
                !$0.authorIsBot && !hidden.contains($0.id) && $0.mergedAt >= coverageStart
                    && !config.excludedRepos.contains($0.repo)
                    && !config.excludes($0.author?.login ?? "")
            }
            .map { pr in
                var pr = pr
                pr.reviews.removeAll { config.excludes($0.login) }
                pr.reviewRequests.removeAll { config.excludes($0.login) }
                return pr
            }
        let merged = inRange
            .filter { $0.mergedAt >= windowStart && inTeam($0.author?.login) }
            .sorted { $0.mergedAt > $1.mergedAt }
        self.merged = merged
        let coverage = inRange.filter { inTeam($0.author?.login) }
        self.coverage = coverage
        byID = Dictionary(coverage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        opened = history.openedPerWeek
            .filter { $0.key >= Calendar.metrics.startOfWeek(for: windowStart) }
            .map(\.value)
            .reduce(0, +)
        cycleTime = DurationStat(merged.map(\.cycleTime))
        timeToFirstReview = DurationStat(merged.compactMap(\.timeToFirstReview))
        stages = Dictionary(uniqueKeysWithValues: CycleStage.allCases.map { stage in
            (stage, StageSummary(merged.compactMap { $0.duration(of: stage) }))
        })
        mergedWithoutReview = merged.filter { $0.firstReviewAt == nil }

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
                reviewsGiven: reviewed[login] ?? 0
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
    }

    func pullRequest(id: String) -> MetricPullRequest? { byID[id] }

    func mergedInRange(_ range: Range<Date>) -> [MetricPullRequest] {
        coverage.filter { range.contains($0.mergedAt) }
    }
}

extension TimeInterval {
    /// Compact duration: minutes under an hour, hours under two days, else days.
    var compactDuration: String {
        let minutes = self / 60
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        let hours = minutes / 60
        if hours < 48 { return hours.formatted(.number.precision(.fractionLength(hours < 10 ? 1 : 0))) + "h" }
        let days = hours / 24
        return days.formatted(.number.precision(.fractionLength(days < 10 ? 1 : 0))) + "d"
    }
}
