---
paths:
  - "Gannin/Sessions/PairReview*"
---
# Pair review

- Only an issue's own session gets it (`canPairReview`: not a helper, PR review, plan or Ask). The start script writes `ready-for-review` into `.gannin/` (`SessionScript.readyForReview`, allowed in its settings); the brief tells claude to run it with a note once committed and built, before a PR is marked ready.
- The script writes a token and note to `review-request` in the session folder; the poll (and `readRemote`) reads it beside the hook files. A new token (`CodeSession.reviewRequest`) starts a background reviewer helper (`reviewPrompt` with the note) or asks the existing one to look again.
- A round is the reviewer's reply ending in a JSON list (`SessionTranscript.listedFindings`; nil without one, so `[]` means nothing found). Each reply is taken once (`lastReplyID`, `pairRoundRead` from `store`). Findings are pasted into the working session when it waits, else at turn end (`pendingPrompts`).
- `CodeSession.pairing` ends Settled when a round finds nothing, at `maxRounds` (3; the last round's findings are still sent), or by Stop, which flags the session and ends the reviewer. Turn endings don't flag meanwhile (`isQuietForPairReview`).
- After a limit or Stop, or with the setting off, a request is answered "carry on"; after Settled it starts a fresh loop.
- Nothing is posted to GitHub.
