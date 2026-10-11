---
title: A tour of the app
description: How Gannin's window is laid out, and where to find things in the sidebar, drawers and Inbox.
sidebar:
  order: 1
---

A Gannin window is a sidebar on the left and a page on the right. This page walks through both, and the Inbox, which is where most days start.

## The sidebar

At the foot of the sidebar are the account menu, the project menu and the org's settings (the cog). Your personal GitHub account is listed first, under Personal, and works like an org, except it has no teams and its only member is you. The [project](/docs/concepts/projects-and-harnesses/) you pick narrows every page to its repos.

The rows are grouped by what you're trying to do.

- **Dashboard** and **Inbox** sit at the top. Dashboard is the page a window opens on. Under them, **New Ask** and **Quick Change** start Claude Code work.
- **Work**: Pull Requests; Issues (with All and Not on a board); Epics; Repositories ([local git](/docs/guides/repositories/)); Projects (your GitHub boards); and Views.
- **Delivery**: Scorecards, PR flow, Issue flow, Releases, Investments and CI.
- **Team**: Everyone and each team (open one to see its members), then Activity and Time off.
- **Rituals**: Standup, Recap, Prioritisation, Planning and Board Hygiene.
- **Harness**: Plans, Requirements, Findings, Skills, Prompts, Learnings, Research and Refines. It appears once the project has a harness.
- **Agents**: Metrics, Waiting on You, Routines and Queue, then your Claude Code sessions.

Picking a person under Team shows their page as the main view.

At the very bottom is the sync row: a **Refresh** link, how much of your GitHub [budget](/docs/concepts/github-budget/) is left and when it resets, and a chevron that opens the step-by-step detail of a sync. The detail slides up by itself while a sync runs and closes a few seconds after. If GitHub is refusing requests, the row says Paused to a time, in orange. Option-click or right-click Refresh for Full Refresh.

A page whose data source is turned off in [Settings › Sync](/docs/settings/app/sync/) says so at the top.

## Windows and tabs

Windows are independent. Each window or tab remembers its own org, project, section and metrics window, so you can look at two orgs side by side.

- File › New Window and File › New Tab open another one.
- A window that opens with no org takes the last one you picked.
- Picking an org takes the project you last used for it on this Mac.

Right-click almost anything in a list for **Open in New Tab** and **Open in New Window**. A PR or issue opened in a new window gets a window of its own. Anything else opens a main window on the same org, sidebar row and page.

## Pages and Back

The page's title is the window's title, and its top-level controls are in the toolbar.

Opening something from a page (a person, a repo, a board) pushes it over the page you were on, under a breadcrumb trail. Only the last page shows, full width. **Back** is in the toolbar, or press ⌘[ or Esc. Picking a row in the sidebar clears the trail. If you open a page that's already in the trail, you go back to it rather than stacking a second copy. See [Keyboard shortcuts](/docs/keyboard-shortcuts/).

## Drawers

Pull requests, issues and harness documents open in a **drawer** over the page rather than replacing it. An issue's drawer has its facts, its timeline, plans, linked PRs, description and board fields. A drawer has **Open as Page** and **Open in Window** if you want more room.

- A link inside a drawer opens another drawer on top. The ones beneath show as a dimmed edge, up to three. Click an edge to go back to it.
- **Done** or Esc closes the top drawer. Clicking outside closes them all.
- With an issue open, ← and → step to the previous or next issue in the list it came from.

An issue's timeline tells its story: opened, assigned, board moves, sub-issues, reopened, closed and comments, then each linked PR's commits, reviews and merge.

## Inbox

The Inbox is your share of the workload, in sections:

- **Ready for your approval**: reviews Claude has finished that it would approve.
- **Claude Code**: sessions waiting on you for an answer.
- **While you were away**: what happened on PRs Claude reviewed while you weren't looking.
- **Needs your review**: reviews requested of you, longest waiting first.
- **Changed since your review**: PRs you asked changes of that have new commits or a reply.
- **Your pull requests** and where each stands.
- **Your issues**: those assigned to you, in progress first.

Three more are off until you want them: **Issues you opened**, **Your harness plans** and **Uncategorised investments**.

The **Sections** button in the bar lets you tick which sections show and drag them into the order you want. Usual Sections puts them back. This is kept per org, on this Mac. Click a column heading to sort within a section.

## Hiding things

Hide and Unhide are in the right-click menu of PRs and issues. Hiding is local to you, and hidden items drop out of the counts. [Org settings › Hidden](/docs/settings/org/hidden/) lists them.
