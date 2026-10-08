import Foundation

/// What an Ask session has on hand: Gannin's view of the org as JSON files,
/// written into its `context/` each time it starts or resumes
/// (`SessionStore.writeAskContext`).
enum OrgContext {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private struct PR: Encodable {
        let repo: String; let number: Int; let title: String; let url: URL
        let author: String?; let draft: Bool; let review: String?; let reviewers: [String]
        let created: Date; let updated: Date; let additions: Int; let deletions: Int
    }

    private struct Person: Encodable {
        let login: String; let name: String?
        let openPRs: [PR]; let reviewsWaiting: [PR]
        let assignedIssues: [String]; let mergedRecently: Int
    }

    private struct IssueRow: Encodable {
        let repo: String; let number: Int; let title: String; let url: URL
        let open: Bool; let closed: Date?; let reason: String?
        let author: String?; let assignees: [String]; let labels: [String]; let type: String?
        let status: String?; let statusSince: Date?; let parent: Int?; let created: Date
        let pullRequests: [String]; let investment: String?
    }

    private struct Document: Encodable {
        let path: String; let kind: String; let title: String; let status: String?
        let summary: String?; let owner: String?; let domains: [String]?; let issues: [String]
        let tasks: Int; let tasksDone: Int
    }

    private struct Delivery: Encodable {
        struct Span: Encodable {
            let from: Date; let to: Date; let merged: Int
            let cycleTimeHours: Double?; let firstReviewHours: Double?
            let stageMedianHours: [String: Double]
            let byRepo: [String: Int]; let byAuthor: [String: Int]
        }
        let window: Span
        let previous: Span?
        let mergedWithoutReview: [String]
        let largestPRs: [String]
    }

    private struct TimeOff: Encodable {
        let login: String; let kind: String; let from: Date; let to: Date; let note: String
    }

    static func files(
        org: String,
        workload: Workload?,
        metrics: OrgMetrics?,
        issues: IssueHistory?,
        config: OrgConfig,
        harness: HarnessIndex?,
        people: [String: PersonDates]
    ) -> [String: Data] {
        var files: [String: Data] = [:]
        func pr(_ pr: PullRequest) -> PR {
            PR(repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author?.login, draft: pr.isDraft,
               review: pr.reviewDecision?.rawValue, reviewers: pr.requestedReviewers.map(\.login),
               created: pr.createdAt, updated: pr.updatedAt, additions: pr.additions, deletions: pr.deletions)
        }
        if let workload {
            let rows = workload.people.map { load in
                Person(login: load.person.login, name: load.person.name,
                       openPRs: load.pullRequests.map(pr), reviewsWaiting: load.reviewRequests.map(pr),
                       assignedIssues: load.issues.map { "\($0.repo)#\($0.number) \($0.title)" }, mergedRecently: load.merged.count)
            }
            files["workload.json"] = try? encoder.encode(rows)
        }
        if let issues {
            let investments = config.investmentConfig
            let byID = issues.issues
            let rows = byID.values.filter { !config.repoExclusion.contains($0.repo) }.map { record in
                IssueRow(
                    repo: record.repo, number: record.number, title: record.title, url: record.url,
                    open: record.isOpen, closed: record.closedAt, reason: record.stateReason,
                    author: record.author, assignees: record.assignees, labels: record.labels, type: record.issueType,
                    status: record.statusChanges.last?.status, statusSince: record.statusChanges.last?.at,
                    parent: record.parentID.flatMap { byID[$0]?.number }, created: record.createdAt,
                    pullRequests: record.linkedPullRequests.map { "\($0.url.absoluteString) \($0.state.lowercased())" },
                    investment: investments.categorise(record, parent: record.parentID.flatMap { byID[$0] })?.category.name
                )
            }
            .sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
            files["issues.json"] = try? encoder.encode(rows)
        }
        if let metrics {
            func span(_ from: Date, _ to: Date, _ summary: DeliverySummary) -> Delivery.Span {
                Delivery.Span(
                    from: from, to: to, merged: summary.merged,
                    cycleTimeHours: summary.cycleTime.median.map { $0 / 3600 },
                    firstReviewHours: summary.timeToFirstReview.median.map { $0 / 3600 },
                    stageMedianHours: Dictionary(uniqueKeysWithValues: summary.stages.compactMap { stage, value in value.overall.median.map { (stage.rawValue, $0 / 3600) } }),
                    byRepo: summary.repos.mapValues(\.count), byAuthor: summary.authors.mapValues(\.count)
                )
            }
            let previous = metrics.window.previous()
            let delivery = Delivery(
                window: span(metrics.interval.start, metrics.interval.end, metrics.current),
                previous: metrics.previous.map { span(previous.start, previous.end, $0) },
                mergedWithoutReview: metrics.mergedWithoutReview.map { "\($0.repo)#\($0.number) \($0.title)" },
                largestPRs: metrics.prSize.large.prefix(10).map { "\($0.repo)#\($0.number) \($0.title), \($0.size) lines" }
            )
            files["delivery.json"] = try? encoder.encode(delivery)
        }
        if let harness {
            let documents = harness.documents.filter(\.followsStandard).map { document in
                Document(path: document.path, kind: document.kind.singular, title: document.title, status: document.statusLabel,
                         summary: document.summary, owner: document.owner, domains: document.domains,
                         issues: document.subjects.map { "\($0.repo ?? harness.issuesRepo ?? "")#\($0.number)" },
                         tasks: document.tasks, tasksDone: document.tasksDone)
            }
            files["harness.json"] = try? encoder.encode(documents)
        }
        let soon = Date.now.addingTimeInterval(-7 * 86_400)
        let off = people.flatMap { login, dates in
            dates.absences.filter { $0.end >= soon }.map { TimeOff(login: login, kind: $0.kind.rawValue, from: $0.start, to: $0.end, note: $0.note) }
        }
        files["time-off.json"] = try? encoder.encode(off.sorted { $0.from < $1.from })
        files["README.md"] = Data("""
            # \(org), as Gannin sees it

            - workload.json: each person's open PRs, the reviews waiting on them, their assigned issues
            - issues.json: the issue history (every open issue, and those closed recently), with board status, parent, linked PRs and investment category
            - delivery.json: merged-PR metrics for the stats window and the period before
            - harness.json: plans, requirements and findings in the team's harness, with the issues they're about
            - time-off.json: booked time off from a week ago on

            Written \(Date.now.formatted(.iso8601)).
            """.utf8)
        return files.compactMapValues { $0 }
    }
}
