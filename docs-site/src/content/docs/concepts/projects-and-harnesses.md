---
title: Projects and harnesses
description: What a project is, what its harness holds, and why it's a repo.
sidebar:
  order: 2
---

## A project

A project is the unit a window works in: a name, the repos it covers, and the boards it lists. You pick it from the project menu above the org at the foot of the sidebar, and every page narrows to its repos. A project covering no repos in particular covers them all.

## Its harness

Every project has a **harness**: a GitHub repo beside the code that holds what the team decides and writes down about it.

- **Team settings**, as files under `.gannin/`: the issue workflow, investments, goals, the scorecard and more ([where things are kept](/docs/concepts/where-things-are-kept/) lists them).
- **Documents**: plans, requirements, findings, research, and the `STANDARDS.md` they follow. They're listed under Harness in the sidebar.
- **Instructions for agents**: `skills/`, `prompts/` and `learnings/` (rules and reasons people gave in review).
- **Records**: what each agent session and review did, under `sessions/` and `.gannin/reviews/`, and each Design and Refine session under `refines/`, with its screenshots, listed under Harness › Refines.
- **Where sessions run**: Claude Code works in a checkout of the harness, with each repo it touches cloned under `projects/` and each issue's worktrees under `.worktrees/`. Both are kept out of the harness's own git.

Because it's a repo, it has history, review and permissions like any other: whoever can read the harness can read the team's settings and documents, and changes to them are commits.

A harness can also be the code repo itself, when a project is one repo. Then it has no `projects/` folder, and sessions make a worktree of it.

## Home

The org's first project is its **home**. Its harness holds the org-wide settings as well as its own. You can make another project home in [Org settings › Projects](/docs/settings/org/projects/), and Gannin offers to copy the org-wide files committed in the old home's harness across.
