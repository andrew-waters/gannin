---
paths:
  - "Gannin/Sessions/PairReview*"
  - "Gannin/Sessions/ExtraReviewer*"
---
# Pair review

- Only an issue's own session gets it (`canPairReview`); never a helper, PR review, plan or Ask.
- Take each reviewer reply once (`lastReplyID`), or a round is counted twice.
- A reply with no JSON list is not a round (`listedFindings` is nil); `[]` means nothing found.
- Keep the last round's findings sent when `maxRounds` is hit.
- Do not flag the session when turns end during the loop (`isQuietForPairReview`); flag only on Stop or settling.
- After a limit or Stop, or with the setting off, answer a request "carry on"; after Settled start a fresh loop.
- Replace a reviewer whose sandbox failed to start rather than message it: its prompt would wait for a claude that never started, and its `reviewing` phase would hide the request.
- Never post anything to GitHub from this loop.

## Extra reviewers
- `reviewerID` is the claude reviewer. Extras (`ExtraReviewer`, built-in presets only) are tracked in `PairReview.extras` by preset id and reset by `startExtras` each round. Which are on is `HarnessConfig.extraReviewers`: this Mac only, never the harness. Ignore ids this build doesn't know, so a newer build's config still loads.
- Finish a round only through `finishRoundIfReady`, which claude's reply and each extra both call. Never call `finishRound` from a reply directly: it would finish before an extra that started has answered. The phase leaving `reviewing` is what stops a second call finishing it again.
- A failed extra counts as having found nothing and keeps its message for the panel, with a capped copy of what the CLI printed (`ExtraReview.output`, `ExtraReviewer.shown`) that is saved with the pairing. Never let one hold up claude's round: `ExtraReviewer.review` gives up after the timeout plus grace, and each start's `run` ID stops a run from an earlier loop answering for a later one.
- A reviewer must return the same fenced JSON list as claude (`[]` for nothing) and run as a one-shot process in a throwaway copy of the worktree, never in the worktree. "Can't edit" is enforced by discarding the copy, since a CLI's own read-only flags aren't trusted (Junie's `--plan` still edited). A worktree's `.git` file points at its admin directory in the main clone, so the script re-points each one in the copy at a private copy of that directory and of the clone's refs and config, borrowing the objects as an alternate: without that, `git commit` or `reset` in the copy moves the real branch. A `.git` with no `commondir` (a submodule's, or a separate git dir) is left as it was, so it isn't isolated. The copy doesn't protect other state, such as the CLI's own MCP servers.
- Give the CLI `</dev/null`: `set -m` stops bash doing it for a background job, and the script is read from stdin, so a CLI that reads stdin would swallow the rest of it.
- Stop a CLI's whole process group on timeout (`set -m`, `kill -TERM -$pid`), not just its launcher, or its children keep writing into the copy being deleted. Persisted `running` extras are failed on load (`abandonRunningExtras`): their run died with the app, and nothing else would finish the round.
- Stop an extra's run when its round ends early (`cancelRunningExtras`: Stop, the session removed, or a new round replacing it), not only on its timeout: a stale run's result is ignored but it still costs CPU, disk and the CLI's quota. The run's folder is named for its `run` ID so `cancelScript` can find its process group; the cancel does nothing once the run has ended, so it can't leave a folder behind. `abandonRunningExtras` fails extras only in a `reviewing` round: a stopped review's panel line must still say it stopped.
- Merge findings by file and line across reviewers, never by comment text: two models don't word a problem alike, so matching text would show every finding twice.
- Run extras for local, unsandboxed sessions only: they need the CLI installed and signed in on this Mac.
- Label findings with their reviewer only when an extra answered, so the prompt with extras off is unchanged. Keep `Finding.reviewer` optional: it is saved with the pairing.

## Testing
`PairReviewTests` covers the loop's rules, reading Junie's output, merging and a round waiting on an extra. Nothing runs the real `junie`; check by hand with it installed.
