---
title: This Mac
description: "The default: Claude Code runs on your Mac, as you."
sidebar:
  order: 2
---

With no Connect with command and sandboxing off, sessions run on this Mac.

## What it needs

- Claude Code installed and signed in (`claude` in a terminal once).
- git, and ideally gh, signed in.
- A project with a harness, checked out on this Mac. Org settings › Harness says where; by default Gannin finds a checkout in a usual place (such as `~/Code/<owner>/<name>`), else uses one under the workspace folder (`~/Gannin`, set in Settings › General).

## How it works

Work on This starts the issue's session in the harness checkout: it pulls the harness, records the session there (asking first, unless you said not to), puts the brief in the issue's folder (`.worktrees/<branch>/`) and starts Claude Code there. Claude makes a worktree per repo the issue touches, from the shared clones in `projects/`.

## What it protects

Nothing beyond Claude Code's own permission prompts. Claude runs as you, so it can read and change anything you can: other repos, `~/.ssh`, your keychain, cloud credentials. That's usually fine for Attended work. For Unattended sessions and routines, consider a [sandbox](/docs/sessions/sandboxes/).

## How Claude signs in

With your own Claude Code login on this Mac. Gannin never sees it.
