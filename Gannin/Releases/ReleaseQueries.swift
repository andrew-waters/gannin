import Foundation

extension GitHubAPI {
    /// Every non-archived repo's open milestones, those closed most lately
    /// and its latest releases, repos most recently pushed first, stopping at
    /// those not pushed to since `since`.
    func milestonesAndReleases(
        org: String,
        pushedSince since: Date,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> (milestones: [RepoMilestone], releases: [RepoRelease]) {
        struct Response: Decodable {
            struct Org: Decodable { let repositories: PagedConnection<Lossy<RawReleaseRepository>> }
            let organization: Org?
        }
        let milestoneFields = """
            nodes {
              id number title description dueOn state closedAt updatedAt url
              openIssues: issues(states: [OPEN]) { totalCount }
              closedIssues: issues(states: [CLOSED]) { totalCount }
              openPullRequests: pullRequests(states: [OPEN]) { totalCount }
              closedPullRequests: pullRequests(states: [CLOSED, MERGED]) { totalCount }
            }
            """
        var reachedOlder = false
        let nodes: [Lossy<RawReleaseRepository>] = try await paginate(limit: 1000, onPage: onPage) { cursor in
            guard !reachedOlder else { return nil }
            var variables = ["login": org]
            if let cursor { variables["cursor"] = cursor }
            // Nested milestones and releases make for heavy repos.
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  \(GitHubAccounts.ownerField(org)) {
                    repositories(first: 25, after: $cursor, isArchived: false, orderBy: { field: PUSHED_AT, direction: DESC }\(GitHubAccounts.repositoryArguments(org))) {
                      pageInfo { hasNextPage endCursor }
                      totalCount
                      nodes {
                        nameWithOwner pushedAt
                        openMilestones: milestones(first: 25, states: [OPEN], orderBy: { field: DUE_DATE, direction: ASC }) { \(milestoneFields) }
                        closedMilestones: milestones(first: 10, states: [CLOSED], orderBy: { field: UPDATED_AT, direction: DESC }) { \(milestoneFields) }
                        releases(first: 10, orderBy: { field: CREATED_AT, direction: DESC }) {
                          nodes { id name tagName url createdAt publishedAt isDraft isPrerelease isLatest author { login } description }
                        }
                      }
                    }
                  }
                }
                """, variables: variables)
            if let last = response.organization?.repositories.nodes.last?.value, (last.pushedAt ?? .distantPast) < since {
                reachedOlder = true
            }
            return response.organization?.repositories
        }
        let repos = nodes.compactMap(\.value).filter { ($0.pushedAt ?? .distantPast) >= since }
        return (repos.flatMap(\.milestones), repos.flatMap(\.releaseModels))
    }
}

private struct RawReleaseRepository: Decodable {
    struct Count: Decodable { let totalCount: Int }
    struct Milestone: Decodable {
        let id: String
        let number: Int
        let title: String
        let description: String?
        let dueOn: Date?
        let state: String
        let closedAt: Date?
        let updatedAt: Date
        let url: URL
        let openIssues: Count
        let closedIssues: Count
        let openPullRequests: Count
        let closedPullRequests: Count
    }
    struct Release: Decodable {
        struct Actor: Decodable { let login: String }
        let id: String
        let name: String?
        let tagName: String
        let url: URL
        let createdAt: Date
        let publishedAt: Date?
        let isDraft: Bool
        let isPrerelease: Bool
        let isLatest: Bool
        let author: Actor?
        let description: String?
    }

    let nameWithOwner: String
    let pushedAt: Date?
    let openMilestones: Connection<Lossy<Milestone>>?
    let closedMilestones: Connection<Lossy<Milestone>>?
    let releases: Connection<Lossy<Release>>?

    var milestones: [RepoMilestone] {
        ((openMilestones?.nodes ?? []) + (closedMilestones?.nodes ?? [])).compactMap(\.value).map { milestone in
            RepoMilestone(
                id: milestone.id, repo: nameWithOwner, number: milestone.number, title: milestone.title,
                description: milestone.description, dueOn: milestone.dueOn, isOpen: milestone.state == "OPEN",
                closedAt: milestone.closedAt, updatedAt: milestone.updatedAt, url: milestone.url,
                openIssues: milestone.openIssues.totalCount, closedIssues: milestone.closedIssues.totalCount,
                openPullRequests: milestone.openPullRequests.totalCount, closedPullRequests: milestone.closedPullRequests.totalCount
            )
        }
    }

    var releaseModels: [RepoRelease] {
        (releases?.nodes ?? []).compactMap(\.value).map { release in
            RepoRelease(
                id: release.id, repo: nameWithOwner, name: release.name, tagName: release.tagName, url: release.url,
                createdAt: release.createdAt, publishedAt: release.publishedAt, isDraft: release.isDraft,
                isPrerelease: release.isPrerelease, isLatest: release.isLatest, author: release.author?.login,
                notes: release.description
            )
        }
    }
}
