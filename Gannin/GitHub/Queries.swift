import Foundation

// MARK: - Viewer and organisations

extension GitHubAPI {
    func viewer() async throws -> Viewer {
        struct Response: Decodable { let viewer: Viewer }
        let response: Response = try await query("query { viewer { login name avatarUrl } }")
        return response.viewer
    }

    /// Orgs the signed-in user is a member of; their own account is added
    /// by `OrgStore`.
    func organisations() async throws -> [Organisation] {
        struct Response: Decodable {
            struct ViewerOrgs: Decodable { let organizations: PagedConnection<Organisation> }
            let viewer: ViewerOrgs
        }
        return try await paginate { cursor in
            let response: Response = try await query("""
                query($cursor: String) {
                  viewer {
                    organizations(first: 100, after: $cursor) {
                      pageInfo { hasNextPage endCursor }
                      nodes { id login name avatarUrl description }
                    }
                  }
                }
                """, variables: cursorVariables(cursor))
            return response.viewer.organizations
        }
    }
}

// MARK: - Org snapshot

extension GitHubAPI {
    /// How much of a snapshot to fetch again. Anything not fetched is carried
    /// over from the previous snapshot.
    struct SnapshotPlan {
        /// Members and teams.
        var people = true
        /// Search only for PRs and issues updated since this date and merge
        /// them in, rather than searching for everything.
        var changesSince: Date?
    }

