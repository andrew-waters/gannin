---
title: Quick Change
description: Start Claude on a small change from a note, without writing up an issue first.
sidebar:
  order: 7
---

A Quick Change is for a snag, a tweak or a one-line fix. You write a note, and Claude starts on it straight away in a worktree and branch of its own.

## Starting one

New Quick Change is beside New Ask in the sidebar, in the Claude Code window's **+**, on the Agents page and in the command palette. It opens a tab with a form:

- **Project** and **Repository** (the project's first, then the org's).
- **What to change**: the note.
- **Title**: optional. Without it, the note's first line is used.
- **Screenshots**: drop, paste or Add Screenshots. Images only, up to 20 MB each.
- **Create an issue for it**: on by default, and asked each time.
- The team's prompts and skills for work, **Run in** (when sandboxing is on) and **Record the session in the harness**.

What you've typed stays in the tab while you look at another.

The session runs through the project's Quick Change [workflow](/docs/agents/workflows/). With none set up, it's the session described here. A workflow can have a [specialist](/docs/concepts/specialists-and-workflows/) run the session, on its own model, told who it is before the team's prompts.

## With an issue

Starting files an issue from your note, assigned to you, and adds it to the project's workflow board with Status set to its first in-progress option. If the board step fails, the error shows in the panel and the session starts anyway. From then on the session is that issue's, like [Work on This](/docs/agents/work-on-this/).

## Without an issue

The session has no issue. Claude is told it's meant to be small, needs no plan document, and should stop and say so if it isn't. The PR says "Quick change, no issue." where it would normally close one.

## Screenshots

They're copied into the session for Claude to look at, and are never uploaded to GitHub or committed. The exception is **Add the screenshots to the issue** (offered with an issue, off each time), which commits them to the harness so the issue can show them; the button then reads Commit N Images, Create Issue and Start.

## The tab

A Quick Change tab is named Quick Change. Its panel shows the note and screenshots, then Changes, PRs and Activity as in [Work on This](/docs/agents/work-on-this/). Closing a running one asks to wrap up first.
