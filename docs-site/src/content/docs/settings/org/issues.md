---
title: Issues settings
description: Every option in Org settings › Issues, which says where the org files its issues, how they move through your board so cycle time can be worked out, and how the team runs standup.
sidebar:
  order: 5
---

Org settings › Issues tells Gannin where the org files its issues, and which project board, and which of its statuses, mean an issue is in progress. That is what issue cycle time is built from. Open it with the cog beside the account menu in the sidebar's footer, then pick Issues in the toolbar.

## Where issues go

How the org keeps its issues, which [planning](/docs/agents/planning/#agree) follows when it files a plan's tasks. This is an org-wide team file: the home project's harness keeps it as `.gannin/issue-strategy.json`, whichever project your window is in, so everyone working on the org reads the same choice. Changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps it on this Mac.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Strategy | Per repo, collected on a project | **Per repo, collected on a project**: each issue goes in the repo its work is in, and repos with issues turned off, or archived, are never offered. **Central repo**: every issue goes in one repo (a `product` repo, say), whichever repo the work is in, and the issue says which repo that is. | Home harness (`.gannin/issue-strategy.json`) |
| Repository | None picked | With Central repo, the repo every issue goes in. If it has issues turned off or is archived, a warning says so here and in planning's Agree. | Home harness (`.gannin/issue-strategy.json`) |
| Project | The Issue workflow board | With Per repo, the board each new issue is added to. The Issue workflow board is the Board picked below; with Any board there, issues aren't added to one. | Home harness (`.gannin/issue-strategy.json`) |

Under Central repo, planning still adds each issue to the Issue workflow board, when one is picked.

## Issue workflow settings

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

## Standup

How the project runs [Standup](/docs/guides/standup/). This is a team file, and it belongs to the project your window is working in: a project's harness keeps it as `.gannin/standup.json`, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps it on this Mac.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Style | Walk the Board | The style Standup opens on: Walk the Board, Person by Person, Changelog or Written. Anyone can pick another from Standup's toolbar for the day, without changing this. | Harness (`.gannin/standup.json`) |
| Discussion label | needs discussion | The GitHub label that marks an issue to discuss at standup. Issues with it (open, or completed since the day began) are listed first under Done and needs discussion. Standup's Needs Discussion and Discussed add and remove it. | Harness (`.gannin/standup.json`) |

## Standup columns

A menu for each Status option on the Issue workflow board, in board order, with the board's colour: Done, In review, In progress or Not shown. Pick the Board under Issue workflow first; the options appear once the board has loaded.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| A status name | Guessed from its name | Which Standup column the status's issues are in. Done shows issues moved to the status since the last working day; In review and In progress show the board as it is; Not shown leaves them off. Until you pick one, names like Done, Shipped or Complete are Done, names with "review" are In review, and the in-progress statuses above, or names with "progress", are In progress. Issues with no Status are always Triage. | Harness (`.gannin/standup.json`) |
