import Foundation

// MARK: - What a finding is about

/// What a finding is about, as the reviewer files it (the review JSON's
/// `category`), in the spirit of CodeRabbit's: for the finding's chip, the
/// review's filter and Agents › Metrics.
enum ReviewCategory: String, CaseIterable, Identifiable, Sendable {
    case correctness, data, stability, security, performance, maintainability

    var id: Self { self }

    var title: String {
        switch self {
        case .correctness: "Functional correctness"
        case .data: "Data integrity and integration"
        case .stability: "Stability and availability"
        case .security: "Security and privacy"
        case .performance: "Performance and scalability"
        case .maintainability: "Maintainability and code quality"
        }
    }

    var shortTitle: String {
        switch self {
        case .correctness: "Correctness"
        case .data: "Data"
        case .stability: "Stability"
        case .security: "Security"
        case .performance: "Performance"
        case .maintainability: "Maintainability"
        }
    }

    var systemImage: String {
        switch self {
        case .correctness: "checkmark.diamond"
        case .data: "cylinder.split.1x2"
        case .stability: "waveform.path.ecg"
        case .security: "lock.shield"
        case .performance: "gauge.with.dots.needle.67percent"
        case .maintainability: "wrench.and.screwdriver"
        }
    }

    /// Read leniently: any spelling that starts with or names one.
    init?(_ raw: String?) {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let exact = ReviewCategory(rawValue: raw) { self = exact; return }
        guard let found = ReviewCategory.allCases.first(where: { raw.hasPrefix($0.rawValue) || raw.contains($0.shortTitle.lowercased()) }) else { return nil }
        self = found
    }

    /// The review prompt's list of them.
    static var promptList: String {
        allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " | ")
    }
}

/// The severities a reviewer gives, most serious first.
enum ReviewSeverity: String, CaseIterable, Identifiable, Sendable {
    case blocker, major, minor, nit

    var id: Self { self }
    var title: String { rawValue.capitalized }

    init?(_ raw: String?) {
        guard let raw, let found = ReviewSeverity(rawValue: raw.lowercased()) else { return nil }
        self = found
    }
}

// MARK: - The record kept in the harness

/// One person's Claude review of one PR, kept in the harness as
/// `.gannin/reviews/<owner>/<name>/<number>-<reviewer>.json` so the team
/// can see who reviews with Gannin and how its findings land (Agents ›
/// Metrics). Written when a review is posted (by hand or automatically),
/// finished, or its PR is merged or closed while watched, each time one
/// commit; findings are kept across rounds by their key.
struct ReviewRecord: Codable, Hashable, Identifiable {
    struct Finding: Codable, Hashable {
        let key: String
        let path: String
        var line: Int?
        var severity: String?
        var category: String?
        /// `kept`, `edited` or `dismissed`: what the person made of it.
        var decision: String
        /// The start of what was posted, to find its thread on GitHub.
        var excerpt: String
        var postedAt: Date?
        /// When its thread was found resolved (fixed, or answered), or nil.
        var resolvedAt: Date?
    }

    let repo: String
    let number: Int
    var title: String
    /// The PR's author.
    var author: String?
    /// Who ran the review: the signed-in GitHub account.
    let reviewer: String
    var startedAt: Date
    var updatedAt: Date
    /// The reviewer's verdict: `approve`, `comment` or `request_changes`.
    var verdict: String?
    /// How much work reviewing it by hand is, 1 to 5, as the reviewer judged.
    var effort: Int?
    /// What was posted (`APPROVE`, `COMMENT`, `REQUEST_CHANGES`) and when.
    var event: String?
    var postedAt: Date?
    /// Posted by Gannin by itself (Post automatic reviews).
    var postedAutomatically: Bool?
    /// `OPEN`, `MERGED` or `CLOSED` when last looked at.
    var state: String?
    var mergedAt: Date?
    var findings: [Finding]

    var id: String { "\(repo)#\(number)@\(reviewer.lowercased())" }

    var posted: [Finding] { findings.filter { $0.postedAt != nil } }
    var dismissed: [Finding] { findings.filter { $0.decision == "dismissed" } }
    var accepted: [Finding] { findings.filter { $0.postedAt != nil && $0.resolvedAt != nil } }

