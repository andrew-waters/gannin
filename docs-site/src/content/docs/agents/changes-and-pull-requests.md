---
title: Changes and pull requests
description: Review a session's edits, comment on lines, and handle its PRs' checks and feedback.
sidebar:
  order: 3
---

A session's side panel has Changes and PRs next to Issue and Activity. (An Ask session has no Changes, and PRs appears once it has one.)

## Changes

Changes diffs every worktree in the issue's folder, new files included. A switch at the top picks the mode:

- **Branch**: everything since the branch left the default branch, committed or not.
- **Uncommitted**: what isn't committed yet. Here you can Stage and Unstage files, Discard a file or a single hunk, Commit, and Push. Each worktree says what isn't pushed.

Commit opens a sheet with a message, or Ask Claude to Commit. Files and lines open in your chosen editor (Open in …, and Copy Path).

The pane updates when Claude edits files or runs commands, and otherwise every 10 seconds (30 over ssh).

### Comments on lines

Click a line's number, or use Comment on This Line, to write a comment. Comments collect in a bar under the list showing their count. Send to Claude pastes them together into Claude's prompt (if it's working, it reads them when done); Discard drops them. Nothing is posted to GitHub.

## PRs

The PRs pane lists the session's pull requests: those Claude opened from the session's branch, or any you open from it. Each shows its state, review, conflicts and checks. Gannin looks every two minutes (every minute while checks run), set in Settings › Sync.

- **Send Failures to Claude** pastes the failed checks, with how to read their logs, into Claude's prompt. **Re-run Failed Checks** asks GitHub to run them again.
- Open review threads and reviews with words in them are listed with ticks. **Send N to Claude** pastes the ticked ones as one prompt.

### New feedback

Gannin notifies you of new failing checks and new review comments from other people. It doesn't flag conversation comments, approvals or conflicts.

Turn on **Send new feedback to Claude** on the pane to paste new failures and feedback into the session automatically: straight away if Claude is waiting for you, otherwise when its turn ends. If Claude exits first, it's dropped. The prompt also asks Claude to post a short reply on each review thread it fixed, saying what it changed; threads it disagrees with are left for you. Settings › General › Agent › Ask Claude to reply to review threads turns that off. The default for new sessions is Settings › General › Agent › Send new PR feedback to Claude (off).
