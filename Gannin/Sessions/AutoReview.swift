import AppKit
import Observation

// MARK: - Settings

/// Reviews Gannin starts and repeats by itself: a review request found by
/// `EngineerWatch` starts one, and a reviewed PR that changes is reviewed
/// again. Every setting here is the user's own, on this Mac.
enum AutoReview {
    /// Settings > General: start a review when a request is found.
    static let enabledKey = "autoReviewRequests"
    /// Settings > General: whether a finished review watches its PR, until
    /// changed on the review.
    static let watchKey = "watchReviewedPullRequests"
    /// Settings > General: post automatic reviews to GitHub as comments,
    /// never approving or requesting changes. Off, they wait for Post Review.
    static let postKey = "autoPostReviews"
    /// More than this many automatic reviews at once wait for a later check.
    static let maxRunning = 2
    /// How long a watched PR must stay quiet before it's reviewed again, so
    /// a run of pushes or a conversation is one review rather than several.
    static let quietPeriod: TimeInterval = 120

    /// The org's own choice, overriding the default: `on`, `off`, or empty
    /// for the default. Settings > Harness.
    static func orgKey(_ org: String) -> String { "autoReviewRequests.\(org)" }

    /// The project's own choice, by its harness repo, overriding the
    /// default: `on`, `off`, or empty for the default. Settings > Harness.
    static func postOverrideKey(_ repo: String) -> String { "autoPostReviews.\(repo)" }

    static var isOnByDefault: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var watchesByDefault: Bool { UserDefaults.standard.object(forKey: watchKey) as? Bool ?? true }
    static var postsAutomatically: Bool { UserDefaults.standard.bool(forKey: postKey) }

    static func isOn(for org: String) -> Bool {
        switch UserDefaults.standard.string(forKey: orgKey(org)) {
        case "on": true
        case "off": false
        default: isOnByDefault
        }
    }

    /// Whether a finished review posts itself, for the project its session
    /// ran in (its harness repo), falling back to Settings' own choice.
    static func shouldPost(repo: String?) -> Bool {
        guard let repo else { return postsAutomatically }
        switch UserDefaults.standard.string(forKey: postOverrideKey(repo)) {
        case "on": return true
        case "off": return false
        default: return postsAutomatically
        }
    }
}

/// A reviewed PR being watched for new commits and comments, kept with its
/// review session.
struct ReviewWatch: Codable, Hashable {
    var isOn = true
    /// The head commit when last looked at; nil until the first look,
    /// which only notes what's there.
    var headSHA: String?
    /// Comments and reviews already seen, by node ID.
    var seen: Set<String> = []
    /// What's changed since the last review and not yet reviewed: when the
    /// latest change was seen, whether there are new commits, and how many
    /// new comments.
    var changedAt: Date?
    var hasNewCommits = false
    var newComments = 0
    /// Who opened the PR, as of the last look, for the look-again prompt.
    var author: String?
}

// MARK: - What happened while you were away

/// Something on a reviewed or watched PR, for the Inbox's catch-up: a
/// comment or push from someone else, or a review Gannin ran by itself.
struct ReviewEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case started, reviewed, posted, failed, comment, push, stopped
    }

    /// The text of the `.stopped` event for a merged PR; the Inbox reads it to offer Finish Review.
    static let mergedText = "Merged"

    let id: String
    let pullRequest: PullRequestReference
    let session: UUID
    let kind: Kind
    let at: Date
    var author: String?
    var text: String?
    var url: URL?
    /// When you opened its review; nil while it's news.
    var seenAt: Date?
}

/// The catch-up log, newest 500, on disk beside the sessions.
@Observable
final class ReviewActivity {
    private(set) var events: [ReviewEvent] = []

    private static var fileURL: URL {
        AppPaths.own
            .appending(path: "Sessions", directoryHint: .isDirectory)
            .appending(path: "ReviewActivity.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([ReviewEvent].self, from: data) {
            events = saved
        }
    }

