---
type: plan
status: In Review
summary: Hold every automatic review Claude would approve, comments and all, so the user's approval posts them once as one review.
issues: [andrew-waters/gannin#465]
domains: [sessions, reviews]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Ready to approve

## Context

Most of the issue was already there: automatic reviews never approve, and `readyForApproval` feeds the
Inbox's Ready for your approval, the Dashboard's Act now and a notification. The gap was
`holdsForApproval`, which held an approve verdict only with no findings. With Post automatic reviews on,
an approve with findings went up as a COMMENT, and the user's approval then posted the summary and
off-diff findings again (the duplicate check covers inline comments only).

## Decisions

- Keep the name Ready for your approval: the Inbox, notifications and docs already use it.
- An approve verdict is held, whatever its findings, while the PR is `readyForApproval`. One that isn't
  ready (failing checks, conflicts) is held only with nothing to say, else its findings are posted as a
  comment, since it never reaches the queue. Comment and request changes reviews keep posting as they do.
- Signing off stays Post Review: the body can be edited, findings dismissed, or the kind changed to
  Comment. No new GitHub write.
- Answered by what's there: new commits take the PR out of the queue until it's reviewed again; merged,
  closed or no longer requested drops it; held reviews persist with the session.

## Tasks

- [x] Hold every approve verdict in `postAutomatically`, noting how many findings are held
- [x] Show the held finding count in the Inbox row and the Dashboard's Act now
- [x] Tests for `holdsForApproval` and `heldFindings`
- [x] Docs (Auto review, Settings › General), rule, CHANGELOG
- [ ] Try it in the app: an automatic review that would approve with comments, then approve it
