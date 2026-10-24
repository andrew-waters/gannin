---
title: Specialists and workflows
description: Write your team's own agents, chain them into workflows for reviews and other agent work, and route PRs and issues to them.
sidebar:
  order: 17
---

Every piece of agent work Gannin starts (a review, Work on This, Quick Change, Ask, Planning, Design and Refine, and a scheduled [routine](/docs/agents/routines/)) runs through a workflow: a chain of steps, each run by a [specialist](/docs/concepts/specialists-and-workflows/). With no workflows set up, each activity runs Gannin's default, a single step that does exactly what that page of these docs describes. The team's workflows and specialists are kept in the project's harness, so everyone shares them. You can also keep your own, marked **Just me**, which stay on your Mac and never reach the harness: a manager might aim a specialist and a workflow at one person's pull requests, for instance.

## Specialists

Harness › Specialists lists the project's specialists, with your own under **Just me** above the team's. New Specialist (in the toolbar) opens its editor, and so do Edit Specialist on a specialist's page or its right-click menu, Edit on one of yours, and Edit Specialist in a workflow step's inspector:

- **Kept for**: **The team** commits it to the harness for everyone's workflows. **Just me** saves it in Gannin on this Mac only, and only your own workflows can use it. When a review posts or records what one of yours found, it's called "Reviewer" (or "Reviewer 1", "Reviewer 2" and so on), so its name never reaches GitHub or the harness, and the person it's aimed at doesn't see it.
- **Title** and **Name**: the name is how workflow steps refer to it, and its file in the harness, `specialists/<name>.md`.
- **Summary**: a line on what it's for.
- **Defaults**: its **Provider** (Claude Code, or a one-shot CLI such as Junie), **Model** and **Focus**. A workflow step can set its own, which win over these. Model is the same menu as in [Settings › General](/docs/settings/app/general/), and a one-shot CLI such as Junie picks its own model, so it has none to set. Left as "Each person's", the step runs with whatever each teammate picked in Settings › General.
- **Soul**: who it is, what it knows about your code, what it looks for and what it leaves to others, in Markdown. It's told to the agent before anything else, ahead of the team's prompts. Gannin's own instructions (the PR or issue, the worktrees, and how a review ends) and the project's review config still apply.

Draft with Claude can write one with you. Commit to Harness commits a team one (Save keeps one of yours), and Delete removes it, after asking. A specialist written by hand with prose only, and no front matter, still works.

## Building a workflow

Harness › Workflows shows the workflows for one activity at a time: pick Reviews, Work on This, Quick Change, Ask, Planning, Design and Refine or Routines in the toolbar (and the project, when the org has several). The menu at the top lists the activity's workflows: Gannin's own, which is always there and can't be changed, the team's, and yours, marked "just me". Beside it, a tag says whose the one showing is: **Gannin's**, **Team** or **Just me**.

- **New** makes a workflow of one step, and **Duplicate** copies the one showing; both ask whether it's kept for **Just me** or **The team**. A copy of one with your own specialists in it can only be yours. **Rename** and **Delete** change your own and the team's.
- **Make My Default** has the activity run it for you unless a routing rule says otherwise. Defaults are each person's: the team doesn't set one, so someone new runs Gannin's until they pick their own.
- A team workflow can only use the team's specialists, since it's committed for everyone; to use one of yours, Duplicate it as Just me.
- The workflow is drawn as nodes, left to right: where it starts, each stage as a column, and where it ends. Steps in one column run at the same time and join before the next column. A step is told what earlier columns found, never what the steps beside it found.
- **Beside** adds a step to a column, and **Stage** adds a column at the end. Right-click a step to move it earlier or later, or remove it.
- Click a step to set it in the inspector: its **Specialist** (or none, for Gannin's own prompt), **Provider**, **Model** and **Focus**, and for a review step its **Rounds**.
- Beneath, the most passes the workflow can make: each step's rounds, added up by provider and model. There's no estimate of cost or time. A review workflow whose first stage has no Claude Code step (only Junie, say) also runs Gannin's own reviewer there, as a review needs one Claude Code session to hold it, and that pass is counted too.

### Review steps and rounds

Every review step is read-only: it can't edit code, push or approve. A round is another pass over the same diff, told what its earlier rounds found and asked for what they missed; the step stops early when a round finds nothing new. A step on a one-shot CLI runs on this Mac in a throwaway copy of the PR, and is skipped (and the review says so) where the CLI isn't installed or signed in, or the review runs on a server. How a run comes together into one review is on [Review with Claude](/docs/agents/reviews/#review-workflows).

### Sessions

A workflow for Work on This, Quick Change, Ask, Planning, Design and Refine or Routines has exactly one step that is the session you type in, marked **Session**. Make This the Session (right-click) moves it to another step. Its specialist's soul and focus, provider and model are the session's. Steps before it run once, before the session first starts, and add what they write to its brief. Steps after it review each pull request the session opens, in the background, and the session's side panel says when one has started. Only Claude Code runs sessions for now.

## Routing

Reviews and Work on This can send work to a workflow by rules, listed beneath the nodes. **Mine** shows your rules, kept on this Mac, which can send work to any workflow; **The team's** shows the shared ones, which can only send to team workflows. Each rule names a workflow and what it matches, as comma-separated lists where any entry matches:

- Reviews: **Repos**, **Authors**, **Labels** and **Paths** (globs on the files the PR changes: `docs/` for a folder, `**/*.sql` anywhere).
- Work on This: **Repos**, **Labels** and **Issue types**.

The **+** beside Repos, Authors, Labels and Issue types adds one Gannin already knows: the project's repos then the rest of the org's, its members and recent PR authors, and the labels and issue types on its issues. Anything else can still be typed, such as a repo's name alone or a label Gannin hasn't seen.

Your rules are checked first, in order, then the team's, and the first that matches picks the workflow; with none matching, your default runs. Automatic reviews follow the same rules.

## Picking one for a run

When the activity has workflows besides Gannin's (the team's or yours), starting it by hand (Review with Claude, Work on This, Quick Change, Ask, a new plan and New Design and Refine) has a **Workflow** choice: as routed (naming the workflow the rules give this PR or issue), or any of the activity's workflows (yours marked "just me") for this run only, with the most passes it can make. For a review, rules on authors, labels and paths are checked as it starts, so the choice names the workflow its repo alone would get.

## Sharing with the team

Team specialists are committed when you save them. Team workflow edits wait as the team's pending changes: the sidebar shows "changes to commit", and Review commits them to the project's harness once you confirm. Teammates get them on their next harness refresh. The file is `.gannin/agent-workflows.json`; a Mac on an older Gannin ignores it. Your own specialists, workflows, rules and default are never in it: they're kept in Gannin's database on this Mac, beside your starred orgs, and changing them asks for no commit.