    func record(_ event: ReviewEvent) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        save()
    }

    /// Everything on the review's PR is seen once you've opened it.
    func markSeen(session: UUID) {
        guard events.contains(where: { $0.session == session && $0.seenAt == nil }) else { return }
        for index in events.indices where events[index].session == session && events[index].seenAt == nil {
            events[index].seenAt = .now
        }
        save()
    }

    /// What you haven't seen in the org, by review, newest change first.
    func unseen(org: String) -> [(session: UUID, events: [ReviewEvent])] {
        let news = events.filter { $0.seenAt == nil && $0.pullRequest.org == org }
        let grouped: [UUID: [ReviewEvent]] = Dictionary(grouping: news) { $0.session }
        var reviews: [(session: UUID, events: [ReviewEvent])] = []
        for (session, events) in grouped {
            reviews.append((session: session, events: events.sorted { $0.at < $1.at }))
        }
        func latest(_ review: (session: UUID, events: [ReviewEvent])) -> Date { review.events.last?.at ?? .distantPast }
        return reviews.sorted { latest($0) > latest($1) }
    }

    /// One line for a PR's news: "2 comments, new commits, reviewed again".
    static func summary(_ events: [ReviewEvent]) -> String {
        var parts: [String] = []
        let comments = events.filter { $0.kind == .comment }.count
        if comments > 0 { parts.append("\(comments) comment\(comments == 1 ? "" : "s")") }
        if events.contains(where: { $0.kind == .push }) { parts.append("new commits") }
        if events.contains(where: { $0.kind == .reviewed }) { parts.append(events.contains { $0.kind == .posted } ? "reviewed and posted" : "reviewed") }
        if events.contains(where: { $0.kind == .failed }) { parts.append("couldn't post") }
        if let stopped = events.last(where: { $0.kind == .stopped }) { parts.append(stopped.text?.lowercased() ?? "stopped watching") }
        if parts.isEmpty, events.contains(where: { $0.kind == .started }) { parts.append("reviewing") }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}

// MARK: - Starting, watching and reviewing again

extension SessionStore {
    /// A review started by Gannin for a request it found, in the background:
    /// no tab is shown. False when the PR already has a review or enough
    /// automatic ones are running; a later check tries again.
    func startAutomaticReview(of pr: PullRequestReference, harness setup: HarnessConfig, harnessPath: String) async -> Bool {
        // Also skip a PR whose review is still being started (`startingReviews`): a review
        // already being started by hand would join that in-flight task and come back as the
        // manual session, which shouldn't count as automatic or be posted on its own.
        // Leaving it be here means a later check finds it through `review(of:)` once that
        // task's added its session.
        guard review(of: pr.id) == nil, startingReviews[pr.id] == nil else { return false }
        guard automaticRuns.filter(isRunning).count < AutoReview.maxRunning else { return false }
        let session = await startReview(of: pr, harness: setup, harnessPath: harnessPath, reveals: false)
        automaticRuns.insert(session.id)
        _ = open(session)
        note(session.id, .started, text: "Started reviewing it when your review was requested")
        return true
    }

    /// Turns watching the review's PR on or off. Turned on again, it starts
    /// afresh from what's there now.
    func setWatching(_ id: UUID, _ isOn: Bool) {
        update(id) { session in
            var watch = session.watch ?? ReviewWatch()
            watch.isOn = isOn
            if isOn, session.watch?.isOn != true { watch = ReviewWatch() }
            session.watch = watch
        }
    }

    /// A review's result arrived: the PR is watched if that's the default
    /// and nobody has said otherwise, and an automatic run is logged and,
    /// if that's wanted, posted.
    func reviewFinished(_ id: UUID) {
        guard let session = sessions[id] else { return }
        if session.watch == nil {
            update(id) { $0.watch = ReviewWatch(isOn: AutoReview.watchesByDefault) }
        }
        // Ready for you whether it started by itself or by hand.
        noticeApproval(id)
        guard automaticRuns.remove(id) != nil else { return }
        let verdict = switch session.reviewResult?.verdict {
        case "approve": "would approve"
        case "request_changes": "would request changes"
        default: "has comments"
        }
        let findings = session.reviewResult?.findings.count ?? 0
        note(id, .reviewed, text: "Claude \(verdict), with \(findings) finding\(findings == 1 ? "" : "s")")
        if AutoReview.shouldPost(repo: session.harnessRepo) { Task { await postAutomatically(id) } }
    }

