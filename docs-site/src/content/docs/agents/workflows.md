---
title: Specialists and workflows
description: Write your team's own agents, chain them into workflows for reviews and other agent work, and route PRs and issues to them.
sidebar:
  order: 17
---

Every piece of agent work Gannin starts (a review, Work on This, Quick Change, Ask, Planning, and Design and Refine) runs through a workflow: a chain of steps, each run by a [specialist](/docs/concepts/specialists-and-workflows/). With no workflows set up, each activity runs Gannin's default, a single step that does exactly what that page of these docs describes. Workflows and specialists are kept in the project's harness, so the whole team shares them.

## Specialists

Harness › Specialists lists the project's specialists. New Specialist (in the toolbar) and Edit Specialist (right-click one) open its editor:

- **Title** and **Name**: the name is how workflow steps refer to it, and its file in the harness, `specialists/<name>.md`.
- **Summary**: a line on what it's for.
- **Defaults**: its **Provider** (Claude Code, or a one-shot CLI such as Junie), **Model** and **Focus**. A workflow step can set its own, which win over these.
- **Soul**: who it is, what it knows about your code, what it looks for and what it leaves to others, in Markdown. It's told to the agent before anything else, ahead of the team's prompts. Gannin's own instructions (the PR or issue, the worktrees, and how a review ends) and the project's review config still apply.

Draft with Claude can write one with you. Commit to Harness commits the file, and Delete removes it, after asking. A specialist written by hand with prose only, and no front matter, still works.

## Building a workflow

Harness › Workflows shows the workflows for one activity at a time: pick Reviews, Work on This, Quick Change, Ask, Planning or Design and Refine in the toolbar (and the project, when the org has several). The menu at the top lists the activity's workflows; Gannin's default is always there and can't be changed.

- **New** makes a workflow of one step, and **Duplicate** copies the one showing. **Rename** and **Delete** change your own. **Make Default** has the activity run it unless a routing rule says otherwise.
- The workflow is drawn as nodes, left to right: where it starts, each stage as a column, and where it ends. Steps in one column run at the same time and join before the next column. A step is told what earlier columns found, never what the steps beside it found.
- **Beside** adds a step to a column, and **Stage** adds a column at the end. Right-click a step to move it earlier or later, or remove it.
- Click a step to set it in the inspector: its **Specialist** (or none, for Gannin's own prompt), **Provider**, **Model** and **Focus**, and for a review step its **Rounds**.
- Beneath, the most passes the workflow can make: each step's rounds, added up by provider and model. There's no estimate of cost or time. A review workflow whose first stage has no Claude Code step (only Junie, say) also runs Gannin's own reviewer there, as a review needs one Claude Code session to hold it, and that pass is counted too.

### Review steps and rounds

Every review step is read-only: it can't edit code, push or approve. A round is another pass over the same diff, told what its earlier rounds found and asked for what they missed; the step stops early when a round finds nothing new. A step on a one-shot CLI runs on this Mac in a throwaway copy of the PR, and is skipped (and the review says so) where the CLI isn't installed or signed in, or the review runs on a server. How a run comes together into one review is on [Review with Claude](/docs/agents/reviews/#review-workflows).

### Sessions

A workflow for Work on This, Quick Change, Ask, Planning or Design and Refine has exactly one step that is the session you type in, marked **Session**. Make This the Session (right-click) moves it to another step. Its specialist's soul and focus, provider and model are the session's. Steps before it run once, before the session first starts, and add what they write to its brief. Steps after it review each pull request the session opens, in the background, and the session's side panel says when one has started. Only Claude Code runs sessions for now.

## Routing

Reviews and Work on This can send work to a workflow by rules, listed beneath the nodes. Each rule names a workflow and what it matches, as comma-separated lists where any entry matches:

- Reviews: **Repos**, **Authors**, **Labels** and **Paths** (globs on the files the PR changes: `docs/` for a folder, `**/*.sql` anywhere).
- Work on This: **Repos**, **Labels** and **Issue types**.

Rules are checked in order and the first that matches picks the workflow; with none matching, the default runs. Automatic reviews follow the same rules.

## Picking one for a run

When the activity has workflows of your own, starting it by hand (Review with Claude, Work on This, Quick Change, Ask, a new plan and New Design and Refine) has a **Workflow** choice: as routed (naming the workflow the rules give this PR or issue), or any of the activity's workflows for this run only, with the most passes it can make. For a review, rules on authors, labels and paths are checked as it starts, so the choice names the workflow its repo alone would get.

## Sharing with the team

Specialists are committed when you save them. Workflow edits wait as the team's pending changes: the sidebar shows "changes to commit", and Review commits them to the project's harness once you confirm. Teammates get them on their next harness refresh. The file is `.gannin/agent-workflows.json`; a Mac on an older Gannin ignores it.
