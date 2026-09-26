import Foundation

extension GitHubAPI {
    /// The search for PRs in the org last updated in `[from, to)`, or since
    /// `from` when `to` is nil, in any state.
    static func workLogSearch(org: String, from: Date, to: Date? = nil) -> String {
        // Search takes a full timestamp; `+00:00` rather than `Z` is the form
        // GitHub documents.
        func stamp(_ date: Date) -> String { date.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00") }
        let range = to.map { "\(stamp(from))..\(stamp($0))" } ?? ">=\(stamp(from))"
        return "org:\(org) archived:false is:pr updated:\(range)"
    }

    /// PRs matching a `workLogSearch`, with their commits and reviews.
    /// GitHub caps a search at 1000 results, so callers search a week at a time.
    func workLogPullRequests(query: String, onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }) async throws -> [WorkLogPullRequest] {
        let nodes: [Lossy<RawWorkLogPullRequest>] = try await search(
            query,
            fields: RawWorkLogPullRequest.fields,
            // A hundred commits per PR makes for heavy pages.
            pageSize: 20,
            onPage: onPage
        )
        return nodes.compactMap { $0.value?.model }
    }
}

private struct RawWorkLogPullRequest: Decodable {
    struct Actor: Decodable { let login: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Author: Decodable { let user: Actor? }
            let authoredDate: Date
            let additions: Int
            let deletions: Int
            let author: Author?
        }
        let commit: Commit
    }
    struct Review: Decodable {
        let submittedAt: Date?
        let state: String
        let author: Actor?
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let mergedAt: Date?
    let repository: Repository
    let author: Actor?
    let mergedBy: Actor?
    let commits: Connection<CommitNode>
    let reviews: Connection<Review>?

    static let fields = """
        ... on PullRequest {
          id number title url createdAt mergedAt
          repository { nameWithOwner }
          author { login }
          mergedBy { login }
          commits(last: 100) { nodes { commit { authoredDate additions deletions author { user { login } } } } }
          reviews(last: 50) { nodes { submittedAt state author { login } } }
        }
        """

    var model: WorkLogPullRequest {
        WorkLogPullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author?.login,
            createdAt: createdAt,
            mergedAt: mergedAt,
            mergedBy: mergedBy?.login,
            commits: commits.nodes.map {
                WorkLogCommit(authoredAt: $0.commit.authoredDate, author: $0.commit.author?.user?.login, additions: $0.commit.additions, deletions: $0.commit.deletions)
            },
            reviews: (reviews?.nodes ?? []).compactMap { review in
                guard let at = review.submittedAt, let login = review.author?.login, review.state != "PENDING" else { return nil }
                return WorkLogReview(submittedAt: at, author: login, state: review.state)
            }
        )
    }
}
