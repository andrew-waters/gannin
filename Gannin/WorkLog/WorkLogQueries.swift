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
            let authoredDate: String
            let additions: Int
            let deletions: Int
            let author: Author?
            let messageHeadline: String?
            let url: URL?
        }
        let commit: Commit
    }
    struct ClosingIssue: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let state: String
        let repository: Repository
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
    let closedAt: Date?
    let repository: Repository
    let author: Actor?
    let mergedBy: Actor?
    let commits: Connection<CommitNode>
    let reviews: Connection<Review>?
    let isDraft: Bool?
    let closingIssuesReferences: Connection<ClosingIssue>?

    static let fields = """
        ... on PullRequest {
          id number title url createdAt mergedAt closedAt isDraft
          repository { nameWithOwner }
          closingIssuesReferences(first: 5) { nodes { id number title url state repository { nameWithOwner } } }
          author { login }
          mergedBy { login }
          commits(last: 100) { nodes { commit { authoredDate additions deletions messageHeadline url author { user { login } } } } }
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
            closedAt: closedAt,
            mergedBy: mergedBy?.login,
            commits: commits.nodes.compactMap { node in
                guard let stamp = GitTimestamp(node.commit.authoredDate) else { return nil }
                return WorkLogCommit(authoredAt: stamp.date, author: node.commit.author?.user?.login, additions: node.commit.additions, deletions: node.commit.deletions, utcOffset: stamp.utcOffset, message: node.commit.messageHeadline, url: node.commit.url)
            },
            reviews: (reviews?.nodes ?? []).compactMap { review in
                guard let at = review.submittedAt, let login = review.author?.login, review.state != "PENDING" else { return nil }
                return WorkLogReview(submittedAt: at, author: login, state: review.state)
            },
            isDraft: isDraft,
            closingIssues: (closingIssuesReferences?.nodes ?? []).map {
                LinkedItem(id: $0.id, number: $0.number, title: $0.title, url: $0.url, repo: $0.repository.nameWithOwner, state: $0.state)
            }
        )
    }
}

/// A git timestamp, which GitHub returns as written (not converted to UTC),
/// so its offset says what the author's clock read.
struct GitTimestamp {
    let date: Date
    let utcOffset: Int

    private static let parser = ISO8601DateFormatter()

    init?(_ text: String) {
        guard let date = Self.parser.date(from: text) else { return nil }
        self.date = date
        // The offset is the trailing `Z` or `+hh:mm` / `-hh:mm`.
        if text.hasSuffix("Z") {
            utcOffset = 0
        } else if text.count > 6 {
            let suffix = text.suffix(6)
            let sign: Int = suffix.first == "-" ? -1 : 1
            let parts = suffix.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, suffix.first == "+" || suffix.first == "-" else { return nil }
            utcOffset = sign * (parts[0] * 3600 + parts[1] * 60)
        } else {
            return nil
        }
    }
}
