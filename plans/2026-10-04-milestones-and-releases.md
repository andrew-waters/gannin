---
type: plan
status: Done
summary: A Releases page under Delivery showing the org's milestones, grouped by title across repos, with GitHub's progress and the issue history's, and its GitHub Releases, linked to the milestone they ship.
issues: [andrew-waters/gannin#9]
domains: [delivery]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Milestones and releases

## Context

Issues already carry their milestone's title (`IssueRecord.milestone`), which Views, investment rules and
session briefs read, but Gannin never fetched milestones themselves (due date, state, counts) or GitHub
Releases, so nobody could see in Gannin what a milestone or release holds or how far along it is.

## Decisions

- Releases are GitHub Releases (tag, name, notes, draft, pre-release, latest). A milestone is linked to the
  release whose tag or name matches its title, ignoring case and a leading `v`, in one of its repos.
- Progress is GitHub's own: closed issues out of all issues in the milestone, which doesn't depend on how
  far back the issue history reaches. From the issue history it also shows how many are in progress (the
  workflow's statuses) and how many have a merged PR.
- Milestones with the same title in different repos are one row, the counts added up and each repo's
  milestone under it.
- A new Releases page under Delivery (`WorkloadTab.releases`) with Milestones and Releases in its toolbar.
  A milestone and a release each have a page of their own. The issue lists get a Milestone filter.
- Read-only: nothing is written to GitHub. Creating milestones or assigning issues to them can follow,
  confirmed first like every other write.
- Sync: one paged GraphQL query over the org's non-archived repos (each repo's open milestones, the ten
  most recently closed, and its latest releases), cached as JSON in Application Support/Releases, fetched
  again after 10 minutes, only once the page has been opened for the org; Refresh includes it from then
  on. It's one step of its own sync run (Releases). Excluded repos no project names are skipped.

## Tasks

- [x] `ReleaseStore` and its query, with the sync run, Refresh and Storage settings
- [x] Releases page: Milestones and Releases, with search and closed milestones on request
- [x] Milestone page: progress per repo, linked release, description, its issues from the history
- [x] Release page: notes, badges, linked milestone
- [x] Milestone filter on the issue lists
- [x] CLAUDE.md
