---
title: The command palette
description: Jump to any page, person, PR, issue or document, or run an action, from the keyboard.
sidebar:
  order: 2
---

Press ⌘K, or choose View › Command Palette, to open the palette over any window. Type, pick a result, and Gannin takes you there. It also works in the issue, PR and Claude Code windows, where it hands results to your main window.

In the Claude Code window, a focused terminal keeps ⌘K for itself. Click outside the terminal first.

## What it searches

The palette searches what Gannin already has stored for every org you belong to. It never fetches anything, so it's instant, and it only knows what's been loaded. If an org has nothing stored yet, the foot of the palette names it and says to open it to search it.

Results come in groups, each labelled with its org:

- **Actions**: New Issue, Refresh, Full Refresh, Switch to an org or project, New Window, New Tab, Open Claude Code, New Ask, New Quick Change, Next Session Waiting on You, and toggles to Exclude Draft Pull Requests and Show Hidden Items.
- **Pages**, including each org's Settings panes (as Settings › Repositories and so on).
- **People**, **Pull Requests** (open and recently merged) and **Issues** (the full issue history).
- **Harness** documents.
- **Boards and Views**.
- **Repositories** and **Claude Code Sessions**.
- **In Descriptions**: issues whose description matches, which appear a moment after you stop typing.

Each group shows six results.

## How matching works

Every word you type has to match. `#123` or `repo#123` finds that number first. Otherwise, titles that start with your text rank above titles with a word that starts with it, then anything else. Your window's org, open items and shorter titles win ties.

With nothing typed, the palette shows your recent picks (on this Mac, your window's org first) and suggested actions.

## Picking

- ↑ and ↓ move, ↩ opens the result, Esc closes the palette.
- A result in the org your window shows opens right there. PRs, issues and documents open in a drawer.
- A result in **another org** asks what to do: Switch This Window, Open in New Tab or Open in New Window. ⌘↩ opens a new tab and ⌥↩ a new window without asking, and Esc goes back to the results. Actions just switch.

Focus goes back to where it was when the palette closes. See [Keyboard shortcuts](/docs/keyboard-shortcuts/) for the full list.
