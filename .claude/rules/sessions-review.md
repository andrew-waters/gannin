---
paths:
  - "Gannin/Sessions/PullRequestReview*"
  - "Gannin/Sessions/Review*"
  - "Gannin/Sessions/AutoReview*"
  - "Gannin/Sessions/ApprovalQueue*"
  - "Gannin/Sessions/EngineerWatch*"
---

# Reviews

## Safety
- Never let an automatic review approve or request changes. Automatic runs (`automaticRuns`) post only as a COMMENT review, and only when post-automatic is on (`AutoReview.shouldPost`; project override beats the app setting).
- Never post a review that would approve with nothing to say (`holdsForApproval`); approval is always the user's.
- Post Review: send only Comment on the user's own PR (GitHub rejects the rest). Put inline comments only on lines the diff shows; everything else goes in the body.
- Resolve only unresolved threads on that PR that the viewer started (`GitHubAPI.resolvableThreads`), whatever IDs claude returns, and only after the review is posted.
- A PR is `readyForApproval` only if its review says approve, covers the latest commits, and has no draft, failing checks or conflicts. Keep that in step with `ApprovalQueue.swift`.

## Reading claude's output
- Read the review JSON leniently (`SessionTranscript.review`, and `applied`, `learnings`, `checks`, `resolved`); a malformed entry must never lose the review. Add new fields the same way.
- Reviews run in the harness with edits disallowed (`--disallowedTools`). Keep that when changing `startReview`.

## Diff highlighting
- Never hand `DiffHighlighter` a line's `+`, `-` or space marker, and never change `DiffLine` ids: it reads the marker as code, and comments anchor to lines by id. `DiffRow` draws the marker itself. `DiffStyle` stays as it is, since session changes and Repositories diffs share it.

## Automatic review
- Gate on: not draft, not dismissed, not already started (`autoReviewedRequests`). Cap concurrent runs at `AutoReview.maxRunning`.
- Watched reviews: the first look only records state. Count commits and comments from others only (not the viewer, not bots), and ask the reviewer to look again only after `quietPeriod` with the reviewer idle. Merged or closed ends the watch.

## Review records (`ReviewRecords.swift`)
- Path is `.gannin/reviews/<owner>/<name>/<number>-<reviewer>.json`, snake case. Other code reads it (`AgentMetricsPage`), so keep the shape stable and read old files leniently.
- `SessionStore.recordReview` (in ReviewRecords.swift) must write only when something changed, and respect `recordReviewsInHarness`. `archiveReview` is in `SessionActions.swift`.
- Match a finding's thread outcome by path, author and the start of its text (`reviewOutcome`), not by ID.

## Review config (`ReviewConfig.swift`)
- Layer in this order, later wins, lists add up: harness `.gannin/review.json` (`defaults`, then the repo's `repos` section), then the repo's own `.gannin/review.json` on its default branch (`ReviewConfig.Layers`).
- A review snapshots its config in `CodeSession.reviewConfig`; don't re-read it mid-review.

## Testing
- Only `PairReviewTests.swift` touches review code (the pair loop). Nothing covers records, config layering, auto review or approval; add tests beside it.
