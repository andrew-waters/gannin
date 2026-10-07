import Foundation

extension GitHubAPI {
    /// Merged PRs in `[from, to]`. Keep the range to a week (see
    /// `weeklyChunks`) so the search stays under GitHub's 1000 result cap.
    func metricPullRequests(
        org: String,
        from: Date,
        to: Date,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> [MetricPullRequest] {
        let query = Self.mergedSearch(org: org, from: from, to: to)
        let nodes: [Lossy<RawMetricPullRequest>] = try await search(
            query,
            fields: RawMetricPullRequest.fields,
            pageSize: 25,
            onPage: onPage
        )
        return nodes.compactMap { $0.value?.model }
    }

    /// Files changed on PRs by node ID, for those stored before it was
    /// fetched: 100 a query, a point each.
    func changedFiles(ids: [String], onBatch: (_ done: Int) -> Void = { _ in }) async throws -> [String: Int] {
        struct Node: Decodable { let id: String; let changedFiles: Int }
        struct Response: Decodable { let nodes: [Lossy<Node>] }
        var files: [String: Int] = [:]
        var done = 0
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let response: Response = try await query("""
                query($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id changedFiles } } }
                """, values: ["ids": batch])
            for node in response.nodes.compactMap(\.value) { files[node.id] = node.changedFiles }
            done += batch.count
            onBatch(done)
        }
        return files
    }

    /// The search for PRs merged in `[from, to]`, by day.
    static func mergedSearch(org: String, from: Date, to: Date) -> String {
        "\(GitHubAccounts.scope(org)) archived:false is:pr is:merged merged:\(day(from))..\(day(to))"
    }

    /// Number of PRs opened in each week starting at the given dates.
    func openedCounts(
        org: String,
        weeks: [Date],
        onWeek: (_ done: Int) -> Void = { _ in }
    ) async throws -> [Date: Int] {
        struct Response: Decodable {
            struct Search: Decodable { let issueCount: Int }
            let search: Search
        }
        var counts: [Date: Int] = [:]
        for week in weeks {
            let end = Calendar.metrics.date(byAdding: .day, value: 6, to: week) ?? week
            let response: Response = try await query("""
                query($q: String!) { search(query: $q, type: ISSUE, first: 1) { issueCount } }
                """, variables: ["q": "\(GitHubAccounts.scope(org)) archived:false is:pr created:\(Self.day(week))..\(Self.day(end))"])
            counts[week] = response.search.issueCount
            onWeek(counts.count)
        }
        return counts
    }

    /// Week-long `[start, end]` ranges covering `[from, to]`.
    static func weeklyChunks(from: Date, to: Date) -> [(Date, Date)] {
        let calendar = Calendar.metrics
        var chunks: [(Date, Date)] = []
        var start = calendar.startOfDay(for: from)
        while start <= to {
            let end = min(calendar.date(byAdding: .day, value: 6, to: start) ?? to, to)
            chunks.append((start, end))
            guard let next = calendar.date(byAdding: .day, value: 7, to: start) else { break }
            start = next
        }
        return chunks
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}

extension Calendar {
    /// Weeks start on Monday for every metric bucket.
    static let metrics: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    func startOfWeek(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }
}

// MARK: - Raw shape

private struct RawMetricPullRequest: Decodable {
    struct Author: Decodable {
        let __typename: String
        let login: String
        let avatarUrl: URL?
    }
    struct Review: Decodable {
        let author: Author?
        let state: String
        let submittedAt: Date?
    }
    struct CommitNode: Decodable {
        struct Commit: Decodable { let authoredDate: Date }
        let commit: Commit
    }
    /// Ready-for-review, review-requested and request-removed events.
    struct TimelineEvent: Decodable {
        struct Reviewer: Decodable { let login: String? }
        let __typename: String
        let createdAt: Date?
        let requestedReviewer: Reviewer?
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let mergedAt: Date
    let additions: Int
    let deletions: Int
    let changedFiles: Int?
    let repository: Repository
    let author: Author?
    let commits: Connection<CommitNode>
    let timelineItems: Connection<Lossy<TimelineEvent>>
    let reviews: Connection<Review>?
    struct Repository: Decodable { let nameWithOwner: String }

    static let fields = """
        ... on PullRequest {
          id number title url createdAt mergedAt additions deletions changedFiles
          repository { nameWithOwner }
          author { __typename login avatarUrl }
          commits(first: 1) { nodes { commit { authoredDate } } }
          timelineItems(itemTypes: [READY_FOR_REVIEW_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT], first: 50) {
            nodes {
              __typename
              ... on ReadyForReviewEvent { createdAt }
              ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } }
              ... on ReviewRequestRemovedEvent { createdAt requestedReviewer { ... on User { login } } }
            }
          }
          reviews(first: 50) { nodes { state submittedAt author { __typename login avatarUrl } } }
        }
        """

    var model: MetricPullRequest {
        let authorLogin = author?.login
        let humanReviews = (reviews?.nodes ?? [])
            .filter { $0.author.map { $0.__typename != "Bot" && $0.login != authorLogin } ?? false }
            .filter { $0.state != "PENDING" && $0.submittedAt != nil }
            .sorted { $0.submittedAt! < $1.submittedAt! }

        let events = timelineItems.nodes.compactMap(\.value).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        let readyAt = events.last { $0.__typename == "ReadyForReviewEvent" }?.createdAt
        // Each request is its own entry (re-requests after a review count
        // again); a removal closes the most recent open request for that user.
        var requests: [MetricReviewRequest] = []
        for event in events {
            guard let login = event.requestedReviewer?.login, let at = event.createdAt else { continue }
            switch event.__typename {
            case "ReviewRequestedEvent":
                requests.append(MetricReviewRequest(login: login, requestedAt: at, removedAt: nil))
            case "ReviewRequestRemovedEvent":
                if let index = requests.lastIndex(where: { $0.login == login && $0.removedAt == nil }) {
                    requests[index].removedAt = at
                }
            default:
                break
            }
        }

        return MetricPullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author.map { Person(login: $0.login, name: nil, avatarUrl: $0.avatarUrl) },
            authorIsBot: author?.__typename == "Bot",
            createdAt: createdAt,
            mergedAt: mergedAt,
            firstCommitAt: commits.nodes.first?.commit.authoredDate,
            readyAt: readyAt,
            reviews: humanReviews.compactMap { review in
                guard let login = review.author?.login, let submittedAt = review.submittedAt else { return nil }
                return MetricReview(login: login, state: review.state, submittedAt: submittedAt)
            },
            reviewRequests: requests,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles
        )
    }
}
