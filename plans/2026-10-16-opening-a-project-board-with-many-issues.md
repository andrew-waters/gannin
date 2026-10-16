---
type: plan
status: in-progress
summary: "Gannin hangs when a project board with many issues is opened (andrew-waters/gannin#388). The cause is unconfirmed: the plan reproduces and profiles the hang first, then fixes the dominant main-thread cost so the window stays interactive."
issues: [andrew-waters/gannin#388, andrew-waters/gannin#390, andrew-waters/gannin#391]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-16
requirement: requirements/opening-a-project-board-with-many-issues.md
---

# Opening a project board with many issues no longer hangs the app

Gannin hangs when a project board with many issues is opened (andrew-waters/gannin#388). The cause is unconfirmed: the plan reproduces and profiles the hang first, then fixes the dominant main-thread cost so the window stays interactive.

## Requirement

In full in [requirements/opening-a-project-board-with-many-issues.md](../requirements/opening-a-project-board-with-many-issues.md).

**Problem:** Opening a project board that has a lot of issues freezes the app, then it recovers. Unconfirmed per the issue: the issue count that triggers it, whether the time goes in fetching, storing or drawing, which Gannin/macOS versions, and whether it affects every large board.

**Goal:** Opening a large board leaves the app responsive.

**Who it's for:** Anyone using Gannin with a large project board.

**Scope:**

1. Reproduce the hang on a real large board and record the triggering issue count
2. Find where the time goes: fetching, storing or drawing
3. Stop opening the board from freezing the app

**Out of scope:**

- Making the board open faster overall
- Progressive or streamed loading of issues

**Acceptance criteria:**

- **R1** When a large project board is opened, the hang shall be reproduced and the triggering issue count recorded on andrew-waters/gannin#388.
- **R2** While the board that reproduced the hang is opening, the system shall keep the window interactive: it can be moved, other pages opened and toolbar items used, with no beachball.
- **R3** When the cause is found and the fix is chosen, the plan shall name the docs-site pages the fix changes, or record "none", on andrew-waters/gannin#388.

**Decisions:**

- Who hits the hang, and is it reproducible by the team? **A real board the team uses hangs now, so it can be reproduced, its issues counted, and recovery observed.**
- What does the hang look like? **The app freezes, then recovers. The cost is waiting, with the UI unresponsive, each time the board is opened.**
- What is the smallest version worth shipping? **Fix the freeze only. Total time to show the board may stay long; making it faster or streaming issues in is out of scope.**
- How will we know the freeze is fixed? **The UI stays interactive while the large board opens: the window can be moved, other pages opened and the toolbar used, with no beachball. Checked by hand on the board that reproduced the hang.**
- Which user docs pages does this change? **Decide after the cause is found; revisit in design.**

## Design

**Measure first, then fix the biggest main-thread cost.** The issue doesn't know where the time goes, and the code has several plausible culprits, so the first piece of work is to reproduce the hang and profile it (Instruments Time Profiler, or `os_signpost` around each step below). The fix is then chosen from the profile, not guessed.

**What happens when a board opens** (`ProjectBoardView`): `loadBoard` loads the board definition and selects the first saved view. `ProjectStore.sync` then pages `GitHubAPI.boardItems` (50 per request, capped at 5000 items, 30 field values each), merges the result into `BoardCache` and writes the whole cache as JSON. `content(_:)` then sorts the items and `BoardTableView` / `BoardColumnsView` draws them.

**Suspects, most likely first:**
1. **Table rows aren't lazy.** `BoardTableView` uses a `LazyVStack` of groups, but each group is a `StatsTable`, whose rows are a plain `VStack` + `ForEach`. With no grouping there is one group, so every row is built at once, each with `AnyView` cells. At a few thousand items that is a long main-thread stall.
2. **Work in `body`.** `content(_:)` re-runs `store.items` (a `compactMap` over `itemsByID`), `BoardLayout.sorted` and `BoardLayout.groups` on every evaluation. `StatsTable.sortedRows` sorts again with `sortKey` closures that lower-case strings. This repeats on every state change while items arrive.
3. **Cache encode and decode on the main actor.** `ProjectStore` is main-actor, so `save` (JSON-encoding every item, then an atomic write) and `loadCached` (decoding it) run on the main thread, each time a sync merges, and on every field edit via `recordFieldValue`.
4. **Merge cost.** `BoardCache.merge` rebuilds `itemsByID` through `pruneOrphanedItems` and compares each item, all on the main actor.
5. **Fetch decoding.** Decoding up to 100 pages of GraphQL happens in the API layer; likely off the main actor but worth confirming.

**Follow existing patterns:** the Board layout already uses `LazyVStack` per column, so lazy rows have precedent. `StatsTable` is shared by 16 pages, so changing it is a wider risk than changing `BoardTableView` alone.

**Approach to the fix (final choice follows the profile):**
- If it's rendering: make the board's table rows lazy. Prefer a lazy rows path scoped to the board table first; make `StatsTable` itself lazy only if the other callers are checked by hand.
- If it's `body` work: compute the sorted and grouped items once per change of items, sort or view, outside `body`.
- If it's the cache: encode and decode on a background task and write the file there, keeping the in-memory cache on the main actor.

**Checking:** by hand on the reproducing board with `scripts/relaunch.sh`: while it opens the window moves, other pages open and the toolbar works. `docs-site/` is revisited once the fix is known (R3).

**Risks and dependencies:** needs the real board that hangs (someone in the room), because the cause depends on its size and its fields. A large board with many field values is the case to test. No unit tests cover boards, so any pure logic moved out of `body` should get a test.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Projects/ProjectBoardView.swift#L210-L231`: content(_:) fetches, sorts and picks the layout on every body evaluation; the first place to look for repeated work.
- `andrew-waters/gannin` `Gannin/Projects/ProjectStore.swift#L230-L292`: sync pages boardItems, merges into the cache and saves it, all on the main actor.
- `andrew-waters/gannin` `Gannin/Projects/BoardLayouts.swift#L17-L50`: BoardTableView groups per body evaluation, then one StatsTable per group; the LazyVStack only lazily builds groups, not their rows.
- `andrew-waters/gannin` `Gannin/Projects/ProjectQueries.swift#L47-L74`: boardItems pages 50 items at a time up to 5000, 30 field values each; pure network time, not main-thread, unless decoding runs on the main actor.
- `andrew-waters/gannin` `Gannin/Projects/ProjectModels.swift#L137-L170`: BoardCache.merge compares items and prunes itemsByID with a full filter on each sync.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Projects/BoardLayouts.swift#L228-L232`: BoardColumnsView puts cards in a LazyVStack per column: precedent for lazy rows on the board.

**Risks:**

- `andrew-waters/gannin` `Gannin/Projects/ProjectStore.swift#L306-L319`: loadCached decodes and save encodes and writes the whole BoardCache synchronously on the main actor; large boards make each a stall.
- `andrew-waters/gannin` `Gannin/Views/StatsTable.swift#L49-L65`: Rows are a plain VStack + ForEach with AnyView cells, so every row is built up front. Shared by 16 callers, so a change here needs each checked.

**Decisions:**

- Commit to a fix now, or profile first? **Profile first, then fix. The fix is chosen from the profile, so shared code such as StatsTable isn't changed on a guess.**

## Tasks

1. [andrew-waters/gannin#390](https://github.com/andrew-waters/gannin/issues/390) Reproduce the board hang and profile where the time goes (satisfies R1)
2. [andrew-waters/gannin#391](https://github.com/andrew-waters/gannin/issues/391) Stop the dominant main-thread cost from freezing the app when a large board opens (satisfies R2)

**Decisions:**

- Are the three tasks (reproduce and profile, fix the dominant cost, docs and changelog) right and in order? **Yes. Every acceptance criterion is covered, and the plan is ready.**

## Open questions

- How many issues does the board that hangs have?
- Which docs pages change, or none? Decided once the cause is known.
