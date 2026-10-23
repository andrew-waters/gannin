import Foundation

/// Reviews ready for your approval: Claude would approve, it has seen the
/// PR as it is, and nothing's in the way. They're team blockers, so they
/// come first (the Inbox's Ready for your approval, the Dashboard's Act
/// now, a notification and the waiting count), but the approval is always
/// yours, given from the review tab after you've looked: automatic reviews
/// never approve, and one Claude would approve isn't posted at all, so its
/// comments go up once, with your approval.
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
              (reviewDrafts[session.id] ?? session.reviewDraft)?.postedEvent != "APPROVE",
              (reviewDrafts[session.id] ?? session.reviewDraft)?.approvalDismissed != true else { return nil }
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
        approvalNoticedAt[id] = .now
        flag(id, title: "Ready for your approval", body: "Claude would approve \(pr.repo)#\(pr.number). Look over the review, then approve it.", replies: false)
    }

    /// How long a held approval waits before its notification is sent again.
    static let approvalReminderInterval: TimeInterval = 24 * 3600

    /// Notifies again for each approval in the queue that's been waiting
    /// `approvalReminderInterval` since its last notification, until it's
    /// given or dismissed. Run on each check of the watched reviews.
    func remindApprovals(now: Date = .now) {
        for (_, session) in approvalQueue() {
            guard let noticed = approvalNoticedAt[session.id] else {
                // Found already waiting (after a relaunch): counted from now.
                approvalNoticedAt[session.id] = now
                continue
            }
            if now.timeIntervalSince(noticed) >= Self.approvalReminderInterval { noticeApproval(session.id) }
        }
    }

    /// Puts a held approval away without giving it: it leaves the Inbox, the
    /// Dashboard and the waiting count, and its record stops saying it's held.
    func dismissApproval(_ id: UUID) {
        reviewDrafts[id, default: sessions[id]?.reviewDraft ?? ReviewDraft()].approvalDismissedAt = .now
        unflag(id)
        Task { await recordReview(id) }
    }

    /// Whether automatic posting should hold the review for you: Claude
    /// would approve and the PR is `isReady` for you, so it waits, findings
    /// and all, for your approval to go up as the one review (posting them
    /// now would post them again beside yours). One with nothing to say is
    /// held either way, as a comment would only be noise. One that isn't
    /// ready but has findings is posted, or they'd go nowhere.
    static func holdsForApproval(_ review: SessionTranscript.ReviewResult, draft: ReviewDraft, isReady: Bool) -> Bool {
        review.verdict == "approve" && (isReady || heldFindings(review, draft: draft) == 0)
    }

    /// The findings a held approval carries (those not dismissed), which go
    /// up with your approval.
    static func heldFindings(_ review: SessionTranscript.ReviewResult, draft: ReviewDraft) -> Int {
        review.findings.count { draft.decisions[$0.key] != .dismissed }
    }

    /// "Claude would approve", with how many findings it's holding for you.
    /// Findings: Post Review may leave out some already on the PR.
    func approvalState(_ session: CodeSession) -> String {
        guard let result = transcripts[session.id]?.review ?? session.reviewResult else { return "Claude would approve" }
        let held = Self.heldFindings(result, draft: reviewDrafts[session.id] ?? session.reviewDraft ?? ReviewDraft())
        return held == 0 ? "Claude would approve" : "Claude would approve · \(held) finding\(held == 1 ? "" : "s")"
    }
}
