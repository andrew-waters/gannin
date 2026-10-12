---
type: plan
status: in-progress
summary: "Group the Claude Code sessions window's tabs so review sessions and active work sessions each sit together, with a divider between them."
issues: [andrew-waters/gannin#300, andrew-waters/gannin#301, andrew-waters/gannin#302]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-12
requirement: requirements/session-tabs-are-grouped-between-reviews.md
---

# Session tabs grouped between reviews and active work

Group the Claude Code sessions window's tabs so review sessions and active work sessions each sit together, with a divider between them.

## Requirement

In full in [requirements/session-tabs-are-grouped-between-reviews.md](../requirements/session-tabs-are-grouped-between-reviews.md).

**Problem:** Review tabs and active work tabs are interleaved in one strip (ordered by when they were opened or inserted), so with many tabs open it is hard to find a particular one.

**Goal:** Review tabs and active work tabs each sit together in the strip, with a divider between the two groups, so a tab is quicker to find.

**Who it's for:** Anyone with several Claude Code sessions open in the sessions window, in particular those running PR reviews alongside their own work.

**Scope:**

1. Keep review tabs together and active work tabs together in the sessions window's tab strip
2. Show a divider between the two groups
3. Planning, Ask, quick change and draft tabs sit in the active work group, so there are two groups only
4. Dragging a tab reorders it within its own group only; a drop across the divider leaves it in its group

**Out of scope:**

- Headers or labelled sections (smallest version is ordering plus a divider)
- The posted / not-posted sub-grouping of reviews, unless the room pulls it back in

**Acceptance criteria:**

- **R1** When the sessions window shows its tabs, the system shall list every review session's tab together, and every other tab (issue work, planning, Ask, quick change, unstarted drafts) together.
- **R2** When both groups have at least one tab, the system shall show a divider between them; when one group is empty, the system shall show no divider.
- **R3** When a tab is opened, the system shall place it in its own group, after the selected tab if that tab is in the same group, otherwise at the end of the group.
- **R4** When a tab is dragged, the system shall reorder it within its own group, and a drop across the divider shall leave it in its group.
- **R5** When Gannin is relaunched, the system shall restore the tabs in their grouped order.
- **R6** When a review runs as a helper inside a session's tab, the system shall keep that tab in the group of the session that owns it.
- **R7** The Work on this docs page (docs-site/src/content/docs/agents/work-on-this.md) shall describe the two groups and the divider, and CHANGELOG.md shall have a line under [Unreleased].

**Decisions:**

- What's the real pain with the session tabs today? **Can't find a tab among many.**
- What's the smallest version worth shipping? **Ordering plus a divider: two groups kept together, a divider between, no headers.**
- Where do planning, Ask, quick change and draft tabs go? **With active work: two groups, reviews and everything else.**
- What does dragging do with two groups? **Reorder within a group only; group membership follows the session's kind.**
- Is the posted / not-posted sub-grouping of reviews part of this work? **Out; a follow-up issue.**
- Are the requirements right? **Yes, with R6 (tab moves group when a session changes kind) dropped, since no session changes kind in practice.**

## Design

**Derive the groups, keep one stored order.** `SessionStore.tabs` stays the flat, persisted list (`sessionsTabs`), so nothing is migrated and the grouped order is restored on relaunch (R5). A new `SessionStore.tabGroups` partitions it, keeping each tab's relative order: active work first (everything that isn't a review: drafts, planning, Ask, quick change and Code), then review tabs (a tab that `isPullRequestReview` and is not a helper), with the group divider between (R1, R6).

- **Tab bar:** `SessionTabBar` iterates the two groups and draws a distinct group divider between them only when both are non-empty (R2); it uses the existing `Divider()` rhythm but heavier or spaced so it differs from the per-tab dividers.
- **New tabs:** `reveal` and `addTab` insert after the selected tab if it's in the same group, otherwise at the end of the new tab's group (R3).
- **Drag:** `moveTab` does nothing when the dragged and target tabs are in different groups, so a drop across the divider leaves the tab where it was (R4).
- **Keyboard:** `selectTab(offset:)` walks the displayed order, so Next/Previous Tab doesn't jump around.
- **Tests:** Swift Testing on the partition, insertion and move rules in `SessionStore` (pure logic).
- **Docs:** `docs-site/src/content/docs/agents/work-on-this.md` and a `CHANGELOG.md` line (R7).

Why derive rather than keep the invariant in the array: every writer of `tabs` (reveal, addTab, replaceDraft, closeTab, moveTab, launch restore) would otherwise have to preserve it, and an old flat order would need migrating.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L343-L360`: The sessions window's tabs are one ordered array, SessionStore.tabs, persisted under sessionsTabs; reveal and addTab insert after the current tab, moveTab reorders by drag. Any grouping has to reconcile with this single order.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L525-L530`: tabOwner: a helper (including a PR review helper) shows in its parent session's tab, so work and its review share one tab. Such a tab is not a 'review tab'.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L155-L192`: SessionTabBar renders sessions.tabs in one ForEach inside a horizontal ScrollView, with a Divider after every tab (and draft tabs the same). The group divider has to be distinguishable from these per-tab dividers.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L532-L555`: reveal and addTab insert a new tab after the selected one, which would put a review among work tabs; they must insert within the tab's own group.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L612-L623`: moveTab (called from the tab's .draggable/.dropDestination at SessionViews.swift:638) and selectTab(offset:) (Next/Previous Tab) both work on the flat tabs array; moveTab must refuse a cross-group drop and selectTab must follow display order.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L625-L628`: tabs are persisted as a flat list under sessionsTabs and restored at launch (L514); if grouping is derived from the list, no migration is needed.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L439-L488`: TabKind already decides what a tab is (Review, Plan, Ask, Quick Change, Code...) from the session; the group test should reuse the same predicate (isPullRequestReview, not a helper) rather than a second one.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L570-L583`: replaceDraft swaps a draft's tab for its session's in place. A quick change or plan draft turns into a non-review, so it stays in the work group; any other draft-to-review path would have to be regrouped.
- `andrew-waters/gannin` `GanninTests/SessionStoreSaveTests.swift`: No tests cover tab ordering today; the grouping and insertion rules are pure logic on SessionStore and should get Swift Testing coverage.

**Decisions:**

- Is the strip the sessions window's? **Yes: it's SessionTabBar over SessionStore.tabs in Gannin/Sessions; the work window has no such strip.**
- Which group goes first in the strip? **Active work first (left), reviews after the divider.**
- Is the design right? **Yes: derived tabGroups over the flat persisted tabs, active work first, divider only when both groups exist, insertion and drag stay within a group.**

## Tasks

1. [andrew-waters/gannin#301](https://github.com/andrew-waters/gannin/issues/301) Group session tabs in SessionStore (satisfies R1, R3, R4, R5, R6)
2. [andrew-waters/gannin#302](https://github.com/andrew-waters/gannin/issues/302) Show a divider between the tab groups in the tab bar (satisfies R2)

**Decisions:**

- Are the tasks right? **Yes: three tasks in order (grouping logic with tests, tab bar divider, docs and CHANGELOG).**
