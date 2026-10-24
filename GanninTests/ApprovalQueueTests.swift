import Foundation
import Testing
@testable import Gannin

/// Automatic reviews Claude would approve are held for the user, findings and all, while they're ready.
struct ApprovalQueueTests {
    private let findings: [SessionTranscript.Finding] = [
        .init(path: "A.swift", line: 3, comment: "Off by one"),
        .init(path: "B.swift", line: nil, comment: "Missing test"),
    ]

    private func review(_ verdict: String?, findings: [SessionTranscript.Finding] = []) -> SessionTranscript.ReviewResult {
        .init(summary: "s", verdict: verdict, findings: findings)
    }

    @Test func approvalWithNothingToSayIsHeldReadyOrNot() {
        #expect(SessionStore.holdsForApproval(review("approve"), draft: ReviewDraft(), isReady: true))
        #expect(SessionStore.holdsForApproval(review("approve"), draft: ReviewDraft(), isReady: false))
    }

    @Test func approvalWithFindingsIsHeldWhenReady() {
        #expect(SessionStore.holdsForApproval(review("approve", findings: findings), draft: ReviewDraft(), isReady: true))
    }

    /// Failing checks or conflicts keep it out of the queue, so its findings
    /// are posted rather than held where nobody sees them.
    @Test func approvalWithFindingsIsPostedWhenNotReady() {
        #expect(!SessionStore.holdsForApproval(review("approve", findings: findings), draft: ReviewDraft(), isReady: false))
        var draft = ReviewDraft()
        for finding in findings { draft.decisions[finding.key] = .dismissed }
        #expect(SessionStore.holdsForApproval(review("approve", findings: findings), draft: draft, isReady: false))
    }

    @Test func commentsAndChangeRequestsAreNotHeld() {
        #expect(!SessionStore.holdsForApproval(review("comment", findings: findings), draft: ReviewDraft(), isReady: true))
        #expect(!SessionStore.holdsForApproval(review("request_changes", findings: findings), draft: ReviewDraft(), isReady: true))
        #expect(!SessionStore.holdsForApproval(review(nil, findings: findings), draft: ReviewDraft(), isReady: true))
    }

    private func reviewSession(_ verdict: String?) -> CodeSession {
        let pr = PullRequestReference(
            org: "acme", id: "PR_1", number: 7, title: "Plan", repo: "acme/harness",
            url: URL(string: "https://github.com/acme/harness/pull/7")!
        )
        var session = CodeSession(
            id: UUID(), issue: IssueReference(org: "acme", id: "I_1", number: 7, title: "Plan", repo: "acme/harness", url: pr.url),
            repo: "acme/harness", branch: "review", createdAt: .now
        )
        session.reviewOf = pr
        session.reviewResult = review(verdict)
        return session
    }

    private func record(_ verdict: String?, draft: ReviewDraft = ReviewDraft(), posting: Bool = false, state: String? = nil) -> ReviewRecord? {
        let outcome = state.map { ReviewOutcome(title: nil, author: nil, state: $0, mergedAt: nil, threads: []) }
        return ReviewRecord.updated(nil, session: reviewSession(verdict), review: review(verdict), draft: draft, reviewer: "andrew", posting: posting, automatically: posting, outcome: outcome)
    }

    @Test func recordDoesNotHoldAnApprovalOnceMergedOrClosed() {
        #expect(record("approve", state: "OPEN")?.approvalHeld == true)
        #expect(record("approve", state: "MERGED")?.approvalHeld == nil)
        #expect(record("approve", state: "CLOSED")?.approvalHeld == nil)
    }

