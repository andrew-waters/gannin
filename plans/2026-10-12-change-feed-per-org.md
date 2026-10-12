---
type: plan
status: In progress
summary: One cheap search per org says which PRs and issues changed, kept as an in-memory log the workload, issue history and work log read instead of each running a changes search, with each store's own search as the fallback.
issues: [andrew-waters/gannin#231]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Sync: one change feed per org

## Context

Stage 3a of `plans/2026-10-11-sync-overlap-and-cleanup.md` (parent andrew-waters/gannin#213). `OrgStore`,
`IssueStore` and `WorkLogStore` each ran an "updated since" search every cycle, so the same PRs and
issues were found three times, each paying the heavy node shape.

## Decisions

- **A retained log, not a shared cursor.** The stores sync on different schedules and keep their own
  cursors (`changesSince`, `syncedAt`, `fetchedAt`). `ChangeFeeds` keeps the last six hours of updates
  per org (id, kind, state, repo, `updatedAt`) in memory; each store asks for entries after its own
  cursor. In memory means no cache format changes, and each store falls back once after a relaunch.
- **Fallback is the store's own search, unchanged.** When the feed's search failed, hit the 1000
  result cap (the feed empties and restarts from that time), or starts after the store's cursor.
  `ChangeFeed.plan` decides, as a pure function.
- **Savings come from skipping.** A store skips an entry whose `updatedAt` it already holds, so
  `IssueRecord` and `WorkLogPullRequest` gain an optional `updatedAt` (no cache version bump: nil
  just means fetched again once). `OrgStore` still refetches open PRs, whose checks change without
  `updatedAt` moving, but skips merged PRs and issues already held, and drops items the feed shows
  closed without fetching them.
- **One run at a time.** Concurrent callers (Refresh starts every store together) await one task, and
  a run under 15 seconds old is reused.
- **Cost is its own ledger row**, `SyncSource.changeFeed` ("Change feed"), so Settings › Sync › Spent
  shows it apart from the three sources it serves.
- Outside repos: the feed covers every readable one; restarting when the set changes, since it has no
  history for one just added. Stores only take the ones they already have a baseline for.

## Tasks

- [x] `ChangeFeed`, `ChangeFeeds`, `changeEntries` and `nodes(ids:)`
- [x] `OrgStore` snapshot, `IssueStore` and `WorkLogStore` take their changes from it
- [x] Tests: `ChangeFeedTests`
- [x] Docs, rules, CHANGELOG
- [ ] Compare Spent per source before and after in the running app

## Not in this plan

`MetricsStore`'s merged top-up, `IssueStore.deepSync`'s id-only search (the same shape as the feed, a
follow-up), the shared PR store (andrew-waters/gannin#232) and the pollers (andrew-waters/gannin#233).
