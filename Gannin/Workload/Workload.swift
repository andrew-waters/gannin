import Foundation

/// What one person has in flight across an org.
struct PersonLoad: Identifiable, Hashable {
    let person: Person
    /// Open PRs they authored or are assigned to.
    var pullRequests: [PullRequest] = []
    /// Open PRs waiting on their review.
    var reviewRequests: [PullRequest] = []
    /// Open issues assigned to them.
    var issues: [Issue] = []
    /// PRs they authored that merged within the lookback window.
    var merged: [PullRequest] = []
    /// IDs of their assigned issues that an open PR (anyone's) is closing.
    var inProgressIssueIDs: Set<String> = []

    var id: String { person.login }

    /// Assigned issues with an open PR against them.
    var activeIssues: [Issue] { issues.filter { inProgressIssueIDs.contains($0.id) } }

    /// Assigned issues nobody has opened a PR for yet.
    var notStartedIssues: [Issue] { issues.filter { !inProgressIssueIDs.contains($0.id) } }

    /// Active work plus review requests. Assigned issues nobody has started
    /// are backlog, not load, and an issue one of their own PRs closes is
    /// the same piece of work as the PR, so neither is counted.
    var inFlight: Int {
        let coveredIssueIDs = Set(pullRequests.flatMap(\.linkedIssues).map(\.id))
        let otherActive = activeIssues.filter { !coveredIssueIDs.contains($0.id) }
        return pullRequests.count + otherActive.count + reviewRequests.count
    }

    var stalePullRequests: [PullRequest] {
        pullRequests.filter(Workload.isStale)
    }
}

/// Derived, filterable view over an `OrgSnapshot`.
struct Workload {
    static let staleAfterDays = 7

    /// The snapshot with hidden items (and drafts, when excluded) removed.
    let snapshot: OrgSnapshot
    let team: Team?
    let people: [PersonLoad]
    let openPullRequests: [PullRequest]
    let mergedPullRequests: [PullRequest]
    let assignedIssues: [Issue]
    let unassignedIssues: [Issue]

    private let pullRequestsByID: [String: PullRequest]
    private let issuesByID: [String: Issue]

    /// Hidden PRs and issues in the snapshot, whether or not they're shown.
    let hiddenCount: Int

    struct Options {
        var excludeDrafts = false
        var hidden: Set<String> = []
        var showHidden = false
        /// The org's excluded repos and people, which drop out entirely.
        var config = OrgConfig()
    }

