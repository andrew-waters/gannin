---
type: requirement
status: in-progress
summary: "Decouple Gannin's agent work from Claude by running every activity through workflows of user-defined agents on any supported provider, starting from single-step defaults that behave as today, so the team can try specialist reviewers, other providers and chained steps without changing how each activity works."
issues: [andrew-waters/gannin#466]
plans: [plans/2026-10-24-review-work-with-user-defined-specialist.md]
---

# Workflows for every agent activity, with specialist agents and any provider

## Problem

Reviewing work goes through a single reviewer setup (Review with Claude). There is no way to define specialist reviewers with their own focus, or to run one piece of work through several focused reviews in a set order. Nobody is hurting from this yet: the motivation is exploratory, to find out whether chained specialist reviews give better results than one generalist pass.

## Goal

Decouple Gannin's agent work from Claude by running every activity through workflows of user-defined agents on any supported provider, starting from single-step defaults that behave as today, so the team can try specialist reviewers, other providers and chained steps without changing how each activity works.

## Who it's for

Anyone using Gannin's agent activities (reviewing PRs, working on issues, Ask, Quick Change, Planning, Design and Refine) who wants specialist agents, chained steps, routing or another provider, and the team that shares them through the harness.

## Requirements

1. User-defined specialist agents, each with a soul.md style definition, created, edited and deleted by the user (no fixed set shipped)
2. Workflows: chains of steps that each set agent, provider and model, focus and (for review steps) number of rounds
3. A node-style visual editor for building and editing workflows
4. Each activity has a default workflow; routing rules can pick another, and a hand-started run can choose another workflow for that run
5. Running a review through a workflow's steps in order, with every step's results visible
6. Agents and workflows are files in the team's harness, committed and shared with the team
7. Workflows review pull requests, as Review with Claude does: any PR the user is reviewing, often a teammate's, with findings posted to the PR
8. Extends Review with Claude: today's reviewer is the review activity's shipped default workflow (one step, one round), so auto review, the approval queue and posting behave as now until another workflow is picked, built or routed to
9. A round is another read-only pass of the step's agent on the same diff, given the earlier rounds' findings and asked for what they missed; a step stops early when a round adds no new findings. Nothing is fixed or edited during a run
10. Steps don't gate each other: every step runs and adds its findings, and the run's verdict is the strictest step's verdict
11. A workflow is a chain of stages; a stage holds one step or several parallel steps that run at the same time and join before the next stage. A step sees the findings of earlier stages, not of steps running beside it
12. A run posts one GitHub review: findings from every step and round merged by file and line, each labelled with its agent, under one summary, through the existing Post Review and posting rules. Gannin shows each step's and round's findings
13. A step runs on a provider: Claude Code (any model it accepts), or for one-shot steps one of the extra reviewer CLIs Pair review supports (such as Junie)
14. A step whose extra CLI can't run (not installed or signed in on this Mac, or a sandboxed review) is skipped and marked as not run in the run and the review summary; the other steps go ahead
15. Before a run starts, show the most passes it can make (steps times rounds, by model or CLI); no money or time estimate
16. An agent's soul.md is Markdown prose (who it is, what it looks for) with a short front matter: name, default model or CLI, default focus. The review config (ignore, path instructions, checks, tone) still applies to every agent
17. Creating, editing or deleting an agent or workflow writes the harness files and, after the user confirms, commits and pushes them as other harness data is; teammates get them on their next harness sync
18. Workflows are the decoupling mechanism: each activity (reviewing a PR, coding on an issue, Ask, Quick Change, Planning, Design and Refine, and future ones) runs through a workflow, and each has a default single-step workflow that behaves as today
19. Workflow steps name an agent and a provider (Claude Code, or another supported provider), so any activity can run on any supported provider
20. Routing: a review can be sent to a workflow by rules on the PR (such as author, repo or type of change), and an issue picked up for coding can be matched to a workflow; otherwise the activity's default runs. A hand-started run can still pick another workflow
21. An interactive activity's workflow (Work on this, Ask, Planning, Design and Refine) has exactly one interactive step, the session the user types in, on its chosen agent and provider, with optional one-shot steps before it (such as preparing a brief) or after it (such as running a review workflow when the session opens a PR)
22. Ships with a provider abstraction that every activity goes through, with Claude Code moved behind it as the only interactive provider, and Junie (and the other extra reviewer CLIs) available for one-shot steps as today
23. Routing rules are an ordered list per activity in the harness; the first match wins, otherwise the activity's default. Review rules match on repo, PR author, labels and changed paths (globs); coding rules match on the issue's repo, labels and issue type. Automatic reviews follow the same rules
24. Docs: new agents/workflows and concepts pages; Reviews and Auto review updated in full; short notes on Work on this, Ask, Quick Change, Planning and Design and Refine; the Settings reference if a pane changes

## Out of scope

- Branching on a verdict, loops or arbitrary graphs in the workflow editor
- Cost or run time estimates before a run
- Applying fixes during a run: reviews stay read-only; fixing stays with Pair review and the PR's author
- Reviewing plans or other harness documents outside a pull request
- Per-user agents and workflows, or workflows kept in a repo rather than the harness
- A fixed set of agents shipped with Gannin
- Handing an interactive session over from one agent or provider to another mid-task
- Adding further interactive providers (Codex, Gemini and so on): follow-up issues, built on the abstraction

## Acceptance criteria

- **R1** When the user creates, edits or deletes an agent, the system shall write or remove its soul.md in the harness and, after the user confirms, commit and push the change.
- **R2** When an agent's soul.md has front matter for name, default provider and model, and default focus, the system shall use them wherever a step doesn't set its own; an agent with prose only shall still load.
- **R3** The system shall run every agent activity (reviewing a PR, Work on this, Ask, Quick Change, Planning, Design and Refine) through a workflow, through a provider abstraction rather than calling Claude Code directly.
- **R4** When this ships with no workflows changed, the system shall give each activity a default single-step workflow on Claude Code that behaves as the activity does today.
- **R5** When the user builds or edits a workflow in the node view, the system shall let them add, remove and order stages, put one or several parallel steps in a stage, and set each step's agent, provider and model, focus and (for review steps) number of rounds.
- **R6** When the user edits an interactive activity's workflow, the system shall keep exactly one interactive step and allow one-shot steps before and after it.
- **R7** When a workflow or routing rule is saved, the system shall write it to the harness and, after the user confirms, commit and push it; teammates shall see it after their next harness sync.
- **R8** When a review starts (by hand or automatically), the system shall pick the workflow from the first review routing rule that matches the PR's repo, author, labels or changed paths, else the review default; when an issue is picked up for coding, it shall pick from the first coding rule that matches the issue's repo, labels or issue type, else the coding default.
- **R9** When the user starts a run by hand, the system shall show the routed workflow, let them pick another for that run, and show the most passes it can make by provider and model before it starts.
- **R10** When an automatic review starts, the system shall run the routed workflow within the existing draft, dismissal, review window and concurrency rules.
- **R11** When a review run executes, the system shall run stages in order and a stage's steps in parallel, giving each step the findings of earlier stages but not of steps beside it.
- **R12** When a review step has several rounds, the system shall run each round as a read-only pass on the same diff with the earlier rounds' findings, and stop the step early when a round adds no new findings.
- **R13** When a step fails or its provider can't run (not installed or signed in, or a sandboxed session), the system shall mark that step as not run in the run and in the review summary, and still run the other steps.
- **R14** When a review run finishes, the system shall produce one review with findings from every step and round merged by file and line, each labelled with its agent, one summary and the strictest step's verdict, posted only through the existing Post Review and automatic posting rules.
- **R15** When the user opens a finished run, the system shall show each step's and round's findings, and which steps were skipped and why.
- **R16** The system shall never edit code, push to the PR branch or approve automatically during a review workflow run.
- **R17** When a one-shot step runs after an interactive session (such as a review workflow when the session opens a PR), the system shall run it without the user starting it and show its result in the session.
- **R18** When this ships, the docs shall have new agents/workflows and concepts pages, updated Reviews and Auto review pages, workflow notes on Work on this, Ask, Quick Change, Planning and Design and Refine, the Settings reference for any changed pane, and a CHANGELOG entry.

## Open questions

- What the provider abstraction must cover so a later provider can run a session (state, PR detection, changes, wrap-up, modes, sandboxes): settled in design

Planned in [plans/2026-10-24-review-work-with-user-defined-specialist.md](../plans/2026-10-24-review-work-with-user-defined-specialist.md).