    /// Posts the review as a comment: never an approval or a request for
    /// changes, which stay yours to give.
    private func postAutomatically(_ id: UUID) async {
        guard let session = sessions[id], let pr = session.reviewOf, let review = session.reviewResult, let api = api() else { return }
        do {
            let draft = reviewDrafts[id] ?? ReviewDraft()
            if Self.holdsForApproval(review, draft: draft) {
                note(id, .reviewed, text: "Nothing posted: Claude would approve it, so it's waiting for you to look and approve")
                await resolveThreads(review.resolved ?? [], of: pr, for: id, api: api)
                await recordReview(id)
                return
            }
            let pull = try await api.reviewedPullRequest(repo: pr.repo, number: pr.number, lenientComments: true)
            let (inline, general, omitted) = pull.comments(for: review, draft: draft)
            let body = ReviewedPullRequest.body(summary: review.summary, general: general)
            // A failed lookup doesn't block posting, as with the comment check.
            if let mine = try? await api.myReviews(repo: pr.repo, number: pr.number),
               let same = PostedReview.repeated(in: mine, event: "COMMENT", commit: pull.headSHA, body: body) {
                reviewDrafts[id, default: ReviewDraft()].posted = same.url ?? pr.url
                reviewDrafts[id, default: ReviewDraft()].postedAt = same.submittedAt
                reviewDrafts[id, default: ReviewDraft()].postedEvent = "COMMENT"
                note(id, .reviewed, text: "Nothing posted: you've already posted this review", url: same.url)
                await resolveThreads(review.resolved ?? [], of: pr, for: id, api: api)
                await recordReview(id)
                return
            }
            let url = try await api.postReview(repo: pr.repo, number: pr.number, commit: pull.headSHA, event: "COMMENT", body: body, comments: inline)
            reviewDrafts[id, default: ReviewDraft()].posted = url ?? pr.url
            reviewDrafts[id, default: ReviewDraft()].postedAt = .now
            reviewDrafts[id, default: ReviewDraft()].postedEvent = "COMMENT"
            var text = "Posted to GitHub as a comment"
            if !omitted.isEmpty {
                text += ", leaving out \(omitted.count) finding\(omitted.count == 1 ? "" : "s") already on the PR"
            }
            if let failure = pull.existingCommentsError {
                text += ". It couldn't check the PR for existing comments (\(failure)), so some may repeat"
            }
            note(id, .posted, text: text, url: url)
        } catch {
            note(id, .failed, text: "GitHub didn't take it: \(error.localizedDescription)")
            return
        }
        await resolveThreads(review.resolved ?? [], of: pr, for: id, api: api)
        await recordReview(id, posting: true, automatically: true)
    }

    /// Looks for a review of yours on GitHub that says what this review does
    /// and notes it as posted, so one posted from another Mac or on GitHub
    /// shows here. Returns whether it learned of a post it didn't have.
    func syncPostedReview(_ id: UUID) async -> Bool {
        guard let session = sessions[id], let pr = session.reviewOf, let review = session.reviewResult, let api = api(),
              let mine = try? await api.myReviews(repo: pr.repo, number: pr.number),
              let found = PostedReview.latest(in: mine, summary: review.summary),
              found.submittedAt > (reviewDrafts[id]?.postedAt ?? session.reviewDraft?.postedAt ?? .distantPast) else { return false }
        reviewDrafts[id, default: ReviewDraft()].posted = found.url ?? pr.url
        reviewDrafts[id, default: ReviewDraft()].postedAt = found.submittedAt
        reviewDrafts[id, default: ReviewDraft()].postedEvent = found.event
        return true
    }

    /// Resolves the threads of yours the review says are dealt with (only
    /// unresolved ones on this PR that you started), noting what was done.
    private func resolveThreads(_ ids: [String], of pr: PullRequestReference, for id: UUID, api: GitHubAPI) async {
        guard !ids.isEmpty else { return }
        let threads: [ReviewThread]
        do {
            threads = try await api.resolvableThreads(ids, pullRequest: pr.id)
        } catch {
            note(id, .failed, text: "Couldn't look up the threads to resolve: \(error.localizedDescription)")
            return
        }
        var resolved = 0
        for thread in threads {
            if (try? await api.resolveReviewThread(thread.id)) != nil { resolved += 1 }
        }
        if resolved > 0 {
            note(id, .posted, text: "Resolved \(resolved) thread\(resolved == 1 ? "" : "s") now dealt with")
        }
        if resolved < threads.count {
            let left = threads.count - resolved
            note(id, .failed, text: "GitHub didn't resolve \(left) thread\(left == 1 ? "" : "s") Claude says \(left == 1 ? "is" : "are") dealt with")
        }
    }

    /// Looks at every watched PR: new commits and others' comments are
    /// noted, and once it's been quiet a while it's reviewed again. A merged
    /// or closed PR stops being watched. `only` limits it to one review, and
    /// `reviewing` false (the tab's Check for Changes) only notes what
    /// changed, leaving the review to be asked for. Returns `only`'s PR
    /// state on GitHub (`OPEN`, `MERGED` or `CLOSED`), nil if it wasn't
    /// watched or couldn't be fetched.
    @discardableResult
    func checkWatchedReviews(only reviewID: UUID? = nil, reviewing: Bool = true) async -> String? {
        let watched = sessions.values.filter { $0.reviewOf != nil && $0.watch?.isOn == true && (reviewID == nil || $0.id == reviewID) }
        guard !watched.isEmpty, let api = api() else { return nil }
        guard let found = try? await api.watchedPullRequests(ids: watched.compactMap(\.reviewOf?.id)) else { return nil }
        var state: String?
        for session in watched {
            guard let id = session.reviewOf?.id, let now = found.pullRequests[id] else { continue }
            await look(at: now, for: session.id, me: found.login, reviewing: reviewing)
            if session.id == reviewID { state = now.state }
        }
        return state
    }

