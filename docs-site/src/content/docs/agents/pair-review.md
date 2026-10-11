---
title: Pair review
description: A second agent reviews a session's work before its pull request goes up.
sidebar:
  order: 5
---

With pair review, Claude's change is looked at by a second agent before you see it. The reviewer can read but not edit, and nothing is posted to GitHub.

## How it works

1. Claude is told to run a ready-for-review command, with a note, once the change is committed and built and before it marks a PR ready.
2. Gannin starts a reviewer in the background, inside the session's tab. You can open it with Show Reviewer.
3. The reviewer's findings are pasted into Claude's prompt (when it's waiting, else when its turn ends). Claude fixes what it agrees with, says why not for the rest, commits, and runs the command again.
4. This repeats for up to three rounds. It ends **Settled** when a round finds nothing. At the limit, the last round's findings are still sent.

The session's tab shows how the review is going.

## Controls

Settings › General › Agent has **Review a session's work with a second agent** (on by default). Each session's Activity pane has its own **Review when it's ready** switch, a Status line, Show Reviewer, **Stop** (ends the loop and tells Claude to carry on) and **Review Now** (starts a round without waiting for Claude).

Pair review applies to a session's own work, not to helpers, PR reviews, plans or Asks. If it's off or has stopped, Claude's request is answered "carry on". After Settled, a new request starts a fresh loop.

This is separate from [Review with Claude](/docs/agents/reviews/), which reviews a pull request someone else wrote.
