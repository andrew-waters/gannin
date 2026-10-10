---
title: Where things are kept
description: What lives on this Mac, what lives in the harness, and what stays on GitHub.
sidebar:
  order: 1
---

Gannin keeps things in three places. Knowing which is which tells you who else sees a change and what happens when you clear or sign out.

## GitHub

Pull requests, issues, reviews, boards, checks, releases and repos stay on GitHub. Gannin reads them and keeps a copy on this Mac (below) so pages open quickly. It writes to GitHub only when you ask, and confirms first.

## The harness

When an org has a [harness](/docs/concepts/projects-and-harnesses/), the team's settings live in it as JSON files under `.gannin/`, so everyone reads the same copy on every Mac:

- **Each project's harness:** its project (name, repos, boards) in `project.json`, the issue workflow (`workflow.json`), investments (`investments.json`), goals (`goals.json`), scorecard (`scorecard.json`), recap cadence (`recap.json`), the committed date field (`prioritisation.json`) and notes from the field (`field-notes.json`).
- **The home project's harness also holds the org-wide ones:** views (`views.json`), the working week (`working-week.json`), leave (`leave.json`), excluded repos and people and the Needs Review and Needs the Mac ticks (`exclusions.json`), drafting guidance (`authoring.json`), and each person's dates and time off (`people/<login>.json`).

Plans, requirements, findings, skills, prompts, learnings, session records and review records are in the harness too, as Markdown and JSON.

Changing a team setting applies at once for you and waits as **N changes to commit** at the foot of the sidebar. Review commits them (one commit per harness), or discards them. Changes made by someone else in the meantime are kept.

An org with **no harness** keeps all of its team settings on this Mac instead.

## This Mac

These are yours alone and never leave this Mac:

- All app settings (Gannin › Settings).
- Stars, hidden pull requests and issues, and which harnesses are your projects.
- Where each harness is checked out, automatic review per org, and whether to record sessions without asking.
- Your GitHub token, and sandbox credentials, in the keychain.
- Caches of what was fetched from GitHub (Settings › Storage shows their size, with Clear).
- Agent sessions, routines and their runs.
- Release download history, which GitHub can't give back once lost, so only Erase Everything removes it.

Nothing is synced through iCloud.
