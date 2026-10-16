---
type: requirement
status: in-progress
summary: "Opening a large board leaves the app responsive."
issues: [andrew-waters/gannin#388]
plans: [plans/2026-10-16-opening-a-project-board-with-many-issues.md]
---

# Opening a project board with many issues no longer hangs the app

## Problem

Opening a project board that has a lot of issues freezes the app, then it recovers. Unconfirmed per the issue: the issue count that triggers it, whether the time goes in fetching, storing or drawing, which Gannin/macOS versions, and whether it affects every large board.

## Goal

Opening a large board leaves the app responsive.

## Who it's for

Anyone using Gannin with a large project board.

## Requirements

1. Reproduce the hang on a real large board and record the triggering issue count
2. Find where the time goes: fetching, storing or drawing
3. Stop opening the board from freezing the app

## Out of scope

- Making the board open faster overall
- Progressive or streamed loading of issues

## Acceptance criteria

- **R1** When a large project board is opened, the hang shall be reproduced and the triggering issue count recorded on andrew-waters/gannin#388.
- **R2** While the board that reproduced the hang is opening, the system shall keep the window interactive: it can be moved, other pages opened and toolbar items used, with no beachball.
- **R3** When the cause is found and the fix is chosen, the plan shall name the docs-site pages the fix changes, or record "none", on andrew-waters/gannin#388.

## Open questions

- How many issues does the board that hangs have?
- Which docs pages change, or none? Decided once the cause is known.

Planned in [plans/2026-10-16-opening-a-project-board-with-many-issues.md](../plans/2026-10-16-opening-a-project-board-with-many-issues.md).
