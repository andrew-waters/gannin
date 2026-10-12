---
type: requirement
status: in-progress
summary: "Review tabs and active work tabs each sit together in the strip, with a divider between the two groups, so a tab is quicker to find."
issues: [andrew-waters/gannin#300]
plans: [plans/2026-10-12-session-tabs-are-grouped-between-reviews.md]
---

# Session tabs grouped between reviews and active work

## Problem

Review tabs and active work tabs are interleaved in one strip (ordered by when they were opened or inserted), so with many tabs open it is hard to find a particular one.

## Goal

Review tabs and active work tabs each sit together in the strip, with a divider between the two groups, so a tab is quicker to find.

## Who it's for

Anyone with several Claude Code sessions open in the sessions window, in particular those running PR reviews alongside their own work.

## Requirements

1. Keep review tabs together and active work tabs together in the sessions window's tab strip
2. Show a divider between the two groups
3. Planning, Ask, quick change and draft tabs sit in the active work group, so there are two groups only
4. Dragging a tab reorders it within its own group only; a drop across the divider leaves it in its group

## Out of scope

- Headers or labelled sections (smallest version is ordering plus a divider)
- The posted / not-posted sub-grouping of reviews, unless the room pulls it back in

## Acceptance criteria

- **R1** When the sessions window shows its tabs, the system shall list every review session's tab together, and every other tab (issue work, planning, Ask, quick change, unstarted drafts) together.
- **R2** When both groups have at least one tab, the system shall show a divider between them; when one group is empty, the system shall show no divider.
- **R3** When a tab is opened, the system shall place it in its own group, after the selected tab if that tab is in the same group, otherwise at the end of the group.
- **R4** When a tab is dragged, the system shall reorder it within its own group, and a drop across the divider shall leave it in its group.
- **R5** When Gannin is relaunched, the system shall restore the tabs in their grouped order.
- **R6** When a review runs as a helper inside a session's tab, the system shall keep that tab in the group of the session that owns it.
- **R7** The Work on this docs page (docs-site/src/content/docs/agents/work-on-this.md) shall describe the two groups and the divider, and CHANGELOG.md shall have a line under [Unreleased].

Planned in [plans/2026-10-12-session-tabs-are-grouped-between-reviews.md](../plans/2026-10-12-session-tabs-are-grouped-between-reviews.md).
