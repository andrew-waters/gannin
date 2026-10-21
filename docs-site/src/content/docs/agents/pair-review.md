---
title: Pair review
description: A second agent reviews a session's work before its pull request goes up.
sidebar:
  order: 5
---

With pair review, Claude's change is looked at by a second agent before you see it. The reviewer can read but not edit, and nothing is posted to GitHub.

## How it works

1. Claude is told to run a ready-for-review command, with a note, once the change is committed and built and before it marks a PR ready.
2. Gannin starts a reviewer in the background, inside the session's tab. You can open it with Show Reviewer. Opening the session's tab, from the tab bar, by cycling to it, or from the Agents page, the command palette or a notification, shows the reviewer instead when it is waiting for an answer and the session itself isn't.
3. The reviewer's findings are pasted into Claude's prompt (when it's waiting, else when its turn ends). Claude fixes what it agrees with, says why not for the rest, commits, and runs the command again.
4. This repeats for up to three rounds. It ends **Settled** when a round finds nothing. At the limit, the last round's findings are still sent.

The session's tab shows how the review is going.

## Controls

Settings › General › Agent has **Review a session's work with a second agent** (on by default). Each session's Activity pane has its own **Review when it's ready** switch, a Status line, Show Reviewer, **Stop** (ends the loop and tells Claude to carry on) and **Review Now** (starts a round without waiting for Claude). Once the review has ended, as Settled, at the round limit or stopped, make more changes and click Review Now to launch the reviewer again: its tab comes to the front, and it looks at every change in the worktree as it is now, committed or not, leaving out what has been dealt with. If the reviewer's Claude Code had exited, it is started again and resumes its conversation. If Review Now can't start, because Claude Code isn't running in the session's tab, the panel says why.

Pair review applies to a session's own work, not to helpers, PR reviews, plans or Asks. If it's off or has stopped, Claude's request is answered "carry on". After Settled, a new request starts a fresh loop.

## A second opinion from Junie

A project can also have [JetBrains Junie](https://junie.jetbrains.com/) review the change, alongside the Claude reviewer. It's off by default. Turn on **Junie reviewer** in Org settings › Projects, in the project's Harness section. The setting is kept on this Mac, not shared through the harness, and applies to sessions in that project.

With it on, each round runs both reviewers, and Claude gets their findings together once both have answered, within the same three rounds. Each finding says who raised it (`claude`, `Junie`, or `claude and Junie` when both flagged the same line of the same file, which then shows each one's comment). Stopping the review also stops a Junie run that's still going. The session's Activity pane shows a line for Junie: looking, how many findings, or why it couldn't review.

- **What Junie needs.** The `junie` command installed on this Mac and already signed in (its own login, or `JUNIE_API_KEY` set where Gannin can see it). Gannin installs nothing and stores no key.
- **It can't edit your work.** Junie runs once a round, as a separate process, in a throwaway copy of the session's worktree folder. The copy is deleted afterwards, so whatever Junie changes in it is discarded, and its git commands (commit, checkout, reset) act on a private copy of the repository's branches and index, not yours (a submodule's own git data isn't copied). Junie still loads your own Junie settings and MCP servers, though, and anything those can reach outside the copy isn't protected.
- **Local sessions only.** For a session that runs in a sandbox or on a server, Junie is shown as not available, with the reason.
- **If Junie fails**, because it isn't installed, is signed out, hits a quota or takes longer than ten minutes, the panel says why and the round goes ahead with Claude's findings alone. The next round tries Junie again.

This is separate from [Review with Claude](/docs/agents/reviews/), which reviews a pull request someone else wrote.
