---
type: plan
status: In Review
summary: Start Claude's review when a review is requested, watch reviewed PRs and review them again when they change, and list what happened while you were away.
issues: [andrew-waters/gannin#3]
domains: [sessions, reviews]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Auto review when requested

## Context

A requested review waited until it was opened in Gannin. `EngineerWatch` already checked GitHub in the
background at an interval the user picks (Settings > General, every 1, 5, 15 or 30 minutes, or never), so
part 2 of the issue needed no new work beyond saying watched PRs are checked too.

## Decisions

- Every setting is the user's own, on this Mac. The per-org override sits in the org's Settings > Harness,
  beside the other per-org Claude Code choices, and stores `on`, `off` or the default.
- Automatic reviews can be posted to GitHub, but only when the user turns that on, only as COMMENT reviews,
  and marked as written by Claude. Approving and requesting changes stay the user's.
- "Comments" are conversation comments, reviews with words and line comments. The user's own and bots' don't
  count, so a posted review never triggers another.
- A watched PR is reviewed again once nothing new has come for two minutes and its reviewer isn't busy.
  Watching stops when it's merged or closed, or when turned off on the review.
- At most two automatic reviews run at once; more wait for a later check.
- "Seen" means the review's tab has been looked at. The catch-up is the Inbox's While you were away section.

## Tasks

- [x] Settings: Review requests automatically, Watch reviewed pull requests, Post automatic reviews (General),
      and the org's override (Harness)
- [x] Start a review in the background when a new request is found (`startAutomaticReview`)
- [x] Watch for changes on a finished review, on by default, toggled on the review
- [x] Check watched PRs after each `EngineerWatch` pass and review again after a quiet period
- [x] Post automatic reviews as comments when enabled, sharing comment building with Post Review
- [x] Catch-up log (`ReviewActivity`) and the Inbox's While you were away section
- [x] CLAUDE.md
- [ ] Try it end to end in the app: a request, a push, a comment, a merge
