import Foundation

// MARK: - Viewer and organisations

extension GitHubAPI {
    func viewer() async throws -> Viewer {
        struct Response: Decodable { let viewer: Viewer }
        let response: Response = try await query("query { viewer { login name avatarUrl } }")
        return response.viewer
    }

    /// Orgs the signed-in user is a member of.
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
    func snapshot(org: String, lookbackDays: Int) async throws -> OrgSnapshot {
        let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: .now) ?? .now
        let sinceString = since.formatted(.iso8601.year().month().day())
        let scope = "org:\(org) archived:false"

        async let memberList = members(org: org)
        async let teamResult = teams(org: org)
        async let openList = pullRequests("\(scope) is:pr is:open sort:updated-desc")
        async let mergedList = pullRequests("\(scope) is:pr is:merged merged:>=\(sinceString) sort:updated-desc")
        async let issueList = issues("\(scope) is:issue is:open sort:updated-desc")

        var warnings: [String] = []
        let teamList: [Team]
        do {
            teamList = try await teamResult
        } catch {
            teamList = []
            warnings.append("Teams unavailable: \(error.localizedDescription)")
        }

        return try await OrgSnapshot(
            orgLogin: org,
            fetchedAt: .now,
            lookbackDays: lookbackDays,
            members: memberList,
            teams: teamList,
            openPullRequests: openList,
            mergedPullRequests: mergedList,
            issues: issueList,
            warnings: warnings
        )
    }

    private func members(org: String) async throws -> [Person] {
        struct Response: Decodable {
            struct Org: Decodable { let membersWithRole: PagedConnection<Person> }
            let organization: Org?
        }
        return try await paginate { cursor in
            var variables = cursorVariables(cursor)
            variables["login"] = org
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  organization(login: $login) {
                    membersWithRole(first: 100, after: $cursor) {
                      pageInfo { hasNextPage endCursor }
                      nodes { login name avatarUrl }
                    }
                  }
                }
                """, variables: variables)
            return response.organization?.membersWithRole
        }
    }

    private func teams(org: String) async throws -> [Team] {
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
        let raw: [RawTeam] = try await paginate(limit: 300) { cursor in
            var variables = cursorVariables(cursor)
            variables["login"] = org
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  organization(login: $login) {
                    teams(first: 100, after: $cursor) {
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

    private func pullRequests(_ searchQuery: String) async throws -> [PullRequest] {
        let nodes: [Lossy<RawPullRequest>] = try await search(searchQuery, fields: RawPullRequest.fields)
        return nodes.compactMap { $0.value?.model }
    }

    private func issues(_ searchQuery: String) async throws -> [Issue] {
        let nodes: [Lossy<RawIssue>] = try await search(searchQuery, fields: RawIssue.fields)
        return nodes.compactMap { $0.value?.model }
    }

    /// Issue/PR search. GitHub caps search results at 1000.
    private func search<Node: Decodable>(_ searchQuery: String, fields: String) async throws -> [Node] {
        return try await paginate { cursor in
            var variables = cursorVariables(cursor)
            variables["q"] = searchQuery
            let response: SearchResponse<Node> = try await query("""
                query($q: String!, $cursor: String) {
                  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
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

// MARK: - Raw GraphQL shapes

private struct SearchResponse<Node: Decodable>: Decodable {
    let search: PagedConnection<Node>
}

/// Decodes to nil instead of failing, so one odd search node (a type outside
/// the fragment decodes as `{}`) doesn't sink the whole page.
private struct Lossy<Value: Decodable>: Decodable {
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
    struct Review: Decodable { let author: RawActor? }

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

    static let fields = """
        ... on PullRequest {
          id number title url isDraft state createdAt updatedAt mergedAt reviewDecision additions deletions
          repository { nameWithOwner }
          author { login avatarUrl }
          assignees(first: 10) { nodes { login avatarUrl } }
          reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login avatarUrl } } } }
          latestReviews(first: 10) { nodes { author { login avatarUrl } } }
          closingIssuesReferences(first: 10) { nodes { \(RawLinked.fields) } }
        }
        """

    var model: PullRequest {
        PullRequest(
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
            reviewers: (latestReviews?.nodes ?? []).compactMap { $0.author?.person },
            linkedIssues: (closingIssuesReferences?.nodes ?? []).map(\.model)
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
