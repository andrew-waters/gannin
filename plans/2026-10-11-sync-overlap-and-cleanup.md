---
type: plan
status: in-progress
summary: "Remove the overlapping GitHub fetches between stores and pollers, fix the sync correctness bugs found on the way, and consolidate the copy-pasted sync plumbing, in stages."
issues: [andrew-waters/gannin#213]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Sync: remove overlapping fetches and consolidate the code

Gannin's sync has no shared scheduler or fetch layer. Each store (`OrgStore`, `MetricsStore`,
`IssueStore`, `WorkLogStore`, `ActionsStore`, `ReleaseStore`, `ProjectStore`, `DetailStore`,
`HarnessStore`) and each poller owns its fetch, cache, interval and rate-limit check. This plan
lists what's there, what's duplicated or wasteful, and the stages to fix it. Each stage ships as its
own pull request.

Findings come from reading the code, not running it. V is verified in the code, I is inferred.

## How sync works today

- `Sync/SyncSettings.swift`: each source has an off switch and an interval, read through `isOn` and
  `isDue`.
- `Sync/SyncActivity.swift`: `SyncRun` and `SyncStep` track progress. `SyncRun.track` sets the
  task-local `SyncContext.step` so `GitHubAPI.send` can charge a query's cost to the step.
- `Sync/APIUsage.swift`: the cost ledger by source (`chargingTo`, else the run's kind, else Other).
- `GitHub/GitHubAPI.swift` `send`: injects `rateLimit`, pauses every request of that kind on
  403, 429 or `RATE_LIMITED`, and retries 502 to 504. `AuthStore.shouldHoldOff` is advisory: each
  caller has to check it.
- `Views/SyncPanel.swift` `OrgRefresh`: Refresh forces every store in parallel.
- Stores, each caching JSON in Application Support: `OrgStore` (snapshot, merged incrementally,
  30 second loop while an org window is open), `MetricsStore`, `IssueStore`, `WorkLogStore`,
  `ActionsStore` (REST), `ReleaseStore`, `ProjectStore`, `DetailStore`, `HarnessStore` (head commit,
  tree, then changed blobs).
- Pollers: `EngineerWatch` (30 second tick), `SessionStore.watchPullRequests` (1 to 2 minutes),
  `SessionStore.poll` (every second), `RoutineScheduler` (15 seconds), git status (10 seconds) and
  fetch (5 minutes), session Changes, Ask files and Planning refresh (2 to 15 seconds).
- User data: SwiftData `UserDatabase` (write-through, duplicates merged on load); team data staged
  in `HarnessTeamStore.pending`, three-way merged and committed with `createCommitOnBranch`.

## Duplication (V)

1. Cache load, save, encoder and decoder are copied across about nine stores.
2. The bounded-parallel task group (concurrency 4) appears five times; `IssueStore.fetch` and
   `WorkLogStore.fetch` are near-identical.
3. `WorkLogStore.Tally` and `IssueStore.IssueTally` are identical. `weeks` is byte-identical in
   `IssueStore` and `WorkLogStore`, with two more week chunkers beside them (mixing
   `Calendar.current` and the metrics calendar).
4. The overlap-window top-up is written four times, and search timestamp formatting four times.
5. The `isOn && isDue && !shouldHoldOff` gate plus its catch ladder is in about 12 places, and about
   eight hand-rolled `while … sleep` loops do polling.
6. Four near-identical `outside*` functions in `Queries.swift`.

## Overlapping fetches (V)

- A PR is fetched in four shapes (`OrgStore`, `MetricsStore`, `WorkLogStore`, `IssueRecord`) with no
  shared cache; a merged PR in the lookback is downloaded by three stores.
- Issues: `OrgStore` fetches a light version, `IssueStore` a heavy one, `ProjectStore` board items
  and `IssueStore.deepSync` more; open issues are stored twice on disk.
- Three "changed since" searches run every cycle.
- `EngineerWatch.engineerWork`, the session PR watch and the watched-review query re-fetch PRs
  already in `OrgStore`'s snapshot, and session PRs are fetched one session at a time.

## Inefficiencies

- (V) A forced Refresh refetches every open issue in the heaviest shape, defeating the hourly gate
  (`IssueStore.swift:65`).
- (V) The open-issue fetch is capped at 1000 results and then removes every open issue not returned,
  so with more than 1000 open, older ones silently disappear. WorkLog's weekly searches can
  truncate the same way.
- (V) The Metrics top-up re-downloads one to two days of merged PRs each sync (the search is
  day-granular).
- (V) `openedCounts` makes one query per week although `GitHubAPI.counts` batches searches.
- (V) No `If-None-Match` on REST; Releases has no incremental path; `ProjectStore` refetches the
  whole item list per filter.
- (V) Hold-off is skipped by `DetailStore`, `loadLinked` and `loadBranches`; one Refresh can run more
  than 16 requests at once; only `HarnessStore` dedupes in-flight requests.
- (V) No network poller checks whether the app is active; git fetch runs every 5 minutes in the
  background.
- (V) `SessionStore.poll` reads 5 to 6 files per session every second on the main actor.
- (V) Disk churn: `RoutineStore` rewrites `state.json` every 15 seconds; `SessionStore.update`
  rewrites every session per call; `OrgStore.updatePullRequest` rewrites the whole snapshot;
  `Details.json` is rewritten per item opened; `HarnessStore` rewrites its index with an unchanged
  head.
- (V) All JSON encode, decode and writes run on the main actor; `HarnessStore.init` decodes every
  cached index at launch.
- (V) `HarnessTeamStore.data(for:in:)` keys its cache on `fetchedAt`, so every no-op refresh
  re-parses about 15 files.
- (V) `harnessTree` ignores `truncated`; a commit queries the head twice.
- (V) `UserDatabase` reloads everything on each app activation and swallows save errors with `try?`.
- (I) The CloudKit remote-change observer in `UserDatabase` is probably dead code; metrics, issues
  and work log don't refresh on their own interval unless a page opens.

## Stages

Each stage is its own pull request, with a CHANGELOG `[Unreleased]` entry and, for anything
user-visible, its docs page in the same pull request (for example Settings › Sync). A cache format
change bumps the store's version, which forces a backfill, so batch those and say so in the release
notes.

### Stage 0: confirm the overlap (no code change)

Diff the field sets of the four PR shapes and the issue shapes (`Queries.swift:754`,
`MetricQueries.swift:151`, `WorkLogQueries.swift:98`, `IssueQueries.swift:123`) and list which
consumers need which fields. Record the real per-source cost from Settings › Sync › Spent as the
baseline. This decides how far Stage 3 goes.

### Stage 1: correctness and cheap wins

- A forced Refresh skips the full open-issue refetch unless `.openIssues` is due.
- Detect the 1000-result cap before `IssueStore` removes missing open issues, splitting the search
  (by repo or `created:` range) when it's hit. Same check for WorkLog's weekly searches.
- The Metrics top-up uses timestamped `merged:>=` (`MetricsStore.swift:57`,
  `MetricQueries.swift:52`).
- Batch `openedCounts` through `GitHubAPI.counts`.
- `HarnessTeamStore.data(for:in:)` drops `fetchedAt` from its cache key, `harnessTree` checks
  `truncated`, and the harness index isn't saved when the head is unchanged.

### Stage 2: shared plumbing (no behaviour change)

Add helpers in `Gannin/Sync/` and move the stores onto them one at a time:

- `JSONCache<T>`: directory, versioned load, save and the shared iso8601 coders, with writes off the
  main actor and rapid saves coalesced.
- A generic bounded task group (from `ReleaseStore.eachRepo`) and one app-wide request limiter, so a
  Refresh can't exceed a set number of concurrent requests.
- One week chunker on a single calendar, and one search timestamp formatter.
- `BudgetGate` (`isOn`, `isDue`, `shouldHoldOff`, force bypass, app active) and a shared wrapper for
  the `syncing` flag and catch ladder, replacing the gates and poll loops.
- In-flight coalescing in `GitHubAPI.send`: identical query and variables await the same task.

Tests: Swift Testing for the helpers; the existing store tests pass unchanged.

### Stage 3: remove the overlapping fetches

Each sub-stage ships alone. Stop when Stage 0 says the next isn't worth it.

- **3a. One change feed per org.** One cheap search (node ID, `updatedAt`, state, repo, kind) for PRs
  and issues updated since a shared cursor, run once per cycle. `OrgStore`, `IssueStore`,
  `WorkLogStore` and `MetricsStore` use it to decide what to fetch in their own shape, replacing
  their three "changed since" searches. Shapes stay as they are.
- **3b. A shared PR core store**, keyed by node ID, holding the fields `OrgStore`, `MetricsStore`
  and `WorkLogStore` share (state, dates, author, reviews, commits). Consumers read from it and
  fetch only their extra fields, migrated one at a time, starting with `MetricsStore`'s merged PRs
  where the lookback covers them.
- **3c. Pollers read the shared cache.** `EngineerWatch.engineerWork`, `watchedPullRequests` and
  `sessionPullRequests` use the core store when `updatedAt` matches and fetch only the volatile parts
  (checks, threads, comments) in one aliased by-node-ID query for all sessions, replacing the
  per-session loop.
- **3d. One copy of open issues.** `OrgSnapshot.issues` and `IssueHistory.issues` become one source,
  and `ProjectStore` item field values merge through one write path instead of the hand-merging in
  `IssueStore.record*`.

Risks: cache version bumps and re-backfills; stores that now depend on the feed's ordering;
`OrgStore.updatePullRequest`'s optimistic writes must go through the shared store. Tests: feed
merging and cache hit and miss cases against fixture responses, and `APIUsage` totals compared
before and after.

### Stage 4: polling and persistence

- `SessionStore.poll`: watch the hook files (FSEvents or `DispatchSource`), or at least read them off
  the main actor and slow down when the app is inactive.
- Gate the 5-minute `git fetch`, session Changes, Ask files and Planning refresh on `NSApp.isActive`
  and the tab being visible.
- Stop the 15-second `RoutineStore` write, save once per batch in `SessionStore.update`, and stop
  rewriting the whole snapshot per `updatePullRequest` and `Details.json` per item.
- REST `If-None-Match` for Actions, the harness tree and stargazers.

## Verification

`xcodegen generate`, then `xcodebuild test` as in CLAUDE.md, then `scripts/relaunch.sh` and watch
Settings › Sync › Spent for the change in cost per source.
