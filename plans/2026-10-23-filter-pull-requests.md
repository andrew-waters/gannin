---
type: plan
status: In Review
summary: The Pull Requests page's filter menus can hide the values picked instead of showing only them, a Checks menu narrows by CI, and Hide reviewed leaves out PRs the viewer has reviewed and not been asked to again.
issues: [andrew-waters/gannin#484]
domains: [pull-requests]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Filter pull requests by repo, author, review state and status

## Context

The Pull Requests page already had Author, Reviewer, Status and Repository menus (several values
each, any matching), Hide mine, Hide drafts and Open, Merged or All, all kept per window in scene
storage, so they come back after a relaunch. Status already meant Draft, Needs review, Changes
requested, Approved or Merged. What was missing: a way to hide a repo or an author rather than
show only them, a way to hide what the viewer has already reviewed, and CI.

## Decisions

- Exclude is a mode per menu, not separate menus: each PR menu ends with a Hide These switch, and
  while it's on the ticked values are hidden instead of shown. The label reads "Repository: not
  api". All five PR menus get it; `FilterMenu` takes it as an optional binding, so the issue pages
  are unchanged. A key in exclude mode with nothing ticked doesn't narrow anything.
- Reviewed means the viewer has left a review and hasn't been asked again since, so a re-request
  brings the PR back. That is the Reviewers column's own reading (`reviewerEntries`).
- Checks is its own menu: Passing, Failing, Running and No checks, from the PR's latest commit as
  fetched, or the drawer's fresher detail when there is one (as the Inbox reads it).
- Choices stay per window in scene storage, as the existing filters are.

## Tasks

- [x] `excluding` and `hideReviewed` in `PullRequestFilters`, stored per window, counted by `isNarrowed` and cleared by Clear All
- [x] Hide These switch in `FilterMenu`, opt-in, used by every PR menu
- [x] Checks key and menu, reading fresher checks from `DetailStore`
- [x] Hide reviewed checkbox on the bar
- [x] Tests for exclusion, Hide reviewed and Checks
- [x] Docs (Issues and Pull Requests) and CHANGELOG
