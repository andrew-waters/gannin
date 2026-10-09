import Foundation

/// A repo's milestone, with GitHub's own counts of its issues and pull
/// requests, which its progress counts together.
struct RepoMilestone: Codable, Hashable, Identifiable {
    let id: String
    let repo: String
    let number: Int
    let title: String
    let description: String?
    let dueOn: Date?
    let isOpen: Bool
    let closedAt: Date?
    let updatedAt: Date
    let url: URL
    let openIssues: Int
    let closedIssues: Int
    let openPullRequests: Int
    /// Merged ones too.
    let closedPullRequests: Int

    var open: Int { openIssues + openPullRequests }
    var closed: Int { closedIssues + closedPullRequests }
    var total: Int { open + closed }
}

/// A file attached to a release, with GitHub's running count of its
/// downloads.
struct ReleaseAsset: Codable, Hashable {
    let name: String
    let downloadCount: Int
    let size: Int
}

/// A GitHub Release: a tag with its notes.
struct RepoRelease: Codable, Hashable, Identifiable {
    let id: String
    let repo: String
    let name: String?
    let tagName: String
    let url: URL
    let createdAt: Date
    /// Nil for a draft.
    let publishedAt: Date?
    let isDraft: Bool
    let isPrerelease: Bool
    let isLatest: Bool
    let author: String?
    let notes: String?
    let assets: [ReleaseAsset]

    /// Every asset's downloads, as GitHub counts them so far.
    var downloads: Int { assets.reduce(0) { $0 + $1.downloadCount } }

    /// Its name, else its tag.
    var title: String {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return tagName }
        return name
    }

    var date: Date { publishedAt ?? createdAt }
}

/// A repo with releases: its stars now, and how many releases GitHub says
/// it has.
struct ReleaseRepository: Codable, Hashable, Identifiable {
    let name: String
    let stars: Int
    let releaseCount: Int

    var id: String { name }
}

/// Each org's milestones (open ones and those closed lately), every
/// release of each repo, and the stars of those with releases.
struct ReleaseHistory: Codable {
    /// 2 added pull request counts; 3 every release, assets, repos and stars;
    /// 4 who the stargazers are.
    static let currentVersion = 4

    let version: Int
    let orgLogin: String
    var syncedAt: Date
    var milestones: [RepoMilestone]
    var releases: [RepoRelease]
    /// Repos with at least one release.
    var repositories: [ReleaseRepository]
    /// By repo.
    var stars: [String: StarHistory]
}

/// When a repo's current stargazers starred it, as stars per day, from
/// GitHub's `starredAt`, and who they are. Those who unstarred are gone from
/// it, as they are from any star history built this way.
struct StarHistory: Codable, Hashable {
    /// Stars a day, by the day's start, oldest first.
    var days: [StarDay]
    /// The latest `starredAt` counted, where the next fetch stops.
    var newest: Date?
    /// Stars older than the backfill reached (it stops at
    /// `ReleaseStore.starReach`), counted before the first day.
    var before: Int
    /// Who starred it, newest first, as far as the backfill reached.
    var stargazers: [Stargazer]

    struct StarDay: Codable, Hashable {
        let day: Date
        var count: Int
    }

    /// Adds stars (any order) to their days, and their stargazers.
    mutating func add(_ stars: [Stargazer], calendar: Calendar = .current) {
        guard !stars.isEmpty else { return }
        var counts = Dictionary(days.map { ($0.day, $0.count) }, uniquingKeysWith: +)
        for star in stars { counts[calendar.startOfDay(for: star.starredAt), default: 0] += 1 }
        days = counts.map { StarDay(day: $0.key, count: $0.value) }.sorted { $0.day < $1.day }
        newest = max(newest ?? .distantPast, stars.map(\.starredAt).max() ?? .distantPast)
        let known = Set(stars.map(\.login))
        stargazers = Array((stars + stargazers.filter { !known.contains($0.login) })
            .sorted { $0.starredAt > $1.starredAt }
            .prefix(ReleaseStore.starReach))
    }

    func gained(since start: Date) -> Int {
        days.filter { $0.day >= start }.reduce(0) { $0 + $1.count }
    }
}

/// Someone starring a repo: who they are, as GitHub's profile has it, and when.
struct Stargazer: Codable, Hashable {
    let login: String
    let name: String?
    let avatarURL: URL?
    let company: String?
    let location: String?
    let followers: Int
    let starredAt: Date

    var profileURL: URL? { URL(string: "https://github.com/\(login)") }
}

/// Download totals recorded once a day: GitHub only keeps each asset's
/// running count, so the history over time is Gannin's own, from the first
/// sync on this Mac. Kept apart from the cache, as it can't be fetched again.
struct DownloadHistory: Codable {
    static let currentVersion = 1

    let version: Int
    let orgLogin: String
    /// Oldest first, one a day.
    var snapshots: [DownloadSnapshot]

    /// Records the totals as the day's, replacing any recorded earlier that day.
    mutating func record(_ totals: [String: Int], at date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        snapshots.removeAll { $0.day == day }
        snapshots.append(DownloadSnapshot(day: day, repos: totals))
        snapshots.sort { $0.day < $1.day }
    }
}

