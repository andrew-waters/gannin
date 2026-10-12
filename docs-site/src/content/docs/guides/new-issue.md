---
title: New Issue
description: Write an issue, or a draft item or sub-issue, from Gannin, with Claude's help and images if you want them.
sidebar:
  order: 31
---

New Issue creates a GitHub issue, or a draft item on a board, without leaving Gannin. Nothing is written until you press Create.

## Open it

- File › New Issue (⌘N).
- New Issue in the toolbar of the issue pages, Inbox, Epics, Prioritisation, Board Hygiene, Views and boards.
- The + on a board column, which presets that column's value.
- New Sub-issue in an issue's context menu or drawer.

The new issue opens in a drawer once it's created.

## The sheet

The left column is the issue itself:

- **Repository**: the project's first repo by default.
- **Template**: the repo's issue templates, if it has any (Markdown or forms).
- **Title** and description.
- **Draft with Claude**: a conversation where Claude writes the description and you ask for changes (the button becomes Revise). Skills from your harness about issues are ticked to start with.

The right column is where it goes: the board (the workflow board by default) and its fields, **Assignees**, **Labels**, **Parent**, and **Images**. Choosing a board with no repo makes a draft item on the board rather than an issue.

Tick **Create Another** to keep the sheet open after each one, with the repo, board and parent kept.

## What gets written

Create writes to GitHub in steps: any images, the issue with its labels and assignees, the link to its parent, adding it to the board, then each board field. If a step fails, the sheet says which.

## Images

GitHub gives apps no way to attach images to an issue, so Gannin commits them to your harness repo and links them from the description. That means:

- They show inline only to people who can read the harness. The sheet warns you about sensitive data.
- The Create button names them, for example "Commit 2 Images and Create Issue". That button is the confirmation.
- With no harness, you can't attach images.

Drop pictures on the sheet, paste them with ⌘V when the clipboard holds only pictures (or press Paste), or choose Add Images. Each adds a placeholder at the end of the description, which you can move. PNG, JPEG, GIF and WebP are kept as they are, other pictures become PNG, and one over 5 MB becomes a JPEG when that makes it fit. If GitHub refuses the issue after the images were committed, retrying doesn't commit them again.

Your harness is described in [Projects and harnesses](/docs/concepts/projects-and-harnesses/).