    static func path(repo: String, number: Int, reviewer: String) -> String {
        ".gannin/reviews/\(repo)/\(number)-\(reviewer.lowercased()).json"
    }

    static func isRecord(_ path: String) -> Bool {
        path.hasPrefix(".gannin/reviews/") && path.hasSuffix(".json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func read(_ text: String) -> ReviewRecord? {
        try? decoder.decode(ReviewRecord.self, from: Data(text.utf8))
    }

    var json: String {
        (try? Self.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
    }

    /// The record brought up to date with the session: the latest result's
    /// findings added or updated (`posting` marks those not dismissed as
    /// posted now), and with `outcome`, the PR's state and which posted
    /// findings' threads are resolved.
    static func updated(_ existing: ReviewRecord?, session: CodeSession, review: SessionTranscript.ReviewResult?, draft: ReviewDraft, reviewer: String, posting: Bool, automatically: Bool, outcome: ReviewOutcome?) -> ReviewRecord? {
        guard let pr = session.reviewOf else { return nil }
        var record = existing ?? ReviewRecord(
            repo: pr.repo, number: pr.number, title: pr.title, author: nil, reviewer: reviewer,
            startedAt: session.createdAt, updatedAt: .now, findings: []
        )
        record.updatedAt = .now
        if let review {
            record.verdict = review.verdict ?? record.verdict
            record.effort = review.effort ?? record.effort
            for finding in review.findings {
                let decision = draft.decisions[finding.key]
                let text: String
                let label: String
                switch decision {
                case .dismissed: (text, label) = (finding.comment, "dismissed")
                case .edited(let edited): (text, label) = (edited, "edited")
                case nil: (text, label) = (finding.comment, "kept")
                }
                let excerpt = String(text.prefix(80))
                if let index = record.findings.firstIndex(where: { $0.key == finding.key }) {
                    // Once posted, what was posted stands.
                    guard record.findings[index].postedAt == nil else { continue }
                    record.findings[index].decision = label
                    record.findings[index].excerpt = excerpt
                    record.findings[index].category = finding.category ?? record.findings[index].category
                    if posting, label != "dismissed" { record.findings[index].postedAt = draft.postedAt ?? .now }
                } else {
                    record.findings.append(Finding(
                        key: finding.key, path: finding.path, line: finding.line, severity: finding.severity?.lowercased(),
                        category: ReviewCategory(finding.category)?.rawValue, decision: label, excerpt: excerpt,
                        postedAt: posting && label != "dismissed" ? (draft.postedAt ?? .now) : nil
                    ))
                }
            }
        }
        if posting {
            record.postedAt = draft.postedAt ?? .now
            record.event = draft.postedEvent
            if automatically { record.postedAutomatically = true }
        }
        if let outcome {
            record.title = outcome.title ?? record.title
            record.author = outcome.author ?? record.author
            record.state = outcome.state ?? record.state
            record.mergedAt = outcome.mergedAt ?? record.mergedAt
            for index in record.findings.indices where record.findings[index].postedAt != nil && record.findings[index].resolvedAt == nil {
                let finding = record.findings[index]
                let prefix = finding.excerpt.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)
                let thread = outcome.threads.first { thread in
                    thread.path == finding.path
                        && thread.author?.caseInsensitiveCompare(reviewer) == .orderedSame
                        && (prefix.isEmpty || thread.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix))
                }
                if thread?.isResolved == true { record.findings[index].resolvedAt = .now }
            }
        }
        return record
    }

    /// A review on this Mac that isn't in the harness yet, as the metrics
    /// count it: posted findings known, their threads not looked at.
    static func local(_ session: CodeSession, reviewer: String) -> ReviewRecord? {
        guard session.reviewOf != nil, let review = session.reviewResult else { return nil }
        let draft = session.reviewDraft ?? ReviewDraft()
        return updated(nil, session: session, review: review, draft: draft, reviewer: reviewer, posting: draft.posted != nil, automatically: false, outcome: nil).map { record in
            var record = record
            record.updatedAt = draft.postedAt ?? session.createdAt
            return record
        }
    }
}

