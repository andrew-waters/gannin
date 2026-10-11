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

## Sync settings
- Read intervals through `SyncSettings.isOn` / `interval` / `isDue`, never fixed ages. Keys `sync.<source>.off` and `sync.<source>.interval` are stored; don't rename them.
- Off means not fetched at all, Refresh included. Sources that can't be off (workload, harness) only space out. A page whose source is off must show `.syncOffNotice`.
- Pages fetch when older than their interval, not on a timer.
- Drive progress through `SyncRun.track`, one `SyncStep` per GitHub query.

## Storage
- User-entered data is SwiftData on this device (`UserDatabase.swift`), no iCloud. Records have no unique constraints (the store once synced via CloudKit), so keep merging duplicates on load: newest wins, time off by UUID.
- Team data belongs in the harness, not here; stars, hidden items and app settings stay local.
- The app has no entitlements beyond hardened runtime and isn't sandboxed (sessions run git, gh and claude as the user).

## Testing
- `RequestLimiterTests`, `BudgetGateTests`, `ParallelSearchesTests`, `MergedSearchTests`, `OrgJSONCacheTests` cover limiting, budget gating and search/cache handling. Auth and sync settings have none; check by hand.
