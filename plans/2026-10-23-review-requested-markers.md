---
type: plan
status: In Review
summary: Mark each reviewer on a PR as asked and waiting or by their latest review, show teams asked, and say None when nobody is on it.
issues: [andrew-waters/gannin#468]
domains: [workload, pull-requests]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Show whether review has been requested

## Context

The PR drawer already marked each reviewer (asked and waiting, or their latest review), but the Reviewers
column on Pull Requests and Who on the Inbox's Your pull requests stacked requested reviewers and past
reviewers together with nothing to tell them apart, and a blank cell for nobody. Team review requests
weren't fetched: `reviewRequests` read `... on User` only.

## Decisions

- Badges on each face, in the drawer's symbols and colours, rather than a second column: the column stays
  narrow and the drawer and table read the same.
- Those still to act (people asked, then teams asked) come first; someone asked again after reviewing is
  waiting, not reviewed.
- Teams are fetched as `combinedSlug` into an optional `requestedTeams`, so caches written before it still
  decode, and count as a reviewer for the No Reviewer filter.
- Sorting the column puts PRs waiting on the most reviewers first.

## Tasks

- [x] `PullRequest.reviewerEntries` and `requestedTeams`, fetched and kept in `PullRequestStore`
- [x] `ReviewerStack` for the Pull Requests column and the Inbox's Who; the drawer uses the same entries
      and lists teams
- [x] Tests for `reviewerEntries` and the No Reviewer filter
- [x] Docs (Issues and Pull Requests, App tour), CHANGELOG
- [ ] Try it in the app: a PR with a team asked, one with someone asked again, one with nobody
