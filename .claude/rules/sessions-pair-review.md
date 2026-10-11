---
paths:
  - "Gannin/Sessions/PairReview*"
---
# Pair review

- Only an issue's own session gets it (`canPairReview`); never a helper, PR review, plan or Ask.
- Take each reviewer reply once (`lastReplyID`), or a round is counted twice.
- A reply with no JSON list is not a round (`listedFindings` is nil); `[]` means nothing found.
- Keep the last round's findings sent when `maxRounds` is hit.
- Do not flag the session when turns end during the loop (`isQuietForPairReview`); flag only on Stop or settling.
- After a limit or Stop, or with the setting off, answer a request "carry on"; after Settled start a fresh loop.
- Never post anything to GitHub from this loop.

## Testing
`PairReviewTests` covers the loop's rules.