    init(snapshot raw: OrgSnapshot, team: Team?, options: Options = Options()) {
        self.team = team

        let hiddenIDs = (raw.openPullRequests.map(\.id) + raw.mergedPullRequests.map(\.id) + raw.issues.map(\.id))
            .filter(options.hidden.contains)
        hiddenCount = Set(hiddenIDs).count

        func isVisible(_ key: String) -> Bool { options.showHidden || !options.hidden.contains(key) }
        // Excluded in the org's settings, or hidden with the old per-person Hide.
        func isExcluded(_ login: String) -> Bool {
            options.config.excludes(login) || options.hidden.contains(HiddenStore.personKey(login))
        }
        func isIncluded(_ pr: PullRequest) -> Bool {
            !options.config.repoExclusion.contains(pr.repo) && !(pr.author.map { isExcluded($0.login) } ?? false)
        }
        let snapshot = OrgSnapshot(
            orgLogin: raw.orgLogin,
            fetchedAt: raw.fetchedAt,
            peopleFetchedAt: raw.peopleFetchedAt,
            fullFetchedAt: raw.fullFetchedAt,
            lookbackDays: raw.lookbackDays,
            members: raw.members.filter { !isExcluded($0.login) },
            teams: raw.teams,
            openPullRequests: raw.openPullRequests.filter { isVisible($0.id) && isIncluded($0) && !(options.excludeDrafts && $0.isDraft) },
            mergedPullRequests: raw.mergedPullRequests.filter { isVisible($0.id) && isIncluded($0) },
            issues: raw.issues.filter { isVisible($0.id) && !options.config.repoExclusion.contains($0.repo) },
            unreadableRepos: raw.unreadableRepos,
            warnings: raw.warnings
        )
        self.snapshot = snapshot

        let teamLogins = team.map { Set($0.members) }
        func involvesTeam(_ logins: some Sequence<String>) -> Bool {
            guard let teamLogins else { return true }
            return logins.contains(where: teamLogins.contains)
        }

        openPullRequests = snapshot.openPullRequests.filter {
            involvesTeam($0.workers.union($0.requestedReviewers.map(\.login)))
        }
        mergedPullRequests = snapshot.mergedPullRequests.filter { involvesTeam($0.workers) }
        let issues = snapshot.issues.filter { $0.assignees.isEmpty || involvesTeam($0.assignees.map(\.login)) }
        assignedIssues = issues.filter { !$0.assignees.isEmpty }
        // Unassigned work belongs to nobody, so it only shows org-wide.
        unassignedIssues = team == nil ? issues.filter(\.assignees.isEmpty) : []

        pullRequestsByID = Dictionary(
            (snapshot.openPullRequests + snapshot.mergedPullRequests).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        issuesByID = Dictionary(snapshot.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Without a member list, loads falls back to whoever shows up in the
        // activity, so excluded people are filtered here too.
        people = Self.loads(snapshot: snapshot, teamLogins: teamLogins)
            .filter { !isExcluded($0.person.login) }
    }

    private static func loads(snapshot: OrgSnapshot, teamLogins: Set<String>?) -> [PersonLoad] {
        var byLogin: [String: PersonLoad] = [:]
        for member in snapshot.members where teamLogins?.contains(member.login) ?? true {
            byLogin[member.login] = PersonLoad(person: member)
        }
        // Without a member list (e.g. hidden by org policy) fall back to
        // whoever shows up in the activity.
        let restrictToMembers = !snapshot.members.isEmpty

        func update(_ person: Person, _ change: (inout PersonLoad) -> Void) {
            if teamLogins.map({ !$0.contains(person.login) }) ?? false { return }
            if byLogin[person.login] == nil {
                if restrictToMembers { return }
                byLogin[person.login] = PersonLoad(person: person)
            }
            change(&byLogin[person.login]!)
        }

        for pr in snapshot.openPullRequests {
            var workers = pr.assignees
            if let author = pr.author, !workers.contains(where: { $0.login == author.login }) {
                workers.append(author)
            }
            for person in workers { update(person) { $0.pullRequests.append(pr) } }
            for person in pr.requestedReviewers { update(person) { $0.reviewRequests.append(pr) } }
        }
        for pr in snapshot.mergedPullRequests {
            if let author = pr.author { update(author) { $0.merged.append(pr) } }
        }
        for issue in snapshot.issues {
            for person in issue.assignees { update(person) { $0.issues.append(issue) } }
        }

        var inProgress = Set(snapshot.openPullRequests.flatMap(\.linkedIssues).map(\.id))
        for issue in snapshot.issues where issue.linkedPullRequests.contains(where: { $0.state == "OPEN" }) {
            inProgress.insert(issue.id)
        }
        for (login, load) in byLogin {
            byLogin[login]!.inProgressIssueIDs = inProgress.intersection(load.issues.map(\.id))
        }

        return byLogin.values.sorted {
            if $0.inFlight != $1.inFlight { return $0.inFlight > $1.inFlight }
            return $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending
        }
    }

    /// Open, ready PRs with no review yet, oldest first.
    var awaitingFirstReview: [PullRequest] {
        openPullRequests
            .filter { !$0.isDraft && $0.reviewers.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Repos with open or recently merged work, busiest first.
    var repositories: [RepositoryLoad] {
        var byName: [String: RepositoryLoad] = [:]
        for pr in openPullRequests { byName[pr.repo, default: RepositoryLoad(name: pr.repo)].openPullRequests.append(pr) }
        for pr in mergedPullRequests { byName[pr.repo, default: RepositoryLoad(name: pr.repo)].mergedPullRequests.append(pr) }
        for issue in assignedIssues + unassignedIssues { byName[issue.repo, default: RepositoryLoad(name: issue.repo)].issues.append(issue) }
        return byName.values.sorted {
            ($0.openPullRequests.count + $0.issues.count, $1.name) > ($1.openPullRequests.count + $1.issues.count, $0.name)
        }
    }

    func repository(named name: String) -> RepositoryLoad? {
        repositories.first { $0.name == name }
    }

    func load(for login: String) -> PersonLoad? {
        people.first { $0.person.login == login }
    }

    func pullRequest(id: String) -> PullRequest? { pullRequestsByID[id] }

    func issue(id: String) -> Issue? { issuesByID[id] }

    /// PRs linked to an issue, from either side of the relationship.
    func linkedPullRequests(for issue: Issue) -> [LinkedItem] {
        var items = issue.linkedPullRequests
        let known = Set(items.map(\.id))
        for pr in pullRequestsByID.values where !known.contains(pr.id) && pr.linkedIssues.contains(where: { $0.id == issue.id }) {
            items.append(LinkedItem(id: pr.id, number: pr.number, title: pr.title, url: pr.url, repo: pr.repo, state: pr.state))
        }
        return items
    }

    static func isStale(_ pr: PullRequest) -> Bool {
        guard pr.mergedAt == nil,
              let cutoff = Calendar.current.date(byAdding: .day, value: -staleAfterDays, to: .now) else {
            return false
        }
        return pr.updatedAt < cutoff
    }
}

/// Work in one repo, from the same filtered lists as the rest of `Workload`.
struct RepositoryLoad: Identifiable, Hashable {
    /// `owner/name`.
    let name: String
    var openPullRequests: [PullRequest] = []
    var mergedPullRequests: [PullRequest] = []
    var issues: [Issue] = []

    var id: String { name }

    /// The name without the org, which the sidebar already shows.
    var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }

    var url: URL? { URL(string: "https://github.com/\(name)") }

    var stalePullRequests: [PullRequest] { openPullRequests.filter(Workload.isStale) }
}
