---
paths:
  - "Gannin/Sessions/PullRequestReview*"
  - "Gannin/Sessions/Review*"
  - "Gannin/Sessions/AutoReview*"
  - "Gannin/Sessions/ApprovalQueue*"
  - "Gannin/Agents/ReviewRuns*"
  - "Gannin/Sessions/EngineerWatch*"
  - "Gannin/Git/DiffHighlighter*"
  - "Gannin/Git/DiffLanguage*"
---

# Reviews

## Safety
- Never let an automatic review approve or request changes. Automatic runs (`automaticRuns`) post only as a COMMENT review, and only when post-automatic is on (`AutoReview.shouldPost`; project override beats the app setting).
- Never post an automatic review that would approve while it's `readyForApproval` (`holdsForApproval`): its findings go up once, in the user's approval from Post Review. Posting them as a comment first splits them over two reviews and repeats the summary. Hold one that isn't ready only when it has nothing to say: it never reaches the queue, so its findings would go nowhere.
- Post Review: send only Comment on the user's own PR (GitHub rejects the rest). Put inline comments only on lines the diff shows; everything else goes in the body.
- Never post findings without comparing them to the PR's current review comments (`ReviewedPullRequest.comments(for:draft:)` leaves out a duplicate): the sheet's copy of the PR dates from when it opened, so `PostReviewSheet.post()` re-fetches comments first, and `postAutomatically` uses a fresh `reviewedPullRequest`. A failed check must not block posting; show it. Check body findings too, against comments in the file and earlier reviews' bodies (`earlierReviews`): a follow-up review has a new summary, so `PostedReview.repeated` misses them. Only the viewer's outdated comments (`ExistingComment.isOutdated`) count: others' may be about code that has changed. Comments in resolved threads count, as the REST comments don't say which threads are resolved. Keep the "- `path:line`: comment" shape of `ReviewedPullRequest.body`, which `said` reads back. Never count the review's own post (a body starting with its summary) as an earlier review: its body findings would drop out and `PostedReview.repeated` would miss the shrunken body.
- Never post a review the viewer already has on GitHub (`PostedReview.repeated`: same kind, commit and body). `PostReviewSheet.post()` and `postAutomatically` check it just before posting, and a failed lookup must not block posting. `syncPostedReview` (Check for Changes) matches by the summary at the start of the body, since the body may have been edited.
- Resolve only unresolved threads on that PR that the viewer started (`GitHubAPI.resolvableThreads`), whatever IDs claude returns, and only after the review is posted.
- A PR is `readyForApproval` only if its review says approve, covers the latest commits, has no draft, failing checks or conflicts, and the reviewer hasn't dismissed it (`ReviewDraft.approvalDismissed`). Keep that in step with `ApprovalQueue.swift`.
- Never write `ReviewRecord.approvalHeld` from one place only: it is derived in `ReviewRecord.updated` from verdict, event and dismissal, so that every writer of the record agrees.
- An automatic comment posted for an approve verdict carries `ReviewedPullRequest.approvalHeldNote` (`postAutomatically` passes `approvalHeld`): the summary is written for an approval and, alone, reads as one on GitHub. A Comment posted by hand from Post Review doesn't, as the reviewer chose it.

## Reading claude's output
- Read the review JSON leniently (`SessionTranscript.review`, and `applied`, `learnings`, `checks`, `resolved`); a malformed entry must never lose the review. Add new fields the same way.
- Reviews run in the harness with edits disallowed (`--disallowedTools`). Keep that when changing `startReview`.