    private func look(at now: WatchedPullRequest, for id: UUID, me: String, reviewing: Bool) async {
        guard var watch = sessions[id]?.watch, watch.isOn else { return }
        defer { update(id) { $0.watch = watch } }
        watch.author = now.author
        // The first look notes what's there.
        guard let head = watch.headSHA else {
            watch.headSHA = now.headSHA
            watch.seen = Set(now.comments.map(\.id))
            return
        }
        guard now.state == "OPEN" else {
            watch.isOn = false
            note(id, .stopped, text: now.state == "MERGED" ? ReviewEvent.mergedText : "Closed")
            // How its findings landed, now it's done.
            Task { await recordReview(id) }
            return
        }
        var changed = false
        if now.headSHA != head {
            watch.headSHA = now.headSHA
            watch.hasNewCommits = true
            changed = true
            note(id, .push, eventID: "push-\(now.headSHA)", text: "New commits")
        }
        for comment in now.comments where !watch.seen.contains(comment.id) {
            watch.seen.insert(comment.id)
            // Yours (and so any review posted for you) and bots' aren't news.
            guard comment.author != me, !comment.isBot else { continue }
            watch.newComments += 1
            changed = true
            note(id, .comment, eventID: "comment-\(comment.id)", author: comment.author, text: String(comment.body.prefix(280)), url: comment.url, at: comment.createdAt)
        }
        if changed {
            watch.changedAt = .now
            return
        }
        guard reviewing, let since = watch.changedAt, Date.now.timeIntervalSince(since) >= AutoReview.quietPeriod,
              ![.working, .starting, .needsYou].contains(state(id)) else { return }
        var reasons: [String] = []
        if watch.hasNewCommits { reasons.append("new commits have been pushed") }
        if watch.newComments > 0 { reasons.append("\(watch.newComments) new comment\(watch.newComments == 1 ? " has" : "s have") been left") }
        if await reviewAgain(id, because: reasons.joined(separator: " and ")) {
            watch.changedAt = nil
            watch.hasNewCommits = false
            watch.newComments = 0
        }
    }

    /// What the author has seen decides the wording: a review that was never
    /// posted isn't one they can be told has "not changed".
    static func lookAgainPrompt(_ pr: PullRequestReference, because reasons: String, wasPosted: Bool, learned: String, author: String? = nil) -> String {
        let whose = author.map { "the PR author (@\($0))" } ?? "the PR author"
        let answerComments = "Answer what \(whose)'s comments ask of you. Answer other people's comments only if they disagree with your review or one of its findings, or you disagree with what they say; leave the rest alone."
        let opening: String
        let earlier: String
        if wasPosted {
            opening = "Since your last review of \(pr.repo)#\(pr.number), \(reasons). Fetch the PR again with its comments and review it as it is now."
            earlier = """
                \(answerComments) Leave out findings from your earlier review that still stand unchanged, and say in the \
                summary which of them are now dealt with, and list their threads in `resolved`.
                """
        } else {
            opening = "Review \(pr.repo)#\(pr.number) as it is now; \(reasons). Fetch the PR again with its comments."
            earlier = """
                Your earlier review was never posted, so the author hasn't seen it. Review the PR as if for the first time: keep the \
                findings that still stand and write a summary that stands alone. \(answerComments) Don't refer to your earlier review or \
                say that nothing has changed.
                """
        }
        return """
            \(opening) \
            \(earlier)\(learned)

            End the same way with the fenced JSON block.
            """
    }

    /// Asks the reviewer to look again: now if it's waiting, else once
    /// it's started (resumed from the history if it was finished).
    private func reviewAgain(_ id: UUID, because reasons: String) async -> Bool {
        guard let session = sessions[id], let pr = session.reviewOf else { return false }
        // The PR's diff may have grown since the review started, so the
        // learnings fixed into its first prompt may now fall short of
        // what covers it.
        let learnings = await reviewLearnings(org: pr.org, harnessRepo: session.harnessRepo, repo: pr.repo, number: pr.number)
        let learned = HarnessLearning.reviewInstructions(learnings).map { "\n\n\($0)" } ?? ""
        let wasPosted = (reviewDrafts[id] ?? session.reviewDraft)?.postedLatest ?? false
        let prompt = SessionStore.lookAgainPrompt(pr, because: reasons, wasPosted: wasPosted, learned: learned, author: session.watch?.author)
        if isRunning(id) {
            guard state(id) == .idle else {
                // Claude has exited and left its shell, where a paste would go to bash.
                note(id, .failed, text: "Couldn't review it again: Claude Code isn't running in its tab")
                return false
            }
            submit(prompt, to: id)
        } else {
            if session.archivedAt != nil { update(id) { $0.archivedAt = nil } }
            pendingPrompts[id] = prompt
            _ = open(session)
        }
        automaticRuns.insert(id)
        note(id, .started, text: "Reviewing it again: \(reasons)")
        return true
    }