    @Test func dismissedApprovalLeavesTheQueueUntilANewResult() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ApprovalQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "ApprovalQueueTests-\(UUID().uuidString)")!)
        let session = reviewSession("approve")
        store.add(session)
        #expect(store.readyForApproval("PR_1")?.id == session.id)
        var draft = ReviewDraft()
        draft.resultAt = Date(timeIntervalSince1970: 100)
        draft.approvalDismissedAt = Date(timeIntervalSince1970: 200)
        store.reviewDrafts[session.id] = draft
        #expect(store.readyForApproval("PR_1") == nil)
        // Claude reviews again: a new approval to give or dismiss.
        store.reviewDrafts[session.id]?.resultAt = Date(timeIntervalSince1970: 300)
        #expect(store.readyForApproval("PR_1")?.id == session.id)
    }

    @Test func recordMarksAnApprovalNotGivenAsHeld() {
        #expect(record("approve")?.approvalHeld == true)
        // Posted as a comment: the verdict is approve, but what reached GitHub isn't.
        var commented = ReviewDraft()
        commented.postedEvent = "COMMENT"
        #expect(record("approve", draft: commented, posting: true)?.approvalHeld == true)
        #expect(record("approve", draft: commented, posting: true)?.event == "COMMENT")
    }

    @Test func recordDoesNotHoldAnApprovalOnceGivenOrDismissed() {
        var approved = ReviewDraft()
        approved.postedEvent = "APPROVE"
        #expect(record("approve", draft: approved, posting: true)?.approvalHeld == nil)
        var dismissed = ReviewDraft()
        dismissed.approvalDismissedAt = .now
        #expect(record("approve", draft: dismissed)?.approvalHeld == nil)
    }

    @Test func recordHoldsNothingForOtherVerdicts() {
        #expect(record("comment")?.approvalHeld == nil)
        #expect(record("request_changes")?.approvalHeld == nil)
    }

    @Test func dismissalLapsesWithANewResult() {
        var draft = ReviewDraft()
        draft.resultAt = Date(timeIntervalSince1970: 100)
        draft.approvalDismissedAt = Date(timeIntervalSince1970: 200)
        #expect(draft.approvalDismissed)
        draft.resultAt = Date(timeIntervalSince1970: 300)
        #expect(!draft.approvalDismissed)
    }

    @Test func approvalHeldNoteIsAddedToTheBodyOnlyWhenHeld() {
        #expect(!ReviewedPullRequest.body(summary: "Looks good.", general: []).contains(ReviewedPullRequest.approvalHeldNote))
        let held = ReviewedPullRequest.body(summary: "Looks good.", general: [], approvalHeld: true)
        #expect(held.hasPrefix("Looks good."))
        #expect(held.contains(ReviewedPullRequest.approvalHeldNote))
    }

    private func openPullRequest(author: String = "author", requested: Bool = false, draft: Bool = false, checks: ItemDetail.CheckState? = nil) -> PullRequest {
        PullRequest(
            id: "PR_1", number: 7, title: "Plan", url: URL(string: "https://github.com/acme/harness/pull/7")!, repo: "acme/harness",
            author: Person(login: author, name: nil, avatarUrl: nil), isDraft: draft, state: "OPEN", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: .now, mergedAt: nil, reviewDecision: nil, additions: 0, deletions: 0, changedFiles: 0, assignees: [],
            requestedReviewers: requested ? [Person(login: "andrew", name: nil, avatarUrl: nil)] : [], reviewRequestedAt: [:], reviewers: [],
            linkedIssues: [], checks: checks, reviewStates: nil, reviewedAt: nil, lastCommitAt: nil, authorRepliedAt: nil
        )
    }

    private func queueStore(posted: Bool) -> SessionStore {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ApprovalQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "ApprovalQueueTests-\(UUID().uuidString)")!)
        var session = reviewSession("approve")
        if posted {
            // An automatic comment: GitHub then stops listing the PR as asking for your review.
            var draft = ReviewDraft()
            draft.postedEvent = "COMMENT"
            draft.postedAt = Date(timeIntervalSince1970: 200)
            session.reviewDraft = draft
        }
        store.add(session)
        return store
    }

    /// A comment posted for an approve verdict makes GitHub drop the review request, which mustn't drop the approval.
    @Test func approvalStaysInTheQueueAfterItsReviewRequestIsDropped() {
        let store = queueStore(posted: true)
        let asked = store.approvalQueue(in: [openPullRequest(requested: true)], login: "andrew")
        let dropped = store.approvalQueue(in: [openPullRequest(requested: false)], login: "andrew")
        #expect(asked.count == 1)
        #expect(dropped.count == 1)
        #expect(dropped.first?.askedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func approvalIsNotQueuedWhileItsPullRequestIsNotReady() {
        let store = queueStore(posted: true)
        #expect(store.approvalQueue(in: [openPullRequest(draft: true)], login: "andrew").isEmpty)
        #expect(store.approvalQueue(in: [openPullRequest(checks: .failure)], login: "andrew").isEmpty)
        #expect(store.approvalQueue(in: [openPullRequest(author: "andrew")], login: "andrew").isEmpty)
        #expect(store.approvalQueue(in: [openPullRequest()], login: nil).isEmpty)
        // The checks pass: it comes back with no review request on it.
        #expect(store.approvalQueue(in: [openPullRequest(checks: .success)], login: "andrew").count == 1)
    }

    /// `findingEntries` reads every line after a finding as part of it, so the note can't follow the list.
    @Test func approvalHeldNoteComesBeforeTheFindingsList() throws {
        let body = ReviewedPullRequest.body(summary: "Looks good.", general: [findings[1]], approvalHeld: true)
        let note = try #require(body.range(of: ReviewedPullRequest.approvalHeldNote))
        let finding = try #require(body.range(of: "- `B.swift`: Missing test"))
        #expect(note.upperBound <= finding.lowerBound)
        #expect(body.hasSuffix("Missing test"))
    }

    @Test func aNeverNotifiedApprovalIsDueAReminder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionStore.isDueReminder(noticed: nil, now: now))
        #expect(!SessionStore.isDueReminder(noticed: now.addingTimeInterval(-3600), now: now))
        #expect(SessionStore.isDueReminder(noticed: now.addingTimeInterval(-SessionStore.approvalReminderInterval), now: now))
    }

    /// Kept with the review, so a relaunch doesn't restart the 24 hours or notify again at once.
    @Test func theNotifiedTimeSurvivesBeingSaved() throws {
        var draft = ReviewDraft()
        draft.approvalNoticedAt = Date(timeIntervalSince1970: 500)
        let decoded = try JSONDecoder().decode(ReviewDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded.approvalNoticedAt == Date(timeIntervalSince1970: 500))
        // A draft saved before it existed has no such key.
        let older = try JSONDecoder().decode(ReviewDraft.self, from: JSONEncoder().encode(ReviewDraft()))
        #expect(older.approvalNoticedAt == nil)
    }

    @Test func recordDoesNotHoldAnApprovalGivenOnGitHubByHand() {
        // Check for Changes sets the draft's event from GitHub without posting.
        var draft = ReviewDraft()
        draft.postedEvent = "APPROVE"
        #expect(record("approve", draft: draft)?.approvalHeld == nil)
    }

    @Test func dismissedFindingsAreNotHeld() {
        var draft = ReviewDraft()
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 2)
        draft.decisions[findings[0].key] = .dismissed
        draft.decisions[findings[1].key] = .edited("Add a test for the empty token")
        #expect(SessionStore.heldFindings(review("approve", findings: findings), draft: draft) == 1)
    }
}