    /// The workload snapshot. Each query is tracked as a step of `run`.
    func snapshot(
        org: String,
        lookbackDays: Int,
        previous: OrgSnapshot?,
        plan: SnapshotPlan,
        run: SyncRun
    ) async throws -> OrgSnapshot {
        let startedAt = Date.now
        let mergedSince = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -lookbackDays, to: startedAt) ?? startedAt
        )
        let scope = "\(GitHubAccounts.scope(org)) archived:false"
        let fetchPeople = plan.people || previous == nil
        let changesSince = previous == nil ? nil : plan.changesSince

        if fetchPeople {
            run.add("members", title: "Members")
            run.add("teams", title: "Teams")
        }
        if let changesSince {
            let since = changesSince.formatted(date: .omitted, time: .shortened)
            run.add("changed-prs", title: "Pull requests", detail: "Changed since \(since)")
            run.add("changed-issues", title: "Issues", detail: "Changed since \(since)")
        } else {
            run.add("open-prs", title: "Open PRs")
            run.add("merged-prs", title: "Merged PRs", detail: "Last \(lookbackDays) days")
            run.add("issues", title: "Open issues")
        }

        var searches: [String: String] = [:]
        if let changesSince {
            // Search takes a full timestamp; `+00:00` rather than `Z` is the
            // form GitHub documents.
            let timestamp = changesSince.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00")
            searches["changed-prs"] = "\(scope) is:pr updated:>=\(timestamp)"
            searches["changed-issues"] = "\(scope) is:issue updated:>=\(timestamp)"
        } else {
            let since = mergedSince.formatted(.iso8601.year().month().day())
            searches["open-prs"] = "\(scope) is:pr is:open sort:updated-desc"
            searches["merged-prs"] = "\(scope) is:pr is:merged merged:>=\(since) sort:updated-desc"
            searches["issues"] = "\(scope) is:issue is:open sort:updated-desc"
        }

        // Every step's total up front, in one cheap request, so progress is
        // by items from the start. Search and the member and team lists stop
        // at 1000, 1000 and 300. Progress only, so a failure is ignored.
        let limits = ["members": 1000, "teams": 300]
        if let counts = try? await run.overhead({ try await counts(searches: searches, membersOf: fetchPeople ? org : nil) }) {
            for (id, count) in counts { run.setTotal(min(count, limits[id] ?? 1000), for: id) }
        }

        let plannedSearches = searches
        async let memberList: [Person]? = fetchPeople ? fetchMembers(org: org, run: run) : nil
        async let teamResult: [Team]? = fetchPeople ? fetchTeams(org: org, run: run) : nil
        async let items = fetchChanges(searches: plannedSearches, run: run)
        async let fullItems = changesSince == nil ? fetchAll(searches: plannedSearches, run: run) : nil

        var warnings = previous?.warnings ?? []
        var teamList = previous?.teams ?? []
        if fetchPeople {
            do {
                teamList = try await teamResult ?? []
                warnings = []
            } catch {
                teamList = []
                warnings = ["Teams unavailable: \(error.localizedDescription)"]
            }
        }
        let members = try await memberList ?? previous?.members ?? []

        var open: [PullRequest]
        var merged: [PullRequest]
        var issues: [Issue]
        if let full = try await fullItems {
            (open, merged, issues) = full
        } else if let changes = try await items, let previous {
            guard !changes.truncated else {
                // Too much changed to trust a merge: search everything instead.
                let carried = previous.with(members: members, teams: teamList, warnings: warnings, peopleFetchedAt: fetchPeople ? startedAt : previous.peopleFetchedAt)
                return try await snapshot(org: org, lookbackDays: lookbackDays, previous: carried, plan: SnapshotPlan(people: false), run: run)
            }
            (open, merged, issues) = previous.merging(changes, mergedSince: mergedSince)
        } else {
            (open, merged, issues) = ([], [], [])
        }

        return OrgSnapshot(
            orgLogin: org,
            fetchedAt: startedAt,
            peopleFetchedAt: fetchPeople ? startedAt : previous?.peopleFetchedAt,
            fullFetchedAt: changesSince == nil ? startedAt : previous?.fullFetchedAt,
            lookbackDays: lookbackDays,
            members: members,
            teams: teamList,
            openPullRequests: open,
            mergedPullRequests: merged,
            issues: issues,
            warnings: warnings
        )
    }

    private func fetchMembers(org: String, run: SyncRun) async throws -> [Person] {
        try await run.track("members", count: \.count) { try await members(org: org, onPage: $0) }
    }

    private func fetchTeams(org: String, run: SyncRun) async throws -> [Team] {
        try await run.track("teams", count: \.count) { try await teams(org: org, onPage: $0) }
    }

    /// Open PRs, PRs merged in the lookback and open issues, in full; nil
    /// when `searches` is for changes.
    private func fetchAll(searches: [String: String], run: SyncRun) async throws -> ([PullRequest], [PullRequest], [Issue])? {
        guard let openQuery = searches["open-prs"], let mergedQuery = searches["merged-prs"], let issueQuery = searches["issues"] else {
            return nil
        }
        async let open = run.track("open-prs", count: \.count) {
            try await pullRequests(openQuery, onPage: $0).items
        }
        async let merged = run.track("merged-prs", count: \.count) {
            try await pullRequests(mergedQuery, onPage: $0).items
        }
        async let issueList = run.track("issues", count: \.count) {
            try await issues(issueQuery, onPage: $0).items
        }
        return try await (open, merged, issueList)
    }

    /// PRs and issues in any state updated since the last fetch; nil when
    /// `searches` is for everything.
    private func fetchChanges(searches: [String: String], run: SyncRun) async throws -> SnapshotChanges? {
        guard let prQuery = searches["changed-prs"], let issueQuery = searches["changed-issues"] else { return nil }
        async let prs = run.track("changed-prs", count: \.items.count) {
            try await pullRequests(prQuery, onPage: $0)
        }
        async let issueList = run.track("changed-issues", count: \.items.count) {
            try await issues(issueQuery, onPage: $0)
        }
        let (prResult, issueResult) = try await (prs, issueList)
        return SnapshotChanges(
            pullRequests: prResult.items,
            issues: issueResult.items,
            truncated: prResult.isTruncated || issueResult.isTruncated
        )
    }

    private func members(org: String, onPage: (Int, Int?) -> Void) async throws -> [Person] {
        // A personal account's only member is its owner.
        if GitHubAccounts.isUser(org) {
            struct Response: Decodable { let user: Person? }
            let response: Response = try await query("query($login: String!) { user(login: $login) { login name avatarUrl } }", variables: ["login": org])
            onPage(1, 1)
            return response.user.map { [$0] } ?? []
        }
        struct Response: Decodable {
            struct Org: Decodable { let membersWithRole: PagedConnection<Person> }
            let organization: Org?
        }
        return try await paginate(onPage: onPage) { cursor in
            var variables = cursorVariables(cursor)
            variables["login"] = org
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  organization(login: $login) {
                    membersWithRole(first: 100, after: $cursor) {
                      totalCount
                      pageInfo { hasNextPage endCursor }
                      nodes { login name avatarUrl }
                    }
                  }
                }
                """, variables: variables)
            return response.organization?.membersWithRole
        }
    }

    private func teams(org: String, onPage: (Int, Int?) -> Void) async throws -> [Team] {
        guard !GitHubAccounts.isUser(org) else { return [] }
        struct RawTeam: Decodable {
            struct Member: Decodable { let login: String }
            let id: String
            let slug: String
            let name: String
            let members: Connection<Member>
        }
        struct Response: Decodable {
            struct Org: Decodable { let teams: PagedConnection<RawTeam> }
            let organization: Org?
        }
        let raw: [RawTeam] = try await paginate(limit: 300, onPage: onPage) { cursor in
            var variables = cursorVariables(cursor)
            variables["login"] = org
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  organization(login: $login) {
                    teams(first: 100, after: $cursor) {
                      totalCount
                      pageInfo { hasNextPage endCursor }
                      nodes { id slug name members(first: 100) { nodes { login } } }
                    }
                  }
                }
                """, variables: variables)
            return response.organization?.teams
        }
        return raw.map { Team(id: $0.id, slug: $0.slug, name: $0.name, members: $0.members.nodes.map(\.login)) }
    }

    private func pullRequests(_ searchQuery: String, onPage: (Int, Int?) -> Void) async throws -> SearchResult<PullRequest> {
        // PR nodes carry several nested connections; smaller pages keep
        // each request under GitHub's timeout.
        var total: Int?
        let nodes: [Lossy<RawPullRequest>] = try await search(searchQuery, fields: RawPullRequest.fields, pageSize: 50) {
            total = $1
            onPage($0, $1)
        }
        return SearchResult(items: nodes.compactMap { $0.value?.model }, total: total)
    }

    private func issues(_ searchQuery: String, onPage: (Int, Int?) -> Void) async throws -> SearchResult<Issue> {
        var total: Int?
        let nodes: [Lossy<RawIssue>] = try await search(searchQuery, fields: RawIssue.fields) {
            total = $1
            onPage($0, $1)
        }
        return SearchResult(items: nodes.compactMap { $0.value?.model }, total: total)
    }

    /// How many results each search matches (uncapped), keyed as given, in
    /// one request. With `membersOf`, also the org's "members" and "teams".
    func counts(searches: [String: String], membersOf org: String? = nil) async throws -> [String: Int] {
        let keys = searches.keys.sorted()
        var variables: [String: String] = [:]
        var definitions: [String] = []
        var fields: [String] = []
        for (index, key) in keys.enumerated() {
            variables["q\(index)"] = searches[key]
            definitions.append("$q\(index): String!")
            fields.append("s\(index): search(query: $q\(index), type: ISSUE, first: 1) { issueCount }")
        }
        if let org, !GitHubAccounts.isUser(org) {
            variables["login"] = org
            definitions.append("$login: String!")
            fields.append("org: organization(login: $login) { membersWithRole(first: 1) { totalCount } teams(first: 1) { totalCount } }")
        }
        guard !fields.isEmpty else { return [:] }

        let response: [String: CountNode?] = try await query(
            "query(\(definitions.joined(separator: ", "))) { \(fields.joined(separator: " ")) }",
            variables: variables
        )
        var counts: [String: Int] = [:]
        for (index, key) in keys.enumerated() {
            if let count = response["s\(index)"]??.issueCount { counts[key] = count }
        }
        if let node = response["org"] ?? nil {
            counts["members"] = node.membersWithRole?.totalCount
            counts["teams"] = node.teams?.totalCount
        }
        return counts
    }

    /// Issue/PR search. GitHub caps search results at 1000.
    func search<Node: Decodable>(
        _ searchQuery: String,
        fields: String,
        pageSize: Int = 100,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> [Node] {
        return try await paginate(onPage: onPage) { cursor in
            var variables = cursorVariables(cursor)
            variables["q"] = searchQuery
            let response: SearchResponse<Node> = try await query("""
                query($q: String!, $cursor: String) {
                  search(query: $q, type: ISSUE, first: \(pageSize), after: $cursor) {
                    issueCount
                    pageInfo { hasNextPage endCursor }
                    nodes { \(fields) }
                  }
                }
                """, variables: variables)
            return response.search
        }
    }

    private func cursorVariables(_ cursor: String?) -> [String: String] {
        cursor.map { ["cursor": $0] } ?? [:]
    }
}

