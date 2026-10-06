import Foundation

/// What the org's repo pages bring back: milestones, each repo's newest
/// releases, its stars, and where to carry on for repos with more releases.
struct ReleaseFetch {
    var milestones: [RepoMilestone]
    var releases: [RepoRelease]
    var repositories: [ReleaseRepository]
    /// The cursor after each repo's first page of releases, for those with more.
    var moreReleases: [String: String]
}

extension GitHubAPI {
    /// Every non-archived repo's open milestones, those closed most lately
    /// and its newest releases, repos most recently pushed first, stopping at
    /// those not pushed to since `since`. Repos with more releases than the
    /// first page are listed in `moreReleases` for `releases(repo:after:)`.
    func milestonesAndReleases(
        org: String,
        pushedSince since: Date,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> ReleaseFetch {
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
                        nameWithOwner pushedAt stargazerCount
                        openMilestones: milestones(first: 25, states: [OPEN], orderBy: { field: DUE_DATE, direction: ASC }) { \(milestoneFields) }
                        closedMilestones: milestones(first: 10, states: [CLOSED], orderBy: { field: UPDATED_AT, direction: DESC }) { \(milestoneFields) }
                        releases(first: 25, orderBy: { field: CREATED_AT, direction: DESC }) { \(Self.releaseFields) }
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
        var moreReleases: [String: String] = [:]
        for repo in repos {
            if let page = repo.releases.pageInfo, page.hasNextPage, let cursor = page.endCursor {
                moreReleases[repo.nameWithOwner] = cursor
            }
        }
        return ReleaseFetch(
            milestones: repos.flatMap(\.milestones),
            releases: repos.flatMap { repo in repo.releases.models(repo: repo.nameWithOwner) },
            repositories: repos.filter { $0.releases.totalCount > 0 }.map {
                ReleaseRepository(name: $0.nameWithOwner, stars: $0.stargazerCount, releaseCount: $0.releases.totalCount)
            },
            moreReleases: moreReleases
        )
    }

    /// A repo's releases after `cursor`, newest first, to the end.
    func releases(repo: String, after cursor: String) async throws -> [RepoRelease] {
        struct Response: Decodable {
            struct Repository: Decodable { let releases: RawReleases }
            let repository: Repository?
        }
        let (owner, name) = Self.split(repo)
        var after = cursor
        var releases: [RepoRelease] = []
        while true {
            let response: Response = try await query("""
                query($owner: String!, $name: String!, $cursor: String) {
                  repository(owner: $owner, name: $name) {
                    releases(first: 50, after: $cursor, orderBy: { field: CREATED_AT, direction: DESC }) { \(Self.releaseFields) }
                  }
                }
                """, variables: ["owner": owner, "name": name, "cursor": after])
            guard let page = response.repository?.releases else { break }
            releases += page.models(repo: repo)
            guard let info = page.pageInfo, info.hasNextPage, let next = info.endCursor else { break }
            after = next
        }
        return releases
    }

    /// When a repo's stargazers starred it, newest first, stopping at the
    /// first at or before `since` (nil for all of them) or after `limit`.
    /// `reachedEnd` is false when the limit cut it short.
    func starDates(repo: String, since: Date?, limit: Int) async throws -> (dates: [Date], reachedEnd: Bool) {
        struct Response: Decodable {
            struct Edge: Decodable { let starredAt: Date }
            struct Stargazers: Decodable {
                let pageInfo: PageInfo
                let edges: [Edge]
            }
            struct Repository: Decodable { let stargazers: Stargazers }
            let repository: Repository?
        }
        let (owner, name) = Self.split(repo)
        var dates: [Date] = []
        var cursor: String?
        while dates.count < limit {
            var variables = ["owner": owner, "name": name]
            if let cursor { variables["cursor"] = cursor }
            let response: Response = try await query("""
                query($owner: String!, $name: String!, $cursor: String) {
                  repository(owner: $owner, name: $name) {
                    stargazers(first: 100, after: $cursor, orderBy: { field: STARRED_AT, direction: DESC }) {
                      pageInfo { hasNextPage endCursor }
                      edges { starredAt }
                    }
                  }
                }
                """, variables: variables)
            guard let page = response.repository?.stargazers else { return (dates, true) }
            for edge in page.edges {
                if let since, edge.starredAt <= since { return (dates, true) }
                dates.append(edge.starredAt)
            }
            guard page.pageInfo.hasNextPage, let next = page.pageInfo.endCursor else { return (dates, true) }
            cursor = next
        }
        return (dates, false)
    }

    private static func split(_ repo: String) -> (owner: String, name: String) {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? repo, parts.count > 1 ? parts[1] : repo)
    }

    private static let releaseFields = """
        pageInfo { hasNextPage endCursor }
        totalCount
        nodes {
          id name tagName url createdAt publishedAt isDraft isPrerelease isLatest author { login } description
          releaseAssets(first: 50) { nodes { name downloadCount size } }
        }
        """
}

/// A page of a repo's releases, as `releaseFields` asks for it.
private struct RawReleases: Decodable {
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
        let releaseAssets: Connection<Lossy<ReleaseAsset>>?
    }

    let pageInfo: PageInfo?
    let totalCount: Int
    let nodes: [Lossy<Release>]

    func models(repo: String) -> [RepoRelease] {
        nodes.compactMap(\.value).map { release in
            RepoRelease(
                id: release.id, repo: repo, name: release.name, tagName: release.tagName, url: release.url,
                createdAt: release.createdAt, publishedAt: release.publishedAt, isDraft: release.isDraft,
                isPrerelease: release.isPrerelease, isLatest: release.isLatest, author: release.author?.login,
                notes: release.description, assets: (release.releaseAssets?.nodes ?? []).compactMap(\.value)
            )
        }
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

    let nameWithOwner: String
    let pushedAt: Date?
    let stargazerCount: Int
    let openMilestones: Connection<Lossy<Milestone>>?
    let closedMilestones: Connection<Lossy<Milestone>>?
    let releases: RawReleases

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
}
