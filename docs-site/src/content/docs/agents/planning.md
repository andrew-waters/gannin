---
title: Planning sessions
description: Plan a topic with the team in the room, stage by stage, and commit the agreed plan to the harness.
sidebar:
  order: 13
---

A planning session is Claude working with a room of people to turn a topic into a plan. It runs in your project's [harness](/docs/concepts/projects-and-harnesses/) and ends with documents committed there.

## Starting one

Open a New Plan tab in the Claude Code window, or use Plan This on an issue. Rituals › Planning lists the sessions you have, with Delete. You can also start from the Agents page, the + menu or a harness document.

The tab has an editable prompt. Start from fills it with one of the team's planning prompts (and its skills), a suggested one, or nothing. What's in the box is what Claude is told. Saving commits it as a planning prompt for next time.

## Stages

The tab is a spec built in stages, each looped until the room approves it:

1. **Context**: documents to read first, links, and places to look.
2. **Requirements**: acceptance criteria.
3. **Design**: the approach, and the code looked at.
4. **Tasks**: each names the criteria it satisfies. Gannin flags any criterion no task covers.
5. **Agree**.

Moving forward approves the stages you passed. Back (with a reason, which is sent to Claude) reopens one and marks the later ones Recheck.

## In the room

On top is what's happening now: a question for the room, what Claude is reading, or whose turn it is. Below is the stage you're looking at, with the requirement as it stands on the right. Both dim while a question is open.

Questions come in a style you pick, kept on this Mac: One at a Time (letter keys), Poll the Room (counts hands and sends the most), Keyboard List or Conversation. A comment box at the foot sends "From the room", closing an open question first. The terminal and prompt box are in a drawer.

Documents dropped on the terminal or picked are each confirmed, as to whether to share it, and separately whether it may be committed.

## Agree

Agree shows what isn't approved or covered, lets you tick who was here, and lets you edit the tasks. It then makes the parent issue (the planned one, or a new one) and a sub-issue per task on the workflow board, and commits the plan and the requirement in one commit.

## Ending a plan

End, beside Agree in the workspace, stops Claude, closes the tab and takes the plan out of the sidebar's Planning group. It's there whether or not the plan is agreed. After ending, the plan stays on Rituals › Planning with the status Finished, and opening it shows its stages, tasks and decisions to read; Claude isn't started again. Delete, from that list, removes a plan altogether.
