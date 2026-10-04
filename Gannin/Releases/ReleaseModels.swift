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

    /// Its name, else its tag.
    var title: String {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return tagName }
        return name
    }

    var date: Date { publishedAt ?? createdAt }
}

/// Each org's milestones (open ones and those closed lately) and latest
/// releases, per repo.
struct ReleaseHistory: Codable {
    /// 2 added pull request counts.
    static let currentVersion = 2

    let version: Int
    let orgLogin: String
    var syncedAt: Date
    var milestones: [RepoMilestone]
    var releases: [RepoRelease]
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