// MARK: - Item detail

extension GitHubAPI {
    /// Description, recent comments and (for PRs) branch and checks.
    func itemDetail(id: String) async throws -> ItemDetail? {
        struct RawComment: Decodable {
            let url: URL
            let author: RawActor?
            let body: String
            let createdAt: Date
        }
        struct Comments: Decodable {
            let totalCount: Int
            let nodes: [RawComment]
        }
        struct Rollup: Decodable { let state: ItemDetail.CheckState }
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct CommitNode: Decodable { let commit: Commit }
        struct Node: Decodable {
            let body: String?
            let updatedAt: Date?
            let comments: Comments?
            let headRefName: String?
            let baseRefName: String?
            let commits: Connection<CommitNode>?
        }
        struct Response: Decodable { let node: Node? }

        let comments = "comments(last: 5) { totalCount nodes { url body createdAt author { login avatarUrl } } }"
        let response: Response = try await query("""
            query($id: ID!) {
              node(id: $id) {
                ... on Issue { body updatedAt \(comments) }
                ... on PullRequest {
                  body updatedAt headRefName baseRefName \(comments)
                  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
                }
              }
            }
            """, variables: ["id": id])
        guard let node = response.node, let body = node.body else { return nil }
        return ItemDetail(
            body: body,
            commentCount: node.comments?.totalCount ?? 0,
            recentComments: (node.comments?.nodes ?? []).map {
                Comment(url: $0.url, author: $0.author?.person, body: $0.body, createdAt: $0.createdAt)
            },
            headRef: node.headRefName,
            baseRef: node.baseRefName,
            checks: node.commits?.nodes.first?.commit.statusCheckRollup?.state,
            updatedAt: node.updatedAt
        )
    }
}

