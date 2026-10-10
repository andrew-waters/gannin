---
title: Issues settings
description: Every option in Org settings › Issues, which says how issues move through your board so cycle time can be worked out.
sidebar:
  order: 5
---

Org settings › Issues tells Gannin which project board, and which of its statuses, mean an issue is in progress. That is what issue cycle time is built from. Open it with the cog beside the account menu in the sidebar's footer, then pick Issues in the toolbar.

Cycle time is the time an issue spends in the statuses you tick. The clock stops when it moves to any other status (Done, or back to Backlog) or is closed, and starts again if it comes back. This is a team file, and it belongs to the project your window is working in: a project's harness keeps it as `.gannin/workflow.json`, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps it on this Mac.

## Issue workflow

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Board | Any board | Only this board's statuses count. With a board picked, the status list below is its Status options in board order. Any board counts statuses from every board. | Harness (`.gannin/workflow.json`) |
| Otherwise, start at the first linked PR | On | For issues that never reach an in-progress status: treats the first linked PR being opened as the start, and the close as the end. | Harness (`.gannin/workflow.json`) |

## In progress when the status is

Each status is a checkbox, with a coloured dot (the board's own colour, when a board is picked) and a count of moves seen. Statuses appear once issues have synced (open the Issues page), or once you pick a board. Reading boards needs the project permission, so sign out and back in once if none show up.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| A status name | Only In Progress ticked | Ticking a status makes time spent in it count towards cycle time. Names are compared without caring about capitals. | Harness (`.gannin/workflow.json`) |
| Status | Empty | With Any board picked, type a status name here (the prompt reads "Add a status by name"), then press Return or use Add. Hidden once a board is picked, because the board's own options are the whole list. | Harness (`.gannin/workflow.json`) |
| Add | Disabled until a name is typed | Adds the typed status and ticks it. | Harness (`.gannin/workflow.json`) |
