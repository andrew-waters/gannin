import Foundation

/// Reviews ready for your approval: Claude would approve, it has seen the
/// PR as it is, and nothing's in the way. They're team blockers, so they
/// come first (the Inbox's Ready for your approval, the Dashboard's Act
/// now, a notification and the waiting count), but the approval is always
/// yours, given from the review tab after you've looked: automatic reviews
/// never approve, and one Claude would approve with nothing to say isn't
/// posted at all.
extension SessionStore {
    /// The PR's review when it's ready for you to approve; nil otherwise.
    /// `whileBusy` counts one the reviewer is just finishing (its result
    /// arrives before its state settles).
    func readyForApproval(_ pullRequestID: String, whileBusy: Bool = false) -> CodeSession? {
        guard let session = review(of: pullRequestID),
              let result = transcripts[session.id]?.review ?? session.reviewResult,
              result.verdict == "approve",
              // New commits since: not ready until it's looked again.
              session.watch?.hasNewCommits != true,
              (reviewDrafts[session.id] ?? session.reviewDraft)?.postedEvent != "APPROVE" else { return nil }
        if !whileBusy, isRunning(session.id), [.working, .starting].contains(state(session.id)) { return nil }
        if let request = EngineerWatch.shared.reviewRequests.first(where: { $0.id == pullRequestID }),
           request.isDraft || request.isFailing || request.mergeable == "CONFLICTING" { return nil }
        let failsAnError = (result.checks ?? []).contains { check in
            check.result.lowercased() == "fail" && session.reviewConfig?.mode(of: check.name) == .error
        }
        return failsAnError ? nil : session
    }

    /// Every review ready for approval among your review requests, longest
    /// waiting first.
    func approvalQueue(org: String? = nil) -> [(request: EngineerWatch.PullRequestItem, session: CodeSession)] {
        EngineerWatch.shared.waitingReviews
            .filter { org == nil || $0.org.caseInsensitiveCompare(org!) == .orderedSame }
            .compactMap { request in readyForApproval(request.id).map { (request, $0) } }
            .sorted { $0.request.createdAt < $1.request.createdAt }
    }

    /// A review's result is in: when it's ready for you, it's flagged as
    /// waiting on you with a notification saying so.
    func noticeApproval(_ id: UUID) {
        guard let pr = sessions[id]?.reviewOf, readyForApproval(pr.id, whileBusy: true) != nil else { return }
        flag(id, title: "Ready for your approval", body: "Claude would approve \(pr.repo)#\(pr.number). Look over the review, then approve it.", replies: false)
    }

    /// Whether automatic posting should hold the review for you: Claude
    /// would approve and has nothing to say, so a comment from your account
    /// would only be noise, or read as an approval.
    static func holdsForApproval(_ review: SessionTranscript.ReviewResult, draft: ReviewDraft) -> Bool {
        review.verdict == "approve" && !review.findings.contains { draft.decisions[$0.key] != .dismissed }
    }
}