/// A PR as a record looks at it: its state, and your review threads.
struct ReviewOutcome {
    struct Thread {
        let isResolved: Bool
        let path: String
        /// Who started it and what they said first.
        let author: String?
        let body: String
    }

    let title: String?
    let author: String?
    let state: String?
    let mergedAt: Date?
    let threads: [Thread]
}

extension GitHubAPI {
    func reviewOutcome(pullRequest id: String) async throws -> ReviewOutcome {
        struct Login: Decodable { let login: String }
        struct Comment: Decodable { let author: Login?; let body: String }
        struct Thread: Decodable { let isResolved: Bool; let path: String; let comments: Connection<Comment> }
        struct PullRequest: Decodable {
            let title: String?
            let author: Login?
            let state: String?
            let mergedAt: Date?
            let reviewThreads: Connection<Thread>?
        }
        struct Response: Decodable { let node: PullRequest? }
        let response: Response = try await query("""
            query($id: ID!) {
              node(id: $id) {
                ... on PullRequest {
                  title author { login } state mergedAt
                  reviewThreads(first: 100) { nodes { isResolved path comments(first: 1) { nodes { author { login } body } } } }
                }
              }
            }
            """, values: ["id": id])
        let pr = response.node
        return ReviewOutcome(
            title: pr?.title, author: pr?.author?.login, state: pr?.state, mergedAt: pr?.mergedAt,
            threads: (pr?.reviewThreads?.nodes ?? []).map { thread in
                let first = thread.comments.nodes.first
                return .init(isResolved: thread.isResolved, path: thread.path, author: first?.author?.login, body: first?.body ?? "")
            }
        )
    }
}

// MARK: - Recording

extension SessionStore {
    /// Settings: whether reviews are recorded in the harness (on by
    /// default), also the Post Review sheet's checkbox.
    static let recordReviewsKey = "recordReviewsInHarness"

    static var recordsReviews: Bool {
        UserDefaults.standard.object(forKey: recordReviewsKey) as? Bool ?? true
    }

    /// Commits the review's record to its harness: `posting` when it's just
    /// been posted, else (finished, merged or closed) to note how it
    /// landed. Nothing's written when nothing changed. Errors are dropped:
    /// the record is a by-product, never in the way of the review.
    func recordReview(_ id: UUID, posting: Bool = false, automatically: Bool = false) async {
        guard Self.recordsReviews, let session = sessions[id], let pr = session.reviewOf, let repo = session.harnessRepo,
              let api = api(), let reviewer = viewerLogin() else { return }
        let review = transcripts[id]?.review ?? session.reviewResult
        guard review != nil || reviewDrafts[id]?.posted != nil else { return }
        let draft = reviewDrafts[id] ?? session.reviewDraft ?? ReviewDraft()
        let outcome = try? await chargingTo(.details) { try await api.reviewOutcome(pullRequest: pr.id) }
        let setup = HarnessConfig(repo: repo)
        let path = ReviewRecord.path(repo: pr.repo, number: pr.number, reviewer: reviewer)
        _ = try? await harnessStore.commit(org: session.org, setup: setup) { head in
            let text = try await self.harnessStore.files(setup: setup, at: head, paths: [path])[path] ?? nil
            let existing = text.flatMap(ReviewRecord.read)
            guard let record = ReviewRecord.updated(existing, session: session, review: review, draft: draft, reviewer: reviewer, posting: posting, automatically: automatically, outcome: outcome) else { return nil }
            // `updatedAt` alone isn't worth a commit.
            var unchanged = record
            unchanged.updatedAt = existing?.updatedAt ?? record.updatedAt
            if let existing, unchanged == existing { return nil }
            let what = posting ? "posted" : record.state == "MERGED" ? "merged" : record.state == "CLOSED" ? "closed" : "updated"
            return HarnessChange(message: "Gannin: review of \(pr.repo)#\(pr.number) by \(reviewer), \(what)", files: [path: record.json])
        }
    }
}
