---
type: plan
status: In Review
summary: A held approval is marked held in the review record, a comment posted for it says it isn't an approval, and the reviewer is reminded until they approve or dismiss it.
issues: [andrew-waters/gannin#442]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Held approvals are visible

## Approach

`verdict` stays Claude's and `event` stays what reached GitHub; a new `approvalHeld` in the record joins them, so a reader doesn't have to compare the two. It is derived in `ReviewRecord.updated` (verdict is approve, event isn't `APPROVE`, not dismissed, and the PR isn't `MERGED` or `CLOSED`, which is read after the outcome is applied) rather than set by `postAutomatically`, so every write path, including a merge noted later, agrees.

The summary is Claude's text and can't be reliably rewritten, so the posted comment gets a fixed line after it, and the reviewer prompt tells Claude not to write that it approves.

Dismissing is stored on `ReviewDraft` (`approvalDismissedAt`, compared with `resultAt`) so it lapses when Claude reviews again. `readyForApproval` returns nil for a dismissed approval, which takes it out of the Inbox, the Dashboard, the waiting count and the reminder with one check. A merged or closed PR still leaves the queue, as before.

GitHub drops a PR from your review requests once you've posted a review on it, even the COMMENT an automatic review goes up as, so a queue built from `waitingReviews` lost the very approvals this issue is about. `approvalQueue(in:login:)` takes the workload's open PRs and keeps those with a ready review of yours, requested or not. For one with no request, readiness comes from the workload's copy of the PR (draft, failing checks); conflicts are only visible on a request, so a PR that conflicts after its request is dropped still shows.

The reminder is `SessionStore.remindApprovals`, run on each check of watched reviews over the open PRs in `PullRequestStore`. The last-notified time is `ReviewDraft.approvalNoticedAt`, saved with the review, so the 24 hours carry across relaunches; an approval never notified about (it became ready after its review finished) is notified about at the next check. The Agents and Inbox badges count held approvals as well as flagged sessions, as looking at a review's tab clears its flag.

- [x] `ReviewRecord.approvalHeld`, derived in `updated`.
- [x] `ReviewedPullRequest.approvalHeldNote` added to the body of an automatic comment whose verdict is approve; summary instruction in the review prompt.
- [x] `ReviewDraft.approvalDismissedAt`, `SessionStore.dismissApproval`, and Dismiss Approval in the Inbox and Dashboard menus.
- [x] `remindApprovals`, called from the watched-reviews check.
- [x] Tests in `ApprovalQueueTests` for the record, the dismissal and the body.
- [x] Docs (`agents/auto-review.md`), CHANGELOG and the reviews rule.
- [ ] Check by hand with `scripts/relaunch.sh`: dismiss from the Inbox and from the Dashboard; the 24 hour reminder has no test.