    /// A prompt waiting for claude to start, sent now it's ready.
    func sendPendingPrompt(_ id: UUID) {
        guard let prompt = pendingPrompts.removeValue(forKey: id) else { return }
        submit(prompt, to: id)
    }

    /// Logs something for the catch-up; already seen if you're looking at
    /// its review.
    private func note(_ id: UUID, _ kind: ReviewEvent.Kind, eventID: String? = nil, author: String? = nil, text: String? = nil, url: URL? = nil, at: Date = .now) {
        guard let pr = sessions[id]?.reviewOf else { return }
        let looking = windowIsKey && selectedTab == id && NSApp.isActive
        activity.record(ReviewEvent(
            id: eventID.map { "\(id.uuidString)-\($0)" } ?? UUID().uuidString, pullRequest: pr, session: id, kind: kind,
            at: at, author: author, text: text, url: url, seenAt: looking ? .now : nil
        ))
    }
}

// MARK: - Watched PRs from GitHub

struct WatchedPullRequest {
    struct Comment {
        let id: String
        let author: String
        let isBot: Bool
        let body: String
        let url: URL?
        let createdAt: Date
    }

    let state: String
    let headSHA: String
    /// The login of whoever opened the PR; nil if their account is gone.
    let author: String?
    /// Conversation comments, reviews with words, and comments on lines.
    let comments: [Comment]
}

extension GitHubAPI {
    /// Watched PRs by node ID, each one's latest comments and reviews, and
    /// who you are, so yours are left out.
    func watchedPullRequests(ids: [String]) async throws -> (login: String, pullRequests: [String: WatchedPullRequest]) {
        struct Author: Decodable { let __typename: String?; let login: String }
        struct Comment: Decodable { let id: String; let url: URL?; let body: String; let createdAt: Date; let author: Author? }
        struct Review: Decodable {
            let id: String
            let url: URL?
            let body: String
            let submittedAt: Date?
            let author: Author?
            let comments: Connection<Comment>
        }
        struct Node: Decodable {
            let id: String?
            let state: String?
            let headRefOid: String?
            let author: Author?
            let comments: Connection<Comment>?
            let reviews: Connection<Review>?
        }
        struct Viewer: Decodable { let login: String }
        struct Response: Decodable { let viewer: Viewer; let nodes: [Node?] }
        let response: Response = try await query("""
            query($ids: [ID!]!) {
              viewer { login }
              nodes(ids: $ids) {
                ... on PullRequest {
                  id state headRefOid author { __typename login }
                  comments(last: 30) { nodes { id url body createdAt author { __typename login } } }
                  reviews(last: 30) {
                    nodes {
                      id url body submittedAt author { __typename login }
                      comments(first: 30) { nodes { id url body createdAt author { __typename login } } }
                    }
                  }
                }
              }
            }
            """, values: ["ids": ids])
        func comment(_ id: String, _ author: Author?, _ body: String, _ url: URL?, _ at: Date) -> WatchedPullRequest.Comment {
            .init(id: id, author: author?.login ?? "ghost", isBot: author?.__typename == "Bot", body: body, url: url, createdAt: at)
        }
        var found: [String: WatchedPullRequest] = [:]
        for case let node? in response.nodes {
            guard let id = node.id, let state = node.state, let head = node.headRefOid else { continue }
            var comments = (node.comments?.nodes ?? []).map { comment($0.id, $0.author, $0.body, $0.url, $0.createdAt) }
            for review in node.reviews?.nodes ?? [] {
                // A review with no words is only its line comments.
                if !review.body.isEmpty {
                    comments.append(comment(review.id, review.author, review.body, review.url, review.submittedAt ?? .now))
                }
                comments += review.comments.nodes.map { comment($0.id, $0.author, $0.body, $0.url, $0.createdAt) }
            }
            found[id] = WatchedPullRequest(state: state, headSHA: head, author: node.author?.login, comments: comments)
        }
        return (response.viewer.login, found)
    }
}
