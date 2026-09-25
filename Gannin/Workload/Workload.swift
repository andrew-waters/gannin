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

    var id: String { person.login }

    /// Items needing their attention. An assigned issue that one of their
    /// own open PRs already closes is the same piece of work, so it isn't
    /// counted twice.
    var inFlight: Int {
        let coveredIssueIDs = Set(pullRequests.flatMap(\.linkedIssues).map(\.id))
        let uncovered = issues.filter { !coveredIssueIDs.contains($0.id) }
        return pullRequests.count + uncovered.count + reviewRequests.count
    }

    var stalePullRequests: [PullRequest] {
        pullRequests.filter(Workload.isStale)
    }
}

/// Derived, filterable view over an `OrgSnapshot`.
struct Workload {
    static let staleAfterDays = 7

    let snapshot: OrgSnapshot
    let team: Team?
    let people: [PersonLoad]
    let openPullRequests: [PullRequest]
    let mergedPullRequests: [PullRequest]
    let assignedIssues: [Issue]
    let unassignedIssues: [Issue]

    private let pullRequestsByID: [String: PullRequest]
    private let issuesByID: [String: Issue]

    init(snapshot: OrgSnapshot, team: Team?) {
        self.snapshot = snapshot
        self.team = team

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

        people = Self.loads(snapshot: snapshot, teamLogins: teamLogins)
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

        return byLogin.values.sorted {
            if $0.inFlight != $1.inFlight { return $0.inFlight > $1.inFlight }
            return $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending
        }
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
