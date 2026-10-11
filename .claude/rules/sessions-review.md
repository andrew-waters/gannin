---
paths:
  - "Gannin/Sessions/PullRequestReview*"
  - "Gannin/Sessions/Review*"
  - "Gannin/Sessions/AutoReview*"
  - "Gannin/Sessions/ApprovalQueue*"
  - "Gannin/Sessions/EngineerWatch*"
---

# Reviews (Review with Claude, auto review, records, config, approval)

- A review is `CodeSession.reviewOf`, started by `SessionStore.startReview`: runs in the harness with edits disallowed (`--disallowedTools`) and ends with a JSON object read by `SessionTranscript.review`. New fields are read leniently so a bad entry never loses a review (same for `applied`, `learnings`, `checks`, `resolved`). Its tab is `PullRequestReviewView`, not a terminal and panel.
- `ReviewReadiness` is computed from `sessionPullRequests` (conflicts, draft, decision, checks, open threads) plus non-dismissed findings; the same sentence is the header and the Overview's.
- Findings carry `ReviewCategory` (CodeRabbit's six). Per-line decisions live in `ReviewDraft`.
- Post Review (`PostReviewSheet`) goes through REST. Only Comment is allowed on your own PR (GitHub takes nothing else from the author). A suggestion is posted as a GitHub suggestion block. Inline comments only on lines the diff shows; the rest goes in the body.
- Thread resolving: the reviewer names threads it considers dealt with in `ReviewResult.resolved`, but only unresolved threads on that PR that the viewer started are resolved (`GitHubAPI.resolvableThreads`), whatever IDs claude returns. Resolution happens after the review is posted (`resolveReviewThread`).
- History: `CodeSession.reviewResult` and `reviewDraft` are saved with the session. `SessionStore.archiveReview` keeps the review (`archivedAt`) and removes its checkout; archived ones open read-only without starting claude.
- Learnings in reviews: the prompt lists `HarnessIndex.learnings(for:)` for the PR's repo (`HarnessLearning.reviewInstructions`; the helper reviewer gets the harness's). JSON adds `applied` (with `concern`) and `learnings` (`ProposedLearning`). `ReviewDiff.learningPlacement` puts file/folder learnings at the top and line ones at their first shown line. `SessionStore.challengePrompt` pastes your objection to the reviewer.
- `EngineerWatch` polls one query (`engineerWork`) for review requests, your PRs and your issues; new requests notify through `startReview` (wired in `GanninApp`).

## Auto review (`AutoReview.swift`)
- All settings are the user's own, per Mac. Org override `autoReviewRequests.<org>` beats `autoReviewRequests`; post override is keyed by harness repo (`AutoReview.shouldPost`).
- A request qualifies if not draft, not dismissed, not already started (`autoReviewedRequests`). `startAutomaticReview` = `startReview(reveals: false)` then `open` launches claude with no tab. At most `AutoReview.maxRunning` (2) at once; the rest wait for a later check.
- `reviewFinished` sets `CodeSession.watch` (`ReviewWatch`). `checkWatchedReviews` (interval is Sync's Watched reviews; `EngineerWatch.checkWatched` holds off when the budget is low) fetches each watched PR by node ID (`watchedPullRequests`). First look only records state. New commits and comments by others (not the viewer, not bots) count; after `quietPeriod` with nothing new and the reviewer idle, `reviewAgain` runs: pasted if idle, else resumed and sent when `SessionStart` reports idle (`pendingPrompts`). Merged or closed ends the watch.
- Automatic runs (`automaticRuns`) are posted only as a COMMENT review, never approving or requesting changes, and only when post-automatic is on; otherwise they wait for Post Review.
- `ReviewActivity`/`ReviewEvent` (newest 500, `Sessions/ReviewActivity.json`) feed the Inbox's While you were away, one row per review until `looked`/`markSeen`.

## Approval (`ApprovalQueue.swift`)
- Invariant: automatic reviews never approve, and a review that would approve with nothing to say isn't posted at all (`holdsForApproval`). Approval is always the human's.
- `SessionStore.readyForApproval`: review says approve, covers the latest commits (`ReviewWatch.hasNewCommits`), not running, not already approved from Gannin, no draft, failing checks, conflicts or failed error check. Feeds the Inbox, Dashboard Act now and `noticeApproval`. Post Review starts on Approve except when there are commits the review hasn't seen.

## Review records (`ReviewRecords.swift`)
- Committed to the harness at `.gannin/reviews/<owner>/<name>/<number>-<reviewer>.json` (snake case): who, verdict, effort, what was posted and when (hand or automatic), PR state, each finding by key across rounds (severity, category, kept/edited/dismissed, posted, thread resolved).
- Thread outcome is matched by path, author and the start of the text (`reviewOutcome`).
- `SessionStore.recordReview` writes on post, automatic post, finish, or watched PR merge/close, only when something changed; gated by `recordReviewsInHarness` (on). `AgentMetricsPage` reads them from the project's harnesses via the index (`.gannin/*.json`) plus unrecorded local reviews.

## Review config (`ReviewConfig.swift`)
- Stored in the project harness as `.gannin/review.json` (`HarnessReviewConfig`: `defaults` plus `repos` sections) and optionally in a repo's `.gannin/review.json` on its default branch (`GitHubAPI.repoFile`). `SessionStore.reviewConfig` layers them in that order via `ReviewConfig.Layers`: later wins, lists add up.
- A review snapshots it (`CodeSession.reviewConfig`) and puts it in its prompt. Check results come back as the JSON's `checks`; error checks are blocking tiers, warnings fix-before-merging. Skipped files are globs (`Glob`). Title keywords make automatic reviews skip.
- `ReviewConfigSheet` writes the harness sections in one commit each, or the repo's own file into the clone (to commit by hand). Statuses on GitHub are not implemented.
