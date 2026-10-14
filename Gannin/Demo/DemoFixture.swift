import Foundation

/// The demo build's invented world: one org, its people, repos and work,
/// built as the app's own model values so a model change breaks the build
/// rather than the screenshots. Every name here is made up and listed in
/// `logins`, `org` and `repos`, which `DemoFixtureTests` holds the rest to.
/// Dates are relative to launch, so the screens always look current.
enum DemoFixture {
    // MARK: Names

    static let org = "lumen-harbor"
    static let orgName = "Lumen Harbor"

    static let people: [(login: String, name: String)] = [
        ("sam-okafor", "Sam Okafor"),
        ("priya-raman", "Priya Raman"),
        ("theo-lindqvist", "Theo Lindqvist"),
        ("mara-chen", "Mara Chen"),
        ("jonah-adeyemi", "Jonah Adeyemi"),
        ("ines-ferreira", "Inês Ferreira"),
    ]

    static var logins: Set<String> { Set(people.map(\.login)) }

    static let repos = ["\(org)/tide-api", "\(org)/beacon-web", "\(org)/chart-room", "\(org)/dockyard"]

    // MARK: Who's who

    static let viewer = Viewer(login: people[0].login, name: people[0].name, avatarUrl: avatar(people[0].login))

    static let organisation = Organisation(id: "demo-org", login: org, name: orgName, avatarUrl: DemoAvatars.url(org, name: orgName),
                                           description: "Harbour logistics, charted.")

    static let personal = Organisation(id: "user:\(viewer.login)", login: viewer.login, name: viewer.name, avatarUrl: viewer.avatarUrl,
                                       description: "Your personal account", isUser: true)

    static func person(_ login: String) -> Person {
        Person(login: login, name: people.first { $0.login == login }?.name, avatarUrl: avatar(login))
    }

    private static func avatar(_ login: String) -> URL {
        DemoAvatars.url(login, name: people.first { $0.login == login }?.name)
    }

    private static var members: [Person] { people.map { person($0.login) } }

    private static var teams: [Team] {
        [
            Team(id: "demo-team-platform", slug: "platform", name: "Platform", members: ["sam-okafor", "theo-lindqvist", "jonah-adeyemi"]),
            Team(id: "demo-team-product", slug: "product", name: "Product", members: ["priya-raman", "mara-chen", "ines-ferreira"]),
        ]
    }

    // MARK: Time

    /// Launch time, so every date in one run agrees.
    static let now = Date.now

