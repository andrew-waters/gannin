---
paths:
  - "Gannin/Sync/**"
  - "Gannin/GitHub/**"
  - "Gannin/Auth/**"
---

# Fetching, auth and the rate limit

## Auth and API
- Token is in the keychain (`Keychain`, by service and account; sandboxes' credentials use another service). OAuth client ID is in `GitHubOAuthConfig` (`DeviceFlow.swift`).
- All GitHub calls are reads except the confirmed writes: project board writes (`ProjectFields.swift`, need the `project` scope), `InvestmentWrites.swift`, review requests (`ReviewRequests.swift`, REST), harness commits (`HarnessWrites.swift`). Every write is confirmed first. Mutations skip the injected `rateLimit` field.
- Raw GraphQL shapes stay private to `Queries.swift` and are mapped onto models.
- Every query also asks for `rateLimit`, injected in `GitHubAPI.send`. The budget lives on `AuthStore.rateLimit`; each query's cost is charged to the running `SyncStep` via the `SyncContext.step` task-local and to `APIUsage`.

## Budget and holding off
- GraphQL has 5,000 points/hour per token; only the Actions sync uses REST, with its own budget (`AuthStore.restRateLimit`).
- The reserve (`sync.reserve`, default 500) is what automatic fetches leave for manual ones: `RateLimit.isLow` is under it. Automatic refreshes and syncs hold off when low and there is cached data to show; pollers use `holdsOff`.
- A 403/429 with none left, `Retry-After`, or GraphQL `RATE_LIMITED` (`RateLimit.refusal`) throws `APIError.rateLimited` and pauses every request of that kind until told (`AuthStore.pausedUntil`, `restPausedUntil`, checked by `GitHubAPI` before sending); REST still waits out a minute or less once.
- Reads (GraphQL and REST) go through `RequestLimiter`: at most 8 in flight so parallel searches don't trip GitHub's secondary limit; writes skip the queue. Syncs are the background lane and leave 2 slots free; a hand-started read (`DetailStore.load`, the review tab's fetch) sets `RequestLimiter.lane` to interactive and is served first. A cancelled request leaves the queue at once.
- `APIUsage` (Application Support/APIUsage.json, last day) records each query's cost and each REST request by source: the `UsageContext.source` task-local set with `chargingTo(_:_:)`, else the sync run's kind, else Other. Mutations count a point each. Fetchers that serve a user action should set `chargingTo`.

## Sync settings
- Every source is a `SyncSource` (`SyncSettings.swift`): `sync.<source>.off` where it can be turned off, `sync.<source>.interval` (seconds), read through `SyncSettings.isOn`/`interval`/`isDue`, never fixed ages. Off means not fetched at all, Refresh included. The workload (and its members/teams/full search), every open issue, the harness and while-checks-run only space out; a sub-part is disabled with its parent.
- Pages fetch what they show when older than its interval, not on a timer. Pollers (review requests, watched reviews at a 30 s tick; session PRs) run on their own intervals.
- A page whose source is off says so with `.syncOffNotice`.
- `SyncRun.track` drives `SyncActivity`: one `SyncStep` per GitHub query (metrics backfill one per week). `GitHubAPI.counts` runs one aliased counts query first so every step's total, and weighted progress, is known up front.
- `SyncSettings.migrate` moves old `reviewCheckMinutes` across once.

## Storage
- User-entered data (people's dates, org settings, hidden items, stars) is SwiftData on this device (`UserDatabase.swift`, `UserData/Gannin.store`), no iCloud; stores keep data in memory and write through. No unique constraints (the store once synced via CloudKit), so duplicates are merged on load: newest wins, time off merges by UUID. GitHub caches are local JSON. Team data lives in harnesses (see harness rules). No entitlements beyond hardened runtime; the app is not sandboxed while sessions are prototyped (they run git, gh, claude as the user).