struct DownloadSnapshot: Codable, Hashable {
    let day: Date
    /// Downloads by repo.
    let repos: [String: Int]

    func total(_ included: (String) -> Bool) -> Int {
        repos.reduce(0) { included($1.key) ? $0 + $1.value : $0 }
    }
}

/// What the Releases page charts, over the repos shown.
struct ReleaseUsage {
    struct Point: Hashable {
        let date: Date
        let value: Int
    }

    let repositories: [ReleaseRepository]
    let downloads: Int
    let stars: Int
    /// Recorded totals, one a day.
    let downloadsOverTime: [Point]
    /// Downloads since the snapshot nearest 30 days ago, when one is that old.
    let downloadsLately: Int?
    /// Downloads of the releases published each month, by the month's start.
    let downloadsByMonth: [Point]
    /// Cumulative stars by day, ending today.
    let starsOverTime: [Point]
    let starsLately: Int
    /// Stars in the last 30 days, by repo.
    let starsGained: [String: Int]
    /// Stars that came before the backfill's reach, counted at the start.
    let starsBefore: Int
    /// New stars by week, or by month over a longer history, by the bucket's start.
    let newStars: [Point]
    let newStarsBucket: StarBucket
    /// Every repo's stargazers, newest first.
    let stargazers: [RepoStargazer]

    /// How new stars are counted: by week (from Monday) until the history
    /// runs longer than `weeklyReach`, then by month.
    enum StarBucket {
        case week, month

        static let weeklyReach: TimeInterval = 182 * 24 * 60 * 60

        func start(of date: Date) -> Date {
            switch self {
            case .week: Calendar.metrics.startOfWeek(for: date)
            case .month: Calendar.metrics.dateInterval(of: .month, for: date)?.start ?? date
            }
        }
    }

    static let lately: TimeInterval = 30 * 24 * 60 * 60

    init(history: ReleaseHistory, downloadHistory: DownloadHistory?, releases: [RepoRelease], included: (String) -> Bool, now: Date = .now, calendar: Calendar = .current) {
        repositories = history.repositories.filter { included($0.name) }
        let downloads = releases.reduce(0) { $0 + $1.downloads }
        self.downloads = downloads
        stars = repositories.reduce(0) { $0 + $1.stars }

        let snapshots = downloadHistory?.snapshots ?? []
        downloadsOverTime = snapshots.map { Point(date: $0.day, value: $0.total(included)) }
        let cutoff = now.addingTimeInterval(-Self.lately)
        downloadsLately = snapshots.last(where: { $0.day <= cutoff }).map { downloads - $0.total(included) }

        var months: [Date: Int] = [:]
        for release in releases where !release.isDraft {
            let month = calendar.dateInterval(of: .month, for: release.date)?.start ?? release.date
            months[month, default: 0] += release.downloads
        }
        downloadsByMonth = months.map { Point(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }

        let histories = repositories.compactMap { history.stars[$0.name] }
        starsBefore = histories.reduce(0) { $0 + $1.before }
        starsGained = Dictionary(uniqueKeysWithValues: repositories.map { ($0.name, history.stars[$0.name]?.gained(since: cutoff) ?? 0) })
        starsLately = starsGained.values.reduce(0, +)
        let perDay = Dictionary(histories.flatMap(\.days).map { ($0.day, $0.count) }, uniquingKeysWith: +)
        var running = starsBefore
        var points: [Point] = []
        for day in perDay.keys.sorted() {
            running += perDay[day] ?? 0
            points.append(Point(date: day, value: running))
        }
        if let last = points.last, last.date < calendar.startOfDay(for: now) {
            points.append(Point(date: calendar.startOfDay(for: now), value: last.value))
        }
        starsOverTime = points

        let firstStar = perDay.keys.min() ?? now
        let bucket: StarBucket = now.timeIntervalSince(firstStar) > StarBucket.weeklyReach ? .month : .week
        newStarsBucket = bucket
        newStars = Self.newStars(perDay, bucket: bucket)
        stargazers = repositories
            .flatMap { repo in (history.stars[repo.name]?.stargazers ?? []).map { RepoStargazer(repo: repo.name, stargazer: $0) } }
            .sorted { $0.stargazer.starredAt > $1.stargazer.starredAt }
    }

    /// Stars per day added up by bucket, with empty buckets between the
    /// first and last as zero, so quiet spells show.
    static func newStars(_ perDay: [Date: Int], bucket: StarBucket) -> [Point] {
        var counts: [Date: Int] = [:]
        for (day, count) in perDay { counts[bucket.start(of: day), default: 0] += count }
        guard let first = counts.keys.min(), let last = counts.keys.max() else { return [] }
        var points: [Point] = []
        var start = first
        while start <= last {
            points.append(Point(date: start, value: counts[start] ?? 0))
            let component: Calendar.Component = bucket == .week ? .weekOfYear : .month
            guard let next = Calendar.metrics.date(byAdding: component, value: 1, to: start) else { break }
            start = bucket.start(of: next)
        }
        return points
    }
}

/// A stargazer of one of the repos shown.
struct RepoStargazer: Identifiable, Hashable {
    let repo: String
    let stargazer: Stargazer

