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

## Two steps

New Issue and New Sub-issue open on Claude. Most issues start as a rough line, so Claude writes it with you first, and the form comes second, for checking the details.

### 1. Write it with Claude

The left side is the conversation:

- **Make**: an issue, or a draft on a board.
- **Repository**: the project's first repo by default.
- **Board**: the workflow board by default. Claude suggests values for its fields.
- **Template**: the repo's issue templates, if it has any (Markdown or forms). Claude keeps its headings.
- **Images**: drop, paste or add them here or on the form (see [Images](#images)).
- Say what the issue is about and press **Draft with Claude** (or Return). Ask for changes and press **Revise**. **Skills** chooses the harness skills Claude follows; the ones about issues are ticked to start with.

The right side is a read-only preview of the draft: the title, labels, suggested board fields and the description. It updates with each reply.

Press **Next** (⌘↩) when the draft looks right, or **Skip** to go straight to an empty form. Cancel or Escape closes the sheet.

### 2. Confirm

The form, filled from the draft. The left column is the issue itself: Make, Repository, Template, **Title**, the description and Images. The right column is where it goes: the board and its fields, **Assignees**, **Labels** and **Parent**. A draft on a board needs a board.

**Back** (or Escape) returns to Claude and keeps what you changed on the form: the next revision improves on it rather than starting over. Cancel closes the sheet.

Tick **Create Another** to go back to Claude after each one, with the repo, board and parent kept.

## What gets written

Create writes to GitHub in steps: any images, the issue with its labels and assignees, the link to its parent, adding it to the board, then each board field. If a step fails, the sheet says which.

## Images

GitHub gives apps no way to attach images to an issue, so Gannin commits them to your harness repo and links them from the description. That means:

- They show inline only to people who can read the harness. The sheet warns you about sensitive data.
- The Create button names them, for example "Commit 2 Images and Create Issue". That button is the confirmation.
- With no harness, you can't attach images.

Drop pictures on the sheet (on either step), paste them with ⌘V when the clipboard holds only pictures (or press Paste), or choose Add Images. Each adds a placeholder at the end of the description, which you can move. PNG, JPEG, GIF and WebP are kept as they are, other pictures become PNG, and one over 5 MB becomes a JPEG when that makes it fit. If GitHub refuses the issue after the images were committed, retrying doesn't commit them again.

Your harness is described in [Projects and harnesses](/docs/concepts/projects-and-harnesses/).