// MARK: - Snapshot merging

nonisolated private struct SearchResult<Item: Sendable>: Sendable {
    let items: [Item]
    /// Matches GitHub reports, which can exceed what search will return.
    let total: Int?

    /// Search stops at 1000 results, so anything past that was missed.
    var isTruncated: Bool { (total ?? 0) > 1000 }
}

/// PRs and issues updated since the previous snapshot, in any state.
struct SnapshotChanges {
    let pullRequests: [PullRequest]
    let issues: [Issue]
    let truncated: Bool
}

extension OrgSnapshot {
    /// The previous lists with changed items swapped in: open ones kept,
    /// newly merged PRs moved across, closed ones dropped, and merged PRs
    /// that have aged out of the lookback removed.
    func merging(_ changes: SnapshotChanges, mergedSince: Date) -> ([PullRequest], [PullRequest], [Issue]) {
        var open = Dictionary(openPullRequests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = Dictionary(mergedPullRequests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var openIssues = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for pr in changes.pullRequests {
            open[pr.id] = pr.state == "OPEN" ? pr : nil
            merged[pr.id] = pr.state == "MERGED" ? pr : nil
        }
        for issue in changes.issues {
            openIssues[issue.id] = issue.state == "OPEN" ? issue : nil
        }
        let newestFirst = { (a: PullRequest, b: PullRequest) in a.updatedAt > b.updatedAt }
        return (
            open.values.sorted(by: newestFirst),
            merged.values.filter { ($0.mergedAt ?? .distantPast) >= mergedSince }.sorted(by: newestFirst),
            openIssues.values.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    /// A copy with fresh members and teams.
    func with(members: [Person], teams: [Team], warnings: [String], peopleFetchedAt: Date?) -> OrgSnapshot {
        OrgSnapshot(
            orgLogin: orgLogin,
            fetchedAt: fetchedAt,
            peopleFetchedAt: peopleFetchedAt,
            fullFetchedAt: fullFetchedAt,
            lookbackDays: lookbackDays,
            members: members,
            teams: teams,
            openPullRequests: openPullRequests,
            mergedPullRequests: mergedPullRequests,
            issues: issues,
            warnings: warnings
        )
    }
}

// MARK: - Raw GraphQL shapes

/// Any of the aliased fields in a counts query (and the `rateLimit` beside
/// them, which decodes to all nils).
private struct CountNode: Decodable {
    struct Total: Decodable { let totalCount: Int }
    let issueCount: Int?
    let membersWithRole: Total?
    let teams: Total?
}

private struct SearchResponse<Node: Decodable>: Decodable {
    let search: PagedConnection<Node>
}

/// Decodes to nil instead of failing, so one odd search node (a type outside
/// the fragment decodes as `{}`) doesn't sink the whole page.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct RawActor: Decodable {
    let login: String?
    let avatarUrl: URL?

    var person: Person? {
        login.map { Person(login: $0, name: nil, avatarUrl: avatarUrl) }
    }
}

private struct RawRepository: Decodable {
    let nameWithOwner: String
}

private struct RawLinked: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let repository: RawRepository

    var model: LinkedItem {
        LinkedItem(id: id, number: number, title: title, url: url, repo: repository.nameWithOwner, state: state)
    }

    static let fields = "id number title url state repository { nameWithOwner }"
}

private struct RawPullRequest: Decodable {
    struct ReviewRequest: Decodable { let requestedReviewer: RawActor? }
    struct RequestedEvent: Decodable {
        let createdAt: Date?
        let requestedReviewer: RawActor?
    }
    struct Review: Decodable { let author: RawActor?; let state: String? }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let reviewDecision: PullRequest.ReviewState?
    let additions: Int
    let deletions: Int
    let repository: RawRepository
    let author: RawActor?
    let assignees: Connection<RawActor>
    let reviewRequests: Connection<ReviewRequest>?
    let latestReviews: Connection<Review>?
    let closingIssuesReferences: Connection<RawLinked>?
    let timelineItems: Connection<Lossy<RequestedEvent>>?
    let commits: Connection<CommitNode>?

    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: String }
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }

