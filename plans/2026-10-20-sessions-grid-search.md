---
type: plan
status: In Review
summary: A search field on the sessions grid narrows it to sessions matching every word typed, across kind, reference, title, repo, branch and PRs, with the matching shared with the + popover's filter.
issues: [andrew-waters/gannin#419]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Sessions grid search

## Approach

The + popover already filters sessions by words, so the matching moves into `SessionSearch` and both use it. The grid's search text is `@State` on `SessionOverview`, so it starts empty each time the grid opens and can't leave a stale filter hiding sessions. ⌘F is a hidden button inside the grid, so it only exists while the grid shows. The last reply isn't searched: it changes constantly and would make results jump.

- [x] `SessionSearch` (kind, reference, title, repo, branch, PRs' repo, number and title), used by the grid and the popover.
- [x] Search field at the top of `SessionOverview`, ⌘F to focus, Escape to clear, a no-match state.
- [x] Test for `SessionSearch`.
- [x] Docs (`agents/work-on-this.md`) and CHANGELOG.
