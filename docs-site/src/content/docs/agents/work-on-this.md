---
title: Work on This
description: Start Claude Code on an issue and follow it from the Claude Code window.
sidebar:
  order: 1
---

Work on This starts a Claude Code session for an issue. It's on the issue page's toolbar, in the context menu of rows in Issues › All, and in the issue's window and drawer.

## Starting a session

The session runs in your project's harness, so there's no repo to pick. Claude makes a worktree per repo the issue touches. A sheet asks which of the team's prompts and skills to use and lets you add a note; with [sandboxing](/docs/sessions/sandboxes/) on, it also has Run in. Where it runs is covered in [Choosing where sessions run](/docs/sessions/).

If the harness records sessions, Gannin asks before committing the session's brief to it. Settings › General › Agent has Ask before recording a session, and the dialog has Don't ask again.

An issue that already has a session shows Open Session instead.

## The Claude Code window

Every session opens as a tab in the one Claude Code window. Tabs are remembered across launches.

- Each tab shows an icon for its kind, and the issue or PR above its title.
- **+** opens a popover with New Ask, Quick Change and Plan buttons over a list of sessions you've started that have no tab open.
- Drag tabs into order. Rename Tab (or double-click) names one; clearing the name goes back to the title.
- Close Tab (or ⌘W) closes the tab and leaves Claude running. For an issue's own session or a quick change that's running, Gannin first shows a wrap-up sheet with Claude's state, its PRs, and uncommitted or unpushed work. It offers Keep Running (the default), Stop Claude, or, once every PR is merged, Finish and Clean Up. Turn the question off in Settings › General › Agent with Ask to wrap up when closing a session's tab.
- Show Beside puts two tabs side by side, and the grid in the tab bar shows every session.

Helpers (such as a reviewer) have no tab of their own. They appear inside their session's tab, under a switcher of Work and each helper by role.

## The side panel

Each tab is a terminal beside a panel. You can drag the panel narrower and hide it from the composer.

- **Issue** (Session for an Ask or a helper): the issue's state, and its plans and requirements from the harness.
- **Changes** and **PRs**: see [Changes and pull requests](/docs/agents/changes-and-pull-requests/).
- **Activity**: events, cost, time working against waiting, files edited, the last test or build, and how full Claude's context is. Plans Claude writes appear here with Read, Approve Plan and Request Changes.

## The composer

Under the terminal: a box to tell Claude something, your saved prompts (⌃1 to ⌃9, edited in Settings), a stop button for interrupting mid-turn, the [Attended or Unattended](/docs/agents/attended-and-unattended/) menu, the context gauge with Compact Now, and the result of the last test or build.

## When Claude needs you

When Claude asks a question, the question and its options float over the terminal and also show on the Agents page. A permission prompt shows the command with Allow and Deny.

A session that moves to Needs you, or finishes its turn while you aren't looking at its tab, is flagged: its tab is marked, the Dock icon counts it, and a notification opens the tab. Notifications follow Settings › General › Agent (Notify when a session needs you). The tab bar's waiting count, or ⇧⌘J, goes to the session that has waited longest.

## Finishing

Once every PR is merged, or the session has been idle for three days, Finish and Clean Up removes its worktrees and forgets the session. Forget removes it without cleaning up.

## Settings

Settings › General › Agent picks the model sessions start with (blank leaves it to Claude Code). Anthropic is the only provider.
