---
title: Design and Refine
description: Step through a web page with the team, note what to improve, and end with issues.
sidebar:
  order: 16
---

Design and Refine is a ritual for the team to walk through a page it has already shipped, together on the shared screen, and turn the rough edges it spots into issues. One person drives; Claude Code sits in as co-reviewer, reading the code behind the page.

## Starting one

Open **Rituals › Design and Refine** and press **New Design and Refine** (it's also in the Claude Code window's **+**, the toolbar of **Agents › Waiting on You** and the command palette). The New Design and Refine tab asks for:

- **Project**: the harness the session runs in.
- **Page**: the address to step through. `https` is added when you leave the scheme out, and `http` for `localhost`.
- **Name**: what's being looked at, for the tab and the lists. Left empty, it's the page's address.
- **Its code**: the repos the page's code is in, the project's first ticked. Claude looks through these.
- **Who's here**: tick the org's people, and type names for anyone outside it.

**Start** (⌘↩) opens the session in its tab. It always runs on this Mac, in the project's harness, in its own folder `.worktrees/refine-<date>-<name>/`, which is kept out of git. Claude is told it's a co-reviewer: it reads the code and never changes it.

## Stepping through the page

The session's tab shows the page in a browser inside Gannin, with the findings beside it. Above the page are **Back**, **Forward**, **Reload** and the address: type a new one and press Return to go there. Links work as they would in a browser. **Terminal** opens Claude's terminal below, with its composer.

Each project keeps its own logins for these pages, so signing in to staging once lasts from one session to the next, and never reaches another project's sessions. **⋯ › Sign Out of Pages** forgets this project's logins; Settings › Storage signs out of every project's. Plain `http` pages, such as `localhost`, load here too.

The session is kept with Gannin's others, so quitting and opening Gannin again brings it back on the page it was last on.

Capturing findings and screenshots, and agreeing the issues and the harness record are still to come (andrew-waters/gannin#134).
