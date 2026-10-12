---
title: Board Hygiene and Epics
description: Find issues whose board status disagrees with reality, fix them together, and follow issues with sub-issues.
sidebar:
  order: 34
---

## Board Hygiene

Board Hygiene lists issues by the flag they carry, each with a count and a one-line explanation. It reads your workflow board, set in [Issues settings](/docs/settings/org/issues/).

| Flag | Fix offered |
| --- | --- |
| PR merged, not done | Move to Done, on the workflow board |
| Closed, not done | Move to Done, on the workflow board |
| Done, still open | Close, closing the issue as completed |
| Quiet in progress | None |
| In review, no open PR | None |

Every issue under a fixable flag is ticked. Untick any you want to leave, then press the flag's button. Gannin shows the ticked changes first; nothing is written to GitHub until you confirm, and then they're written together. Click an issue's row to open it.

## Epics

Epics lists issues that have sub-issues. Each row shows:

- Progress: how many sub-issues are done.
- How many are in progress.
- Linked plans from the harness.
- Open and merged PRs.
- When it last moved. An epic with no movement for two weeks is marked Quiet.

To add a sub-issue to an epic, see [New Issue](/docs/guides/new-issue/).
