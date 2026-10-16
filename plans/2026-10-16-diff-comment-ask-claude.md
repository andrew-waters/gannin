---
type: plan
status: In Review
summary: The comment box opened from a review diff line gets an Ask Claude button that sends the question, with the surrounding diff lines, to the review's own Claude and opens its conversation.
issues: [andrew-waters/gannin#369]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Ask Claude from a review diff comment

## Approach

- [x] `ReviewCommentEditor` gets Ask Claude (⌥⌘↩) beside Add; disabled when the text is empty or the review's Claude isn't running.
- [x] `DiffQuestion.message` wraps the question with the file, the line (old side when removed) and five diff lines either side, the line marked.
- [x] `ReviewDiff` and `DiffRow` take an `ask` closure that reuses the Overview's route (`sessions.submit`, then show the conversation); nil when the session isn't running.
- [x] Test for the message; docs (`agents/reviews.md`) and CHANGELOG.

## Decisions

- The answer shows in the existing conversation with the reviewer rather than a reply in the popover or a new session.
- Not available once the review has finished; resuming it stays with the conversation toggle.