    static let fields = """
        ... on PullRequest {
          id number title url isDraft state createdAt updatedAt mergedAt reviewDecision additions deletions
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          repository { nameWithOwner }
          author { login avatarUrl }
          assignees(first: 10) { nodes { login avatarUrl } }
          reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login avatarUrl } } } }
          latestReviews(first: 10) { nodes { state author { login avatarUrl } } }
          closingIssuesReferences(first: 10) { nodes { \(RawLinked.fields) } }
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) {
            nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } }
          }
        }
        """

    var model: PullRequest {
        var requestedAt: [String: Date] = [:]
        for event in (timelineItems?.nodes ?? []).compactMap(\.value) {
            guard let login = event.requestedReviewer?.login, let at = event.createdAt else { continue }
            requestedAt[login] = max(requestedAt[login] ?? .distantPast, at)
        }
        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author?.person,
            isDraft: isDraft,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            reviewDecision: reviewDecision,
            additions: additions,
            deletions: deletions,
            assignees: assignees.nodes.compactMap(\.person),
            requestedReviewers: (reviewRequests?.nodes ?? []).compactMap { $0.requestedReviewer?.person },
            reviewRequestedAt: requestedAt,
            reviewers: (latestReviews?.nodes ?? []).compactMap { $0.author?.person },
            linkedIssues: (closingIssuesReferences?.nodes ?? []).map(\.model),
            checks: commits?.nodes.first?.commit.statusCheckRollup.flatMap { ItemDetail.CheckState(rawValue: $0.state) },
            reviewStates: Dictionary(
                (latestReviews?.nodes ?? []).compactMap { review in
                    review.author?.login.flatMap { login in review.state.map { (login, $0) } }
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}

private struct RawIssue: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let repository: RawRepository
    let author: RawActor?
    let assignees: Connection<RawActor>
    let labels: Connection<IssueLabel>?
    let closedByPullRequestsReferences: Connection<RawLinked>?

    static let fields = """
        ... on Issue {
          id number title url state createdAt updatedAt closedAt
          repository { nameWithOwner }
          author { login avatarUrl }
          assignees(first: 10) { nodes { login avatarUrl } }
          labels(first: 10) { nodes { name color } }
          closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { \(RawLinked.fields) } }
        }
        """

    var model: Issue {
        Issue(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author?.person,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            assignees: assignees.nodes.compactMap(\.person),
            labels: labels?.nodes ?? [],
            linkedPullRequests: (closedByPullRequestsReferences?.nodes ?? []).map(\.model)
        )
    }
}
