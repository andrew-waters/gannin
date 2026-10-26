---
title: Planning sessions
description: Plan a topic with the team in the room, stage by stage, and commit the agreed plan to the harness.
sidebar:
  order: 13
---

A planning session is Claude working with a room of people to turn a topic into a plan. It runs in your project's [harness](/docs/concepts/projects-and-harnesses/) and ends with documents committed there.

## Starting one

Open a New Plan tab in the Claude Code window, or use Plan This on an issue. Rituals › Planning lists the sessions you have, with Delete. Right-clicking a plan there, or in the sidebar's Planning group, offers Open and Delete, plus links to the plan and parent issue once it's agreed. You can also start from the Agents page, the + menu or a harness document.

The tab has an editable prompt. Start from fills it with one of the team's planning prompts (and its skills), a suggested one, or nothing. What's in the box is what Claude is told. Saving commits it as a planning prompt for next time.

The session runs through the project's Planning [workflow](/docs/agents/workflows/). With none set up, it's the session described here. A workflow can have a [specialist](/docs/concepts/specialists-and-workflows/) run the session, on its own model, told who it is before the team's prompts.

## Stages

The tab is a spec built in stages, each looped until the room approves it:

1. **Context**: documents to read first, links, and places to look.
2. **Requirements**: acceptance criteria.
3. **Design**: the approach, and the code looked at.
4. **Tasks**: each names the criteria it satisfies. Gannin flags any criterion no task covers.
5. **Agree**.

Moving forward approves the stages you passed. Back (with a reason, which is sent to Claude) reopens one and marks the later ones Recheck.

## In the room

On top is what's happening now: a question for the room, what Claude is reading, or whose turn it is. Below is the stage you're looking at, with the requirement as it stands on the right. The stage dims while a question is open (click it to look at it); the requirement stays as it is, so you can read it while you answer.

Questions come in a style you pick, kept on this Mac: One at a Time (letter keys), Poll the Room (counts hands and sends the most), Keyboard List or Conversation. A comment box at the foot sends "From the room", closing an open question first. The terminal and prompt box are in a drawer.

Documents dropped on the terminal or picked are each confirmed, as to whether to share it, and separately whether it may be committed.

## Agree

Claude is asked to keep tasks few and large, by default one per repository that needs changing, with the finer steps as a checklist in the task rather than tasks of their own. Each task becomes a sub-issue, so check them in Agree, where you can edit them.

Agree shows what isn't approved or covered, lets you tick who was here, and lets you edit the tasks. It then makes the parent issue (the planned one, or a new one) and a sub-issue per task, adds each to the board, and commits the plan and the requirement in one commit.

Where the issues go follows the org's choice in [Org settings › Issues › Where issues go](/docs/settings/org/issues/#where-issues-go), which Claude is told when the session starts:

- **Per repo, collected on a project**: each task's issue goes in the repo its work is in. Agree never offers a repo with issues turned off or an archived one: a task that named one moves to another repo, with a note saying why. Each issue is added to the project picked there, or the Issue workflow board.
- **Central repo**: every issue, the parent included, goes in the named repo, and each issue says which repo the work is in. If that repo has issues turned off or is archived, Agree warns before you write. Each issue is added to the Issue workflow board, when one is picked.

You can still pick another repo for any issue before Agree and Write.

When the plan has just one task, it doesn't get a sub-issue. Agree adds its details to the parent issue's description in a Details section, and the sheet says so. The parent is the issue being planned, or a new one if there wasn't one. If the issue being planned has the type Epic or Initiative, the task still becomes a sub-issue.

## Ending a plan

End, beside Agree in the workspace, stops Claude, closes the tab and takes the plan out of the sidebar's Planning group. It's there whether or not the plan is agreed. After ending, the plan stays on Rituals › Planning with the status Finished, and opening it shows its stages, tasks and decisions to read; Claude isn't started again. Delete, from that list, removes a plan altogether.
