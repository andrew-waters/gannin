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
        if let request = EngineerWatch.shared.reviewRequests.first(where: { $0.id == pullRequestID }) {
            if request.isDraft || request.isFailing || request.mergeable == "CONFLICTING" { return nil }
        } else if let known = workloadPullRequest(pullRequestID, org: session.org) {
            // GitHub drops your review request once you've posted a review,
            // even a comment, so the workload's copy is all there is: it
            // knows drafts and checks, not conflicts.
            if known.state != "OPEN" || known.isDraft || known.checks == .failure || known.checks == .error { return nil }
        }
        let failsAnError = (result.checks ?? []).contains { check in
            check.result.lowercased() == "fail" && session.reviewConfig?.mode(of: check.name) == .error
        }
        return failsAnError ? nil : session
    }

    /// The PR as the workload last fetched it; nil if it hasn't.
    private func workloadPullRequest(_ id: String, org: String) -> PullRequest? {
        PullRequestStore.shared.pullRequests(org: org)[id]?.workloadPullRequest
    }

    /// Every review ready for approval among `pullRequests` (the open PRs the
    /// workload has), longest waiting first: those asking for your review,
    /// and those you've reviewed already, which GitHub no longer lists as
    /// asking once the review is posted, even as a comment. Without the
    /// second kind an approval that went up as a comment would never come
    /// back to you.
    func approvalQueue(in pullRequests: [PullRequest], login: String?) -> [(pr: PullRequest, session: CodeSession, askedAt: Date)] {
        pullRequests.compactMap { pr in
            guard !pr.isDraft, pr.checks != .failure, pr.checks != .error,
                  let login, pr.author?.login.caseInsensitiveCompare(login) != .orderedSame,
                  let session = readyForApproval(pr.id) else { return nil }
            let draft = reviewDrafts[session.id] ?? session.reviewDraft
            return (pr, session, pr.reviewRequestedAt[login] ?? draft?.postedAt ?? pr.createdAt)
        }
        .sorted { $0.askedAt < $1.askedAt }
    }

    /// A review's result is in: when it's ready for you, it's flagged as
    /// waiting on you with a notification saying so.
    func noticeApproval(_ id: UUID, now: Date = .now) {
        guard let pr = sessions[id]?.reviewOf, readyForApproval(pr.id, whileBusy: true) != nil else { return }
        reviewDrafts[id, default: sessions[id]?.reviewDraft ?? ReviewDraft()].approvalNoticedAt = now
        flag(id, title: "Ready for your approval", body: "Claude would approve \(pr.repo)#\(pr.number). Look over the review, then approve it.", replies: false)
    }

    /// How long a held approval waits before its notification is sent again.
    static let approvalReminderInterval: TimeInterval = 24 * 3600

    /// Whether an approval last notified about at `noticed` (kept with the
    /// review, so across launches) is due another notification. One never
    /// notified about is: it became ready after its review finished.
    static func isDueReminder(noticed: Date?, now: Date) -> Bool {
        guard let noticed else { return true }
        return now.timeIntervalSince(noticed) >= approvalReminderInterval
    }

    /// Notifies again for each approval that's due (`isDueReminder`), until
    /// it's given or dismissed. Run on each check of the watched reviews,
    /// over the open PRs the workload last fetched for the orgs reviewed.
    func remindApprovals(now: Date = .now) {
        guard let login = viewerLogin() else { return }
        let orgs = Set(sessions.values.filter { $0.reviewOf != nil }.map(\.org))
        let open = orgs.flatMap { PullRequestStore.shared.pullRequests(org: $0).values.compactMap(\.workloadPullRequest) }.filter { $0.state == "OPEN" }
        for (_, session, _) in approvalQueue(in: open, login: login) {
            let noticed = (reviewDrafts[session.id] ?? session.reviewDraft)?.approvalNoticedAt
            if Self.isDueReminder(noticed: noticed, now: now) { noticeApproval(session.id, now: now) }
        }
    }

    /// Puts a held approval away without giving it: it leaves the Inbox, the
    /// Dashboard and the waiting count, and its record stops saying it's held.
    func dismissApproval(_ id: UUID) {
        var draft = reviewDrafts[id] ?? sessions[id]?.reviewDraft ?? ReviewDraft()
        draft.approvalDismissedAt = .now
        // Only the flag the approval raised: a question or permission prompt
        // from the same session is still waiting.
        let raised = draft.approvalNoticedAt != nil
        draft.approvalNoticedAt = nil
        reviewDrafts[id] = draft
        if raised, state(id) != .needsYou { unflag(id) }
        // Supersedes the log's "waiting for you".
        note(id, .reviewed, text: "You dismissed the approval Claude was holding for you", seen: true)
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
