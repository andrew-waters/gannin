---
type: plan
status: Done
summary: A Hide drafts checkbox on the Pull Requests page's bar, kept per window, that leaves draft PRs out of that list only.
issues: [andrew-waters/gannin#475]
domains: [pull-requests]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Hide draft pull requests

## Context

Settings › General › Exclude draft PRs already drops drafts from the workload, so from the Pull
Requests page too, but it's app-wide (Dashboard, Inbox, counts) and nothing on the page shows it.
The Status menu can't exclude one status without ticking the other four.

## Approach

A per-window filter beside Hide mine, rather than a shortcut to the app-wide setting, so narrowing
the list never changes numbers on other pages. When the setting is on, the checkbox shows ticked and
disabled, pointing at the setting.

## Tasks

- [x] `hideDrafts` in `PullRequestFilters`, stored per window, counted by `isNarrowed` and cleared by Clear All
- [x] Hide drafts checkbox on the bar, disabled while Exclude draft PRs is on
- [x] Tests for the filter
- [x] Docs (Issues and Pull Requests) and CHANGELOG