    var id: String { "\(repo)\u{0}\(stargazer.login)" }
}

/// Milestones with the same title across repos, as one: teams often run a
/// release over several repos with a milestone in each.
struct MilestoneGroup: Identifiable, Hashable {
    let key: String
    let title: String
    /// By repo.
    let milestones: [RepoMilestone]

    var id: String { key }

    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var repos: [String] { milestones.map(\.repo) }
    var isOpen: Bool { milestones.contains(where: \.isOpen) }
    /// Issues and pull requests, as GitHub's progress counts them.
    var closed: Int { milestones.reduce(0) { $0 + $1.closed } }
    var total: Int { milestones.reduce(0) { $0 + $1.total } }
    /// Issues alone, which is all the issue history holds.
    var issueTotal: Int { milestones.reduce(0) { $0 + $1.openIssues + $1.closedIssues } }
    /// The soonest due among the open ones, else the latest.
    var dueOn: Date? {
        milestones.filter(\.isOpen).compactMap(\.dueOn).min() ?? milestones.compactMap(\.dueOn).max()
    }
    var closedAt: Date? { isOpen ? nil : milestones.compactMap(\.closedAt).max() }
    var updatedAt: Date { milestones.map(\.updatedAt).max() ?? .distantPast }
    var description: String? {
        milestones.compactMap(\.description).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Grouped by title, leaving out excluded repos: open ones first, by due
    /// date (none last), then closed ones, most recently closed first.
    static func groups(_ milestones: [RepoMilestone], excluding exclusion: RepoExclusion) -> [MilestoneGroup] {
        Dictionary(grouping: milestones.filter { !exclusion.contains($0.repo) }) { key($0.title) }
            .map { key, milestones in
                let sorted = milestones.sorted { $0.repo < $1.repo }
                // The open one's spelling, if titles differ in case.
                let title = (sorted.first(where: \.isOpen) ?? sorted[0]).title
                return MilestoneGroup(key: key, title: title, milestones: sorted)
            }
            .sorted { a, b in
                if a.isOpen != b.isOpen { return a.isOpen }
                if a.isOpen {
                    switch (a.dueOn, b.dueOn) {
                    case let (x?, y?) where x != y: return x < y
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                    }
                }
                return (a.closedAt ?? .distantPast) > (b.closedAt ?? .distantPast)
            }
    }

    /// The issue history's issues with a milestone, by repo and milestone
    /// key, built once per render rather than scanned for each group.
    static func index(_ history: IssueHistory?) -> [String: [IssueRecord]] {
        guard let history else { return [:] }
        var index: [String: [IssueRecord]] = [:]
        for issue in history.issues.values {
            guard let milestone = issue.milestone else { continue }
            index[indexKey(repo: issue.repo, key: key(milestone)), default: []].append(issue)
        }
        return index
    }

    private static func indexKey(repo: String, key: String) -> String { "\(repo)\u{0}\(key)" }

    /// Its issues in the history: those in one of its repos with its title.
    /// Closed ones before the history's start aren't there.
    func issues(in index: [String: [IssueRecord]]) -> [IssueRecord] {
        repos.flatMap { index[Self.indexKey(repo: $0, key: key)] ?? [] }
    }
}

/// Where a milestone's issues stand, from the issue history.
struct MilestoneActivity {
    let issues: [IssueRecord]
    let inProgress: [IssueRecord]
    let withMergedPullRequest: Int

    /// `index` is `MilestoneGroup.index` of the issue history.
    init(group: MilestoneGroup, index: [String: [IssueRecord]], workflow: IssueWorkflow) {
        issues = group.issues(in: index)
        inProgress = issues.filter { issue in
            issue.isOpen && (issue.statusChanges.last(where: workflow.counts).map { workflow.isInProgress($0.status) } ?? false)
        }
        withMergedPullRequest = issues.filter { $0.linkedPullRequests.contains { $0.mergedAt != nil } }.count
    }
}

/// Milestones and releases matched by name: a milestone titled as a
/// release's tag or name (case and a leading `v` aside) in one of its repos.
enum ReleaseLink {
    static func normalised(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v"), text.dropFirst().first?.isNumber == true { text.removeFirst() }
        return text
    }

    static func matches(_ group: MilestoneGroup, _ release: RepoRelease) -> Bool {
        guard group.repos.contains(release.repo) else { return false }
        let title = normalised(group.title)
        return normalised(release.tagName) == title || release.name.map(normalised) == title
    }

    /// The release a milestone shipped as: the first published, else a draft.
    static func release(for group: MilestoneGroup, in releases: [RepoRelease]) -> RepoRelease? {
        releases.filter { matches(group, $0) }.min { ($0.isDraft ? 1 : 0, $0.date) < ($1.isDraft ? 1 : 0, $1.date) }
    }

    static func milestone(for release: RepoRelease, in groups: [MilestoneGroup]) -> MilestoneGroup? {
        groups.first { matches($0, release) }
    }
}