## Review workflow runs (`Gannin/Agents/ReviewRuns.swift`)
- A plain workflow starts no run (`reviewRun` nil): the review is exactly as before workflows.
- One review per PR: the lead session (`review(of:)`) runs the first stage's first Claude Code step and holds `reviewRun`; other steps are helpers with `reviewStep` and no `reviewOf`, so they never show as reviews of their own. Never set `reviewResult` on the lead before the run finishes: `finishRun` sets the merged result and calls `reviewFinished` once, which posting, approval and records act on.
- Route every round's result through `stepResult`; a result read again (the same as the last) must not count as a round. Every way a step's session can go must finish its step, or the run waits for ever: it ends (`stepEnded`), it's removed (`stepClosed`, before the session is cleared, while `reviewStep` still names the lead), or Gannin quit (`resumeReviewRuns` at launch). Every path that frees a slot calls `advanceWaitingRuns`: a step finishing, `reviewFinished`, and an automatic review's terminal ending.
- Mark an automatic run in `automaticRuns` before `advanceRun` starts its steps (`startReview(automatic:)`), or its first stage starts uncapped. `automaticRuns` isn't saved, so the run keeps `ReviewRun.automatic` and `resumeReviewRuns` puts it back before opening or advancing anything. A lead counts against the cap only while its own step runs, or two runs' leads fill it and neither can start a step.
- A step's findings are one per `Finding.key` (line and the start of the comment): two points on one line are two findings, and a new point on a flagged line counts as new for the round rule.
- Steps never edit or post: helpers are `isReviewer` (edits disallowed); one-shot CLIs run in a throwaway copy of a detached checkout, removed after, and only on this Mac.
- Merge with `PairReview.merge(labelled:)`, by file and line. A step's earlier stages' findings go into its prompt; those beside it never do.
- After a run finishes, Look Again asks the lead alone, and its result replaces the run's.

## Diff highlighting
- Never hand `DiffHighlighter` a line's `+`, `-` or space marker, and never change `DiffLine` ids: it would read the marker as code, and comments anchor to lines by id. `DiffRow` and `DiffPaneRow` draw the marker themselves.
- Keep the tints and marker colours for a highlighted row in the shared `DiffStyle`: the review's `DiffRow` and the session Changes pane's `DiffPaneRow` both use them. Repositories diffs aren't highlighted.

## Automatic review
- Gate on: not draft, not dismissed, not already started (`autoReviewedRequests`). Then ask `reviewGate` (review windows, `ReviewGate`): outside every window, queue it in `RoutineStore`'s `reviews.json` and remember it as handled, so a request removed from the queue isn't queued again. Cap concurrent runs at `AutoReview.maxRunning` with no windows, or the open window's reviews at once.
- Watched reviews' Look Again asks `reviewGate` too, queueing what changed and clearing the watch's counts. Reviews started by hand (`startReview`) never ask.
- Watched reviews: the first look only records state. Count commits and comments from others only (not the viewer, not bots), and ask the reviewer to look again only after `quietPeriod` with the reviewer idle. Merged or closed ends the watch.

## Review records (`ReviewRecords.swift`)
- Path is `.gannin/reviews/<owner>/<name>/<number>-<reviewer>.json`, snake case. Other code reads it (`AgentMetricsPage`), so keep the shape stable and read old files leniently.
- `SessionStore.recordReview` (in ReviewRecords.swift) must write only when something changed, and respect `recordReviewsInHarness`. `archiveReview` is in `SessionActions.swift`.
- Match a finding's thread outcome by path, author and the start of its text (`reviewOutcome`), not by ID.

## Review config (`ReviewConfig.swift`)
- Layer in this order, later wins, lists add up: harness `.gannin/review.json` (`defaults`, then the repo's `repos` section), then the repo's own `.gannin/review.json` on its default branch (`ReviewConfig.Layers`).
- A review snapshots its config in `CodeSession.reviewConfig`; don't re-read it mid-review.

## Testing
- Only `PairReviewTests.swift` (the pair loop), `DiffQuestionTests.swift` (the question Ask Claude sends from a diff line), `ReviewGateTests.swift` (review windows) and `ApprovalQueueTests.swift` (which automatic reviews are held) touch review code. Nothing covers records, config layering, the rest of auto review or `readyForApproval`; add tests beside them.
