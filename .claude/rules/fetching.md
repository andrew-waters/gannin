---
paths:
  - "Gannin/Sync/**"
  - "Gannin/GitHub/**"
  - "Gannin/Auth/**"
---

# Fetching, auth and the rate limit

## Auth and writes
- Keep the token in the keychain only (`Keychain`, by service and account); sandboxes use a different service.
- All GitHub calls are reads except the listed writes (`ProjectFields.swift`, `InvestmentWrites.swift`, `ReviewRequests.swift`, `HarnessWrites.swift`). Every write must be confirmed by the user first, and mutations must skip the injected `rateLimit` field.
- Keep raw GraphQL shapes private to `Queries.swift` and map them onto models.
- Board reads and writes need the `project` scope.

## Budget
- GraphQL is 5,000 points an hour per token; only the Actions sync uses REST, with its own budget (`AuthStore.restRateLimit`).
- Automatic fetches must hold off when `RateLimit.isLow` (under `sync.reserve`) and cached data exists, so manual actions keep budget. Pollers check `holdsOff`.
- On a refusal (`RateLimit.refusal`) throw `APIError.rateLimited`; `GitHubAPI` checks `AuthStore.pausedUntil` / `restPausedUntil` before sending, so never bypass it.
- Reads go through `RequestLimiter` (a cap on in-flight requests avoids GitHub's secondary limit); writes skip it. A hand-started read must set the interactive lane so it isn't queued behind syncs.
- REST GETs send `If-None-Match` with the ETag of the last answer for the URL (`RESTCache`, in memory, 20 MB); a 304 returns what was kept and costs nothing against the REST budget. That serves jobs, the harness tree and a PR's files, comments and diff. A query whose URL changes every time, as the run lists' `created=` range ending at now does, passes `cached: false` to `rest`, so it isn't stored and doesn't push out entries that can hit. `AuthStore.signOut` empties the cache; it isn't keyed by account.
- Fetchers serving a user action should set `chargingTo(_:_:)` so `APIUsage` attributes the cost; otherwise it goes to the sync run's kind or Other.

## Change feed
- `OrgStore`, `IssueStore` and `WorkLogStore` ask `ChangeFeeds` (one in-memory log per org) what changed and fetch those node IDs in their own shape, never running their own "updated since" search while it can answer. Never advance one shared cursor instead of keeping the log: stores sync on different schedules, and one that last ran an hour ago would miss what a cursor had moved past.
- A store falls back to its own changes search when `ChangeFeed.plan` says so: the feed's search failed, hit GitHub's 1000-result cap (the feed empties and restarts from now), starts after the store's cursor (a fresh launch), or doesn't cover every outside repo the store needs. Keep that search working. The feed's outside repos only grow (callers' needs are unioned), so stores that see different readable repos don't reset each other's feed; `AuthStore.signOut` clears it.
- A store skips an entry whose `updatedAt` it already holds, so keep `updatedAt` on what it stores. `OrgStore` still refetches open PRs, whose checks change without `updatedAt` moving.
- Await the feed only after the store's `syncing` flag is set, or a second sync can start while it runs. The feed's cost is charged to `.changeFeed`.

## Shared PR store
- PRs live in `PullRequestStore` (core fields plus one extras slot per consumer: metrics, work log, workload), written through `merge` and changed through `update`, never kept in a store's own cache file. A copy beside it can drift from the one `updatedAt` is compared against.
- A store's own file keeps its coverage (what range it has fetched), not the PRs. It must be dropped when the store holds fewer of its PRs than it saved (`storedCount`), or it would claim coverage the PRs no longer back.
- Clear a store's own part with `clear(_ slot:)`, never the whole store: clearing the work log mustn't force the metrics to backfill. Core fields merge one by one (`PullRequestCore.merged`) because a fetch may not read them all; keep new core fields optional.
- `OrgSnapshot`'s file lists its PRs' IDs; load and save it through `OrgSnapshotCache`, never by decoding it, or its PRs come back empty. The in-memory snapshot keeps full `PullRequest` values because views read `OrgStore.snapshots` and `PullRequestStore` isn't observable. An open PR is fetched again at the same `updatedAt`, so a fetch at the held stamp must replace the slot (`newer` does), and `OrgStore.updatePullRequest` writes through `OrgSnapshotCache.update`, which saves once a burst ends.
- Each slot records the `updatedAt` it was fetched at (`MetricsExtras.updatedAt`); a store's skip check reads that, never `core.updatedAt`, which is the newest any store saw and would hide a stale slot from the store that holds it.
- A PR carried over from an old cache has no `updatedAt`; it is fetched again once when the feed reports it changed. Don't invent one.

## Shared issue store
- Issues live in `SharedIssueStore` (core fields plus a workload slot and a history slot), written through `merge` and changed through `IssueStore`'s `record*` methods, never kept in `OrgSnapshot`'s or `IssueHistory`'s own file: a copy beside it can drift from the one `updatedAt` is compared against. Both files list issue IDs (`storedIssueIDs`, `storedIDs`); load them through `OrgSnapshotCache` and `IssueStore.loadCached`, never by decoding them, or their issues come back empty.
- Write a board field, label or assignee edit through `IssueEdits`, which changes the issue and every cached board together. Calling `IssueStore` and `ProjectStore` separately lets one miss the other.
- Each slot records the `updatedAt` it was fetched at; a store's skip check reads that, never `core.updatedAt`. The core merges field by field, and a label or person from a fetch that reads names only keeps the colour or avatar another fetch saved.
- Only a label edit writes `core.labels` and only an assignee edit writes `core.assignees`; other local edits write the history slot alone, because the history's in-memory record can be older than a core the workload has refreshed. `OrgSnapshotCache.save` merges only issues whose workload part differs from the held one, so an issue a changes-only refresh carried over can't undo a label edit.
- Clear a store's own part with `clear(_ slot:)`, never the whole store. The workload leaves out an issue the history has since seen closed, so a closed issue is not a missing one.

## Sync settings
- Read intervals through `SyncSettings.isOn` / `interval` / `isDue`, never fixed ages. Keys `sync.<source>.off` and `sync.<source>.interval` are stored; don't rename them.
- Off means not fetched at all, Refresh included. Sources that can't be off (workload, harness) only space out. A page whose source is off must show `.syncOffNotice`.
- Pages fetch when older than their interval, not on a timer.
- Drive progress through `SyncRun.track`, one `SyncStep` per GitHub query.

## Storage
- Never root a file at `URL.applicationSupportDirectory`; use `AppPaths.support` (or `AppPaths.own`). The demo build points `AppPaths` at its own folder, and a store that bypassed it would show or overwrite the real app's data (`AppPathsTests` fails on it).
- User-entered data is SwiftData on this device (`UserDatabase.swift`), no iCloud. Records have no unique constraints (the store once synced via CloudKit), so keep merging duplicates on load: newest wins, time off by UUID.
- Team data belongs in the harness, not here; stars, hidden items and app settings stay local.
- The app has no entitlements beyond hardened runtime and isn't sandboxed (sessions run git, gh and claude as the user).

## Testing
- `ChangeFeedTests` covers the feed's plan, merging, what the workload snapshot takes from it and `ChangeFeeds`' sharing of a run (with a stubbed search); `RequestLimiterTests`, `BudgetGateTests`, `ParallelSearchesTests`, `MergedSearchTests`, `OrgJSONCacheTests`, `PullRequestStoreTests`, `PullRequestMigrationTests`, `OrgSnapshotCacheTests`, `SharedIssueStoreTests` cover limiting, budget gating and search/cache handling. Auth and sync settings have none; check by hand.