    private static func ago(days: Double = 0, hours: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 24 + hours) * 60 * 60)
    }

    // MARK: Open work

    private static func url(_ repo: String, _ kind: String, _ number: Int) -> URL {
        URL(string: "https://github.com/\(repo)/\(kind)/\(number)")!
    }

    /// An open PR, its review state given by who was asked and what they said.
    private static func open(
        _ number: Int, _ repo: String, _ title: String, by author: String, opened: Double, updated: Double,
        draft: Bool = false, size: (Int, Int, Int), asked: [(String, Double)] = [], reviews: [(String, String, Double)] = [],
        checks: ItemDetail.CheckState? = .success, closes: [Int] = []
    ) -> PullRequest {
        let decision: PullRequest.ReviewState? = reviews.contains { $0.1 == "CHANGES_REQUESTED" } ? .changesRequested
            : reviews.contains { $0.1 == "APPROVED" } ? .approved : (asked.isEmpty ? nil : .reviewRequired)
        return PullRequest(
            id: "demo-pr-\(repo.split(separator: "/").last!)-\(number)", number: number, title: title, url: url(repo, "pull", number),
            repo: repo, author: person(author), isDraft: draft, state: "OPEN", createdAt: ago(days: opened), updatedAt: ago(days: updated),
            mergedAt: nil, reviewDecision: decision, additions: size.0, deletions: size.1, changedFiles: size.2,
            assignees: [person(author)], requestedReviewers: asked.map { person($0.0) },
            reviewRequestedAt: Dictionary(uniqueKeysWithValues: asked.map { ($0.0, ago(days: $0.1)) }),
            reviewers: reviews.map { person($0.0) },
            linkedIssues: closes.map { number in
                let issue = issues.first { $0.number == number }!
                return LinkedItem(id: issue.id, number: number, title: issue.title, url: issue.url, repo: issue.repo, state: "OPEN")
            },
            checks: checks,
            reviewStates: Dictionary(uniqueKeysWithValues: reviews.map { ($0.0, $0.1) }),
            reviewedAt: Dictionary(uniqueKeysWithValues: reviews.map { ($0.0, ago(days: $0.2)) }),
            lastCommitAt: ago(days: updated)
        )
    }

    /// The PR the PR detail shot opens.
    static var featured: PullRequest { openPullRequests[0] }

    static let openPullRequests: [PullRequest] = [
        open(412, repos[0], "Batch berth allocation requests", by: "theo-lindqvist", opened: 3, updated: 0.2,
             size: (486, 112, 14), asked: [("mara-chen", 2.5)], reviews: [("sam-okafor", "APPROVED", 0.5)], closes: [388]),
        open(415, repos[0], "Retry tide feed imports with backoff", by: "jonah-adeyemi", opened: 3.6, updated: 0.4,
             size: (132, 40, 5), asked: [("theo-lindqvist", 3.4)]),
        open(203, repos[1], "Vessel timeline on the berth page", by: "priya-raman", opened: 5, updated: 1,
             size: (742, 208, 21), asked: [("ines-ferreira", 4.5)], reviews: [("mara-chen", "CHANGES_REQUESTED", 2)], checks: .failure),
        open(207, repos[1], "Dark mode for the arrivals board", by: "ines-ferreira", opened: 2, updated: 0.1,
             size: (318, 96, 17), asked: [("priya-raman", 1.8)], reviews: [("priya-raman", "APPROVED", 0.3)]),
        open(209, repos[1], "Keyboard navigation in the schedule grid", by: "mara-chen", opened: 0.6, updated: 0.1,
             draft: true, size: (88, 12, 4), checks: .pending),
        open(58, repos[2], "Weekly throughput chart by terminal", by: "mara-chen", opened: 4, updated: 2,
             size: (264, 31, 9), asked: [("sam-okafor", 3.8)]),
        open(61, repos[2], "Export reports as CSV", by: "sam-okafor", opened: 1, updated: 0.5,
             size: (156, 22, 6), asked: [("mara-chen", 0.9)], reviews: [("jonah-adeyemi", "COMMENTED", 0.4)]),
        open(97, repos[3], "Move crane telemetry to the new queue", by: "theo-lindqvist", opened: 9, updated: 8,
             size: (1210, 640, 38), checks: .failure),
        open(101, repos[3], "Pin base images by digest", by: "jonah-adeyemi", opened: 0.8, updated: 0.2,
             size: (42, 18, 7), asked: [("sam-okafor", 0.7)], reviews: [("sam-okafor", "APPROVED", 0.1)]),
        open(104, repos[3], "Health checks for the customs bridge", by: "sam-okafor", opened: 0.3, updated: 0.1,
             draft: true, size: (61, 4, 3), checks: .pending),
    ]

    // MARK: Issues

    private static func issue(_ number: Int, _ repo: String, _ title: String, by author: String, opened: Double,
                              assignees: [String], labels: [(String, String)]) -> Issue {
        Issue(id: "demo-issue-\(repo.split(separator: "/").last!)-\(number)", number: number, title: title, url: url(repo, "issues", number),
              repo: repo, author: person(author), state: "OPEN", createdAt: ago(days: opened), updatedAt: ago(days: opened / 3),
              closedAt: nil, assignees: assignees.map(person), labels: labels.map { IssueLabel(name: $0.0, color: $0.1) },
              linkedPullRequests: [])
    }

    static let issues: [Issue] = [
        issue(388, repos[0], "Berth requests time out at peak hours", by: "priya-raman", opened: 12,
              assignees: ["theo-lindqvist"], labels: [("bug", "d73a4a"), ("tide-api", "0e8a16")]),
        issue(391, repos[0], "Document the allocation rules", by: "sam-okafor", opened: 6, assignees: [], labels: [("docs", "0075ca")]),
        issue(176, repos[1], "Arrivals board flickers on refresh", by: "ines-ferreira", opened: 8,
              assignees: ["ines-ferreira"], labels: [("bug", "d73a4a")]),
        issue(181, repos[1], "Show pilot boarding times", by: "mara-chen", opened: 4, assignees: [], labels: [("feature", "a2eeef")]),
        issue(44, repos[2], "Monthly report for the harbour board", by: "priya-raman", opened: 15,
              assignees: ["mara-chen"], labels: [("feature", "a2eeef")]),
        issue(46, repos[2], "Totals off by one on month boundaries", by: "jonah-adeyemi", opened: 2, assignees: [], labels: [("bug", "d73a4a")]),
        issue(88, repos[3], "Rotate the registry credentials", by: "theo-lindqvist", opened: 10,
              assignees: ["jonah-adeyemi"], labels: [("security", "b60205")]),
    ]

    // MARK: Merged history

    /// SplitMix64, so the history is the same on every launch.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func double(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + Double(next() % 10_000) / 10_000 * (range.upperBound - range.lowerBound)
        }
    }

    private static let mergedTitles = [
        "Cache vessel lookups", "Paginate the arrivals feed", "Fix timezone on berth slots", "Add crane status endpoint",
        "Tidy the schedule grid styles", "Validate manifest uploads", "Speed up the throughput query", "Log tide feed latency",
        "Retry customs bridge calls", "Rename terminal codes", "Upgrade the charting library", "Show delays on the board",
        "Split the allocation service", "Index berth requests by date", "Drop the legacy export", "Add pilot roster API",
    ]

    /// Ten weeks of merged PRs, about six a week across the repos and people.
    static let mergedPullRequests: [MetricPullRequest] = {
        var random = Seeded(state: 334)
        var result: [MetricPullRequest] = []
        var number = 300
        for day in stride(from: 70, through: 1, by: -1) where Calendar.current.isDateInWeekend(ago(days: Double(day))) == false {
            for _ in 0..<random.int(1...2) {
                number += 1
                let author = people[random.int(0...(people.count - 1))].login
                let others = people.map(\.login).filter { $0 != author }
                let reviewer = others[random.int(0...(others.count - 1))]
                let merged = ago(days: Double(day), hours: random.double(0...8))
                let created = merged.addingTimeInterval(-random.double(4...70) * 3600)
                let firstReview = created.addingTimeInterval(random.double(0.5...20) * 3600)
                let reworked = random.int(0...3) == 0
                var reviews = [MetricReview(login: reviewer, state: reworked ? "CHANGES_REQUESTED" : "APPROVED", submittedAt: min(firstReview, merged))]
                if reworked {
                    reviews.append(MetricReview(login: reviewer, state: "APPROVED", submittedAt: firstReview.addingTimeInterval(
                        merged.timeIntervalSince(firstReview) * 0.7)))
                }
                let large = random.int(0...6) == 0
                let repo = repos[random.int(0...(repos.count - 1))]
                result.append(MetricPullRequest(
                    id: "demo-merged-\(number)", number: number, title: mergedTitles[random.int(0...(mergedTitles.count - 1))],
                    url: url(repo, "pull", number), repo: repo, author: person(author), authorIsBot: false,
                    createdAt: created, mergedAt: merged, firstCommitAt: created.addingTimeInterval(-random.double(2...30) * 3600),
                    readyAt: nil, reviews: reviews,
                    reviewRequests: [MetricReviewRequest(login: reviewer, requestedAt: created.addingTimeInterval(600))],
                    additions: large ? random.int(400...900) : random.int(10...260), deletions: random.int(2...120),
                    changedFiles: large ? random.int(14...30) : random.int(1...12), updatedAt: merged
                ))
            }
        }
        return result
    }()

    static var metricsHistory: MetricsHistory {
        let start = Calendar.metrics.startOfWeek(for: ago(days: 70))
        var opened: [Date: Int] = [:]
        var week = start
        var random = Seeded(state: 335)
        while week <= now {
            opened[week] = random.int(5...9)
            week = Calendar.metrics.date(byAdding: .weekOfYear, value: 1, to: week)!
        }
        return MetricsHistory(
            formatVersion: MetricsHistory.currentFormat, orgLogin: org, coveredFrom: start, syncedAt: now,
            pullRequests: Dictionary(uniqueKeysWithValues: mergedPullRequests.map { ($0.id, $0) }),
            openedPerWeek: opened, filledChangedFiles: true, storedCount: mergedPullRequests.count
        )
    }

    static var snapshot: OrgSnapshot {
        OrgSnapshot(orgLogin: org, fetchedAt: now, peopleFetchedAt: now, fullFetchedAt: now, lookbackDays: OrgStore.defaultLookbackDays,
                    members: members, teams: teams, openPullRequests: openPullRequests, mergedPullRequests: [], issues: issues,
                    warnings: [])
    }

    // MARK: Detail

    private static let featuredBody = """
        Berth requests arrive one at a time from each terminal, and at peak hours the allocator spends most of its time \
        on round trips. This batches them: requests that land within 200 ms of each other are allocated together.

        ## What changes

        - `AllocationQueue` collects requests and flushes on size or time
        - The allocator takes a batch and resolves conflicts within it first
        - Metrics for batch size and wait time

        ## Testing

        Replayed last Tuesday's peak from the staging log: p95 allocation time fell from 2.4 s to 380 ms.

        Closes #388
        """

    static var details: [String: ItemDetail] {
        var details: [String: ItemDetail] = [:]
        for pr in openPullRequests {
            details[pr.id] = ItemDetail(
                body: pr.id == featured.id ? featuredBody : "\(pr.title).",
                commentCount: pr.id == featured.id ? 3 : 0,
                recentComments: pr.id == featured.id ? [
                    Comment(url: URL(string: "\(pr.url)#c1")!, author: person("sam-okafor"),
                            body: "Nice. Could the flush window be a setting? Terminal 4 might want it shorter.", createdAt: ago(days: 1)),
                    Comment(url: URL(string: "\(pr.url)#c2")!, author: person("theo-lindqvist"),
                            body: "Done: `ALLOCATION_BATCH_WINDOW`, defaulting to 200 ms.", createdAt: ago(days: 0.6)),
                    Comment(url: URL(string: "\(pr.url)#c3")!, author: person("sam-okafor"),
                            body: "Approved. Let's watch the wait-time metric after it ships.", createdAt: ago(days: 0.5)),
                ] : [],
                headRef: pr.id == featured.id ? "412-batch-berth-requests" : "\(pr.number)-change",
                baseRef: "main", checks: pr.checks, updatedAt: pr.updatedAt
            )
        }
        return details
    }
}
