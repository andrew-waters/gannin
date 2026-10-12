import Foundation

extension GitHubAPI {
    /// Merged PRs in `[from, to]`, or from `since` when given. Keep the range
    /// to a week (see `weeklyChunks`) so the search stays under GitHub's 1000
    /// result cap.
    func metricPullRequests(
        org: String,
        from: Date,
        to: Date,
        since: Date? = nil,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in }
    ) async throws -> [MetricPullRequest] {
        let query = Self.mergedSearch(org: org, from: from, to: to, since: since)
        let nodes: [Lossy<RawMetricPullRequest>] = try await search(
            query,
            fields: RawMetricPullRequest.fields,
            pageSize: 25,
            onPage: onPage
        )
        return nodes.compactMap { $0.value?.model }
    }

    /// Files changed on PRs by node ID, for those stored before it was
    /// fetched, handed over a batch at a time. `changedFiles` is slow for
    /// GitHub to work out, so a batch is 25 and halved when GitHub times
    /// out; a PR that times out alone is skipped.
    func changedFiles(ids: [String], onBatch: (_ files: [String: Int], _ done: Int) -> Void) async throws {
        struct Node: Decodable { let id: String; let changedFiles: Int }
        struct Response: Decodable { let nodes: [Lossy<Node>] }
        var size = 25
        var done = 0
        while done < ids.count {
            let batch = Array(ids[done..<min(done + size, ids.count)])
            do {
                let response: Response = try await query("""
                    query($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id changedFiles } } }
                    """, values: ["ids": batch])
                done += batch.count
                onBatch(Dictionary(response.nodes.compactMap(\.value).map { ($0.id, $0.changedFiles) }, uniquingKeysWith: { first, _ in first }), done)
                size = min(size * 2, 25)
            } catch APIError.http(let status, _) where (502...504).contains(status) {
                if batch.count == 1 {
                    done += 1
                    onBatch([:], done)
                } else {
                    size = max(batch.count / 2, 1)
                }
            }
        }
    }

    /// The search for PRs merged in `[from, to]`, by day, or from the exact
    /// time `since` (to the second) when it's given, so a top-up doesn't fetch
    /// the rest of the day it starts in again.
    static func mergedSearch(org: String, from: Date, to: Date, since: Date? = nil) -> String {
        let scope = "\(GitHubAccounts.scope(org)) archived:false is:pr is:merged"
        guard let since else { return "\(scope) merged:\(day(from))..\(day(to))" }
        let start = since.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00")
        return "\(scope) merged:\(start)..\(day(to))T23:59:59+00:00"
    }

    /// Number of PRs opened in each week starting at the given dates.
    func openedCounts(
        org: String,
        weeks: [Date],
        onWeek: (_ done: Int) -> Void = { _ in }
    ) async throws -> [Date: Int] {
        var counts: [Date: Int] = [:]
        // One request per batch of weeks, keeping a long history's query small.
        for batch in stride(from: 0, to: weeks.count, by: Self.openedBatchSize).map({ Array(weeks[$0..<min($0 + Self.openedBatchSize, weeks.count)]) }) {
            var searches: [String: String] = [:]
            for week in batch {
                let end = Calendar.metrics.date(byAdding: .day, value: 6, to: week) ?? week
                searches[Self.day(week)] = "\(GitHubAccounts.scope(org)) archived:false is:pr created:\(Self.day(week))..\(Self.day(end))"
            }
            let batchCounts = try await self.counts(searches: searches)
            for week in batch {
                if let count = batchCounts[Self.day(week)] { counts[week] = count }
            }
            onWeek(counts.count)
        }
        return counts
    }

    /// Weeks counted in one `openedCounts` request.
    private static let openedBatchSize = 50

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
    let updatedAt: Date?
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
          id number title url createdAt mergedAt updatedAt additions deletions changedFiles
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
            changedFiles: changedFiles,
            updatedAt: updatedAt
        )
    }
}
