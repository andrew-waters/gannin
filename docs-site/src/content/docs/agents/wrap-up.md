---
title: Closing a session and quitting
description: What Gannin asks when you close a session's tab or quit with Claude still running.
sidebar:
  order: 8
---

Closing a tab doesn't stop Claude. Gannin asks first, so work isn't left half-finished without you noticing.

## Closing a tab

When Claude, or one of its helpers, is still running in an issue's session or a Quick Change, closing its tab (the tab's ✕, Close Tab or the close shortcut) opens a wrap-up sheet. It shows:

- What Claude is doing now, and any helpers running.
- The session's pull requests.
- For each worktree, the files not committed and the commits not pushed.
- Plans and requirements about the issue that still have unticked `- [ ]` items.

Tick the items that are done and commit them in one commit, with the button naming the harness it goes to, or choose **Ask Claude to Tick Them Off** and let the session do it.

Then choose what happens to the session:

| Button | What it does |
| --- | --- |
| **Keep Running** | Closes the tab and leaves Claude working. Find it again under Agents. This is the default. |
| **Stop Claude** | Ends Claude and its helpers but keeps the worktrees. Opening the session again carries on the conversation. |
| **Finish and Clean Up…** | Offered once every pull request is merged. Removes the worktrees, after you confirm, including any whose git folder is already gone (such as when its clone was deleted). A worktree like that which still has files in it is left, with its name in the error, so you can look first. |
| **Cancel** | Keeps the tab open. |

A line above the buttons explains each one. Tabs for Ask, planning and review sessions close without the sheet.

To stop being asked, tick **Don't ask again** on the sheet, or turn off **Ask to wrap up when closing a session's tab** in Settings › General › Agent.

## Quitting

Quitting Gannin with sessions running asks first. It lists which sessions are running and what each is doing, and warns that:

- Sessions that are working stop mid-task.
- Sessions running on a server end with their ssh connection.
- Conversations can be resumed afterwards.

Routines that started a session are named as scheduled runs. See [Routines](/docs/agents/routines/).
