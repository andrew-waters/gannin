---
type: plan
status: done
summary: "One PullRequestStore keeps each PR once per org, as core fields plus a slot per store, so MetricsStore, WorkLogStore and OrgStore stop each saving their own copy."
issues: [andrew-waters/gannin#232]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Sync: one PR store

## Context

Stage 3b of `plans/2026-10-11-sync-overlap-and-cleanup.md` (parent andrew-waters/gannin#213). A merged PR
in the lookback was saved by `MetricsStore`, `WorkLogStore` and `OrgStore`, each in its own file and shape.

## Decisions

- **Core plus a slot per store.** `PullRequestStore` keeps `PullRequestCore` (what every fetch reads) and
  an extras slot each store owns (`MetricsExtras`, `WorkLogExtras`). The three stores read different
  commits and reviews, so one shared reviews or commits list would have changed their numbers.
- **Core fields are optional and merge one by one.** A fetch that doesn't read a field keeps what another
  store saved; a held `updatedAt` newer than the incoming one wins.
- **Each store's own file keeps coverage only**, with a `storedCount` so a cleared store can't leave a
  history claiming a range it no longer has.
- **Upgrade without a backfill.** The old metrics (format 4) and work log (version 4) files are read once
  and their PRs moved into the store. They have no `updatedAt`, so the change feed fetches each once if it
  next reports it changed.
- **Clearing is per slot**, so clearing the work log doesn't make metrics backfill.

## Tasks

- [x] `PullRequestStore`, core and slots, per-slot clear
- [x] `MetricsStore` reads and writes through it, migrating format 4
- [x] `WorkLogStore` reads and writes through it, migrating version 4
- [x] Tests: `PullRequestStoreTests`, `OrgJSONCacheTests.orgs`
- [x] `OrgStore`: a workload slot, the snapshot file listing PR IDs, `updatePullRequest` writing through the store (`OrgSnapshotCache`)
- [ ] Lower Spent for the PR sources: moved to andrew-waters/gannin#312, which fetches a PR once for every store that reads it

## Why it doesn't lower Spent

Each store still fetches a changed PR in its own shape and trusts only its own slot, so one store's fetch
never spares another's. Fetching once for every store is andrew-waters/gannin#312.

## Not in this plan

`IssueRecord`'s linked PRs (a pointer, not a PR shape), the pollers (andrew-waters/gannin#233).
