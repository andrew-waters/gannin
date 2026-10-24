---
type: plan
status: done
summary: "Make workflows the way Gannin runs agent work: reviewing, coding on an issue, Ask, Quick Change, Planning and Design and Refine each run through a workflow (a single-step default to start), whose steps name user-defined agents on any supported provider. Reviews and coding can be routed to a workflow by rules."
issues: [andrew-waters/gannin#466, andrew-waters/gannin#492, andrew-waters/gannin#493, andrew-waters/gannin#494]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-24
requirement: requirements/review-work-with-user-defined-specialist.md
---

# Workflows for every agent activity, with specialist agents and any provider

Make workflows the way Gannin runs agent work: reviewing, coding on an issue, Ask, Quick Change, Planning and Design and Refine each run through a workflow (a single-step default to start), whose steps name user-defined agents on any supported provider. Reviews and coding can be routed to a workflow by rules.

## Requirement

In full in [requirements/review-work-with-user-defined-specialist.md](../requirements/review-work-with-user-defined-specialist.md).

**Problem:** Reviewing work goes through a single reviewer setup (Review with Claude). There is no way to define specialist reviewers with their own focus, or to run one piece of work through several focused reviews in a set order. Nobody is hurting from this yet: the motivation is exploratory, to find out whether chained specialist reviews give better results than one generalist pass.

**Goal:** Decouple Gannin's agent work from Claude by running every activity through workflows of user-defined agents on any supported provider, starting from single-step defaults that behave as today, so the team can try specialist reviewers, other providers and chained steps without changing how each activity works.

**Who it's for:** Anyone using Gannin's agent activities (reviewing PRs, working on issues, Ask, Quick Change, Planning, Design and Refine) who wants specialist agents, chained steps, routing or another provider, and the team that shares them through the harness.

**Scope:**

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

**Out of scope:**

- Branching on a verdict, loops or arbitrary graphs in the workflow editor
- Cost or run time estimates before a run
- Applying fixes during a run: reviews stay read-only; fixing stays with Pair review and the PR's author
- Reviewing plans or other harness documents outside a pull request
- Per-user agents and workflows, or workflows kept in a repo rather than the harness
- A fixed set of agents shipped with Gannin
- Handing an interactive session over from one agent or provider to another mid-task
- Adding further interactive providers (Codex, Gemini and so on): follow-up issues, built on the abstraction

**Acceptance criteria:**

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

**Decisions:**

- What does a single Review with Claude pass miss today, and how often does that hurt? **Mostly exploratory: no current pain; the aim is to learn whether chained specialist reviews give better results before investing heavily.**
- Since this is exploratory, what's the smallest first version worth shipping? **The full issue as written: agents, workflows in a node-style editor, a default workflow and per-run overrides. The smaller cuts (linear list editor, agents only, chaining today's reviewer) were offered and declined.**
- Where should agents and workflows live, and who shares them? **In the harness, shared with the team (alongside skills/ and prompts/). Not per-user app settings, and no per-repo override for now.**
- Room asked to go back **Set aside the answers on the relation to Review with Claude, plan reviews, rounds and who fixes; re-ask from the relation to Review with Claude after a misunderstanding.**
- What is the 'work' these review workflows review? **Pull requests, as Review with Claude does: any PR the user reviews, often a teammate's, with findings posted to the PR.**
- Does this extend Review with Claude or replace it? **Extends it: today's reviewer becomes the shipped default workflow, so nothing changes until someone picks or builds another.**
- What does a 'round' of a step mean on a PR review, and what ends rounds early? **A read-only re-pass on the same diff that sees earlier rounds' findings; the step ends early when a round adds nothing new. No fixing, so it works on any PR.**
- Can a step block the steps after it, or does every step just add findings? **Feedback only: every step runs and adds findings; the run's verdict is the strictest step's.**
- What shapes can a workflow take in the node view? **A chain with parallel groups: steps can run side by side and join before the next; no branches or loops.**
- How are a run's findings combined and posted to the PR? **One review: findings merged by file and line, labelled by agent, with one summary; per-step and per-round detail in Gannin.**
- Which models can a step use, and what is shown about cost before a run? **Claude models plus the extra reviewer CLIs Pair review supports (e.g. Junie). Cost display not settled by this answer.**
- When a step's extra CLI can't run, what happens? **Skip that step, mark it as not run in the run and the review summary, and carry on with the rest.**
- What is shown about cost or run time before a workflow run starts? **Pass count only: the most passes the run can make, by model or CLI. No money or time estimate.**
- Which workflow do automatic reviews use, and can the default differ per repo? **One team default in the harness, used by hand-started and automatic reviews; hand-started runs can pick another. No per-repo defaults.**
- What does an agent's soul.md hold, and how does it sit with the existing review config? **Prose plus a small front matter (name, default model or CLI, default focus); the layered review config still applies to every agent.**
- When someone creates or edits an agent or workflow in Gannin, how does the change reach the team? **Gannin commits and pushes the harness change after the user confirms, as with other harness data.**
- Which pages of the user docs does this change? **A new agents/review-workflows page, plus updates to agents/reviews and agents/auto-review (and the Settings reference if editing is in a settings pane).**
- How much of decoupling from Claude belongs in this plan? **Both the session engine and reviews are decoupled in this plan, so coding and review workflows can use any provider. Accepted as a much wider blast radius.**
- What does 'coding workflows that can use any provider' mean? **Workflows are the decoupling: every activity (review, coding on an issue, Ask, Quick Change, Planning, Design and Refine, future ones) has its own workflow with a default single-step one. Reviews can be routed to a workflow by person, repo, type of change and so on; issues can be matched to a coding workflow.**
- In an interactive activity's workflow, what is a step? **One interactive step (the session the user types in), with one-shot steps before or after it. No hand-offs between interactive sessions.**
- Which providers must work when this ships? **Build the abstraction with Claude Code as the only interactive provider; Junie stays for one-shot steps. Other providers come in follow-ups.**
- What can routing rules match on, and how is a rule chosen? **Ordered rules per activity, first match wins, else the default. Reviews: repo, author, labels, changed paths. Coding: issue repo, labels, issue type. Automatic reviews follow them.**
- With workflows behind every activity, which docs pages change? **New agents/workflows and concepts pages; Reviews and Auto review in full; short workflow notes on Work on this, Ask, Quick Change, Planning and Design and Refine; Settings reference if a pane changes.**
- Are the requirements (R1-R18) right? **Yes, approved; move to design.**

## Design

Three layers, built bottom up so each lands and ships on its own with no visible change until the next.

**1. Provider abstraction, Claude Code behind it (no behaviour change).**
An `AgentProvider` protocol with capabilities a provider declares, implemented once by `ClaudeCodeProvider`:
- *Interactive launch*: the start and resume command `SessionScript` builds today (`claudeSteps`, `repoStart`), its flags (model, read-only tools for reviews, routine tool limits) and a settings or hooks generator that writes the existing provider-neutral files (`state`, `pr`, `changed`, `statusline`) `HookFileWatcher` already reads.
- *One-shot*: `ClaudeRunner.ask` (claude -p, streaming or not, local or over ssh) split from the generic `run` script runner, so its ten or so callers go through the provider.
- *Transcript*: locating and parsing the session's transcript into `SessionTranscript` events (today's jsonl reader moves here).
- *Modes* (optional): Shift+Tab and footer reading from `SessionMode`.
- *Sandbox* (optional): image install step, config dir and credentials.
- *Models*: the provider's model list (today's hard-coded ids).
`ExtraReviewer` becomes the one-shot-only providers (Junie), keeping its isolated throwaway copy, timeout and cancel. Rules in sessions-core, sessions-store, sandbox and pair review are updated as the code moves.

**2. Agents, workflows and routing in the harness, plus the workflow runner.**
- *Specialists* (the user-defined agents; 'Agents' stays the name of Claude Code › Agents): a new harness document kind, `specialists/<name>.md` (the soul), parsed like `prompts/`: front matter `name`, `provider`, `model`, `focus`, the body as the persona. Unknown fields kept. Listed in the harness index; edited with a sheet like the prompt editor; written through `HarnessStore.commit` after confirmation.
- *Workflows and routing*: team data in a new `.gannin/agent-workflows.json` (not `workflow.json`, which is the board's), sorted keys, optional fields, pending edits and the three-way merge. Per activity: a list of workflows (stages of one or more steps; a step names an agent, provider, model, focus, rounds and, for interactive activities, which step is interactive), the default's id, and ordered routing rules (reviews: repo, author, labels, path globs; coding: repo, labels, issue type). A missing file or activity means today's built-in single step, so nothing changes until the team writes one.
- *Scope*: per project, like prompts: each project's harness has its own `specialists/` and `.gannin/agent-workflows.json`, and a review or issue uses the harness covering its repo (`harness(covering:)`, keeping its order).
- *Resolver*: activity + PR or issue -> workflow (first matching rule, else default), used by hand-started and automatic runs; a hand-started run can override it.
- *Prompts*: a step's session gets the specialist's soul and the step's focus first, then the team prompts picked as today (defaults per repo, or what the user ticks), then the review config. `prompts/` is unchanged.
- *Interactive activities*: the interactive step is today's CodeSession, launched through its step's provider and model with the agent's soul added to the instructions. One-shot steps before it add to the brief; steps after it run when the session opens a PR (the review workflow routed for that PR) or finishes.
- *Review runs*: each Claude Code step is its own read-only review session (a CodeSession tab, as a review is today) launched with today's review prompt plus the agent's soul and focus and the earlier stages' findings. A step's later rounds are Look Again in the same session, given its earlier rounds' findings, until a round adds nothing. Steps in a stage start together as parallel tabs, grouped under the run. A step on a one-shot-only provider (Junie) runs one-shot in the isolated copy and shows in the run without a terminal. A failed or unavailable step is marked and skipped. When every step has finished, findings merge by file and line with Pair review's merge, labelled by agent, with the strictest verdict, into one run-level review, so Post Review, holds for approval, duplicate checks, records and auto review rules act on one review per run. The single-step default is today's review exactly.
- *Capacity*: the automatic review cap (`AutoReview.maxRunning`) and a review window's reviews at once count running step sessions, not PRs. A stage whose steps don't all fit starts what fits and the rest wait for free slots; hand-started runs aren't capped, as today.

**3. The workflow editor and run views.**
- A node-style editor (new; nothing like it in the app): stages left to right, parallel steps stacked in a stage, drawn connectors, a step inspector for agent, provider, model, focus and rounds, and a pass count. Built in SwiftUI with Canvas for the connectors.
- A Specialists list and editor (Harness › Specialists), and a routing rules list per activity.
- Start review shows the routed workflow, lets the user pick another, and shows the pass count; the review overview shows each step's and round's findings and skipped steps.
- Docs pages, Settings reference and CHANGELOG.

**Why this order**: layer 1 is the riskiest refactor and touches every session, so it lands first, alone, with nothing for users to see; layer 2 delivers review workflows with editing as JSON and the agent sheet; layer 3 is the large UI piece and can follow without blocking either.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/ExtraReviewer.swift`: The only agent seam today: an enum of one-shot CLI reviewers (Junie) run in a throwaway, git-isolated copy of the worktree with timeout, cancel and lenient findings parsing. Its script and outcome split is the shape for one-shot provider steps; isolation and cancel logic should be reused, not copied.
- `andrew-waters/gannin` `Gannin/Sessions/PullRequestReview.swift#L84-L171`: A review is itself a CodeSession (isReviewer) run as a Claude Code terminal session with a long prompt that asks for a fenced JSON block; config is snapshotted on the session. The default review workflow's single step must keep producing exactly this, and extra steps need a way to run the same prompt one-shot.
- `andrew-waters/gannin` `Gannin/Harness/HarnessModels.swift#L6-L31`: HarnessConfig keeps which extra reviewers are on, per Mac, by id, ignoring unknown ids. Provider availability per Mac can follow this, and existing pair review settings must keep working.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L25-L33`: Every interactive activity is a CodeSession started from one script: options() builds --model and --disallowedTools; claudeSteps (L175-190) and repoStart (L287-296) build `claude --session-id/--resume --settings`. This is where the provider's launch command goes.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L327-L432`: Session state comes from Claude Code hooks and statusLine writing files (state, pr, changed, statusline) that HookFileWatcher reads. The file contract is already provider-neutral; only the settings and hook generator is Claude's, and pullRequestHook relies on Claude's hook JSON order.
- `andrew-waters/gannin` `Gannin/Sessions/ClaudeRunner.swift#L34-L96`: The one entry point for one-shot runs (claude -p, text or stream-json, local or over ssh), used by about ten features. run() is also a generic script runner. Split into a provider's one-shot ask and a generic run.
- `andrew-waters/gannin` `Gannin/Sessions/SessionModel.swift#L20-L22`: Model choices are hard-coded Claude model ids, also named in Settings help text. They move to the Claude provider's model list.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Harness/HarnessPrompts.swift#L1-L80`: Team prompts are harness documents (prompts/<name>.md) with front matter for use (work, review, planning, ask, session), default and repos, parsed leniently with unknown fields kept. Agents' soul.md should follow this pattern (a new harness document kind), and PromptUse is the nearest thing to an activity list.
- `andrew-waters/gannin` `Gannin/Harness/HarnessTeamData.swift`: Team data lives in .gannin/*.json with sorted keys, optional fields, pending edits and a three-way merge on commit. Workflows and routing rules fit here, but .gannin/workflow.json already exists for something else, so the file needs another name.
- `andrew-waters/gannin` `.claude/rules/harness.md`: Every harness write is confirmed and goes through HarnessStore.commit (direct commit or PR when branch rules need one). Satisfies the commit-and-push-on-confirm requirement with no new write path. New document kinds must be kept in step with HarnessKind, HarnessFrontMatter, HarnessSkeleton and the harness's STANDARDS.md.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L353`: Pair review merges claude's and extras' findings by file and line and labels them by reviewer only when an extra answered. Review workflows should reuse this merge and labelling rather than add another.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/AgentsPage.swift`: 'Agents' already names Claude Code › Agents (running sessions waiting on you). User-defined agents need a name or place that doesn't clash, in the app and the docs.
- `andrew-waters/gannin` `STANDARDS.md`: This harness has no STANDARDS.md (or plans/_template.md), yet harness parsing follows it. Adding agent documents means updating the standard where it exists and HarnessSkeleton's templates.
- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L254-L460`: The hardest coupling: activity, cost, questions, plans and the review all come from parsing Claude's ~/.claude/projects jsonl transcripts and Claude tool names. A provider needs a transcript adapter producing SessionTranscript events; the fenced JSON review block itself is neutral.
- `andrew-waters/gannin` `Gannin/Sessions/SessionMode.swift#L8-L60`: Permission modes are switched by sending Shift+Tab and reading Claude's TUI footer; routine runs rely on it for auto mode. Mode control has to be an optional provider capability.
- `andrew-waters/gannin` `Gannin/Sandbox/SandboxLaunch.swift`: Sandboxes install Claude Code in the image, mount /root/.claude, seed .claude.json and handle Anthropic credentials. Image, config dir and credentials become per-provider; only Claude needs doing now.

**Decisions:**

- In a multi-step review workflow, how do steps run? **Every step is its own read-only terminal review session (tab); rounds are Look Again in that session; parallel steps are parallel tabs. One-shot-only providers (Junie) still run one-shot.**
- How do workflow runs count against the automatic review cap and review windows? **The cap counts running step sessions; a stage waits for slots when its steps don't all fit.**
- What should user-defined agents be called? **Specialists: Harness › Specialists, specialists/<name>.md. Claude Code › Agents keeps its name.**
- Are specialists and workflows per project or org-wide? **Per project, like prompts; the harness covering the PR's or issue's repo supplies them.**
- When a step's specialist runs and the team also has prompts, what does the session get? **Both: the soul and step focus first, then the prompts picked as today. prompts/ is unchanged.**
- Is the design right? **Yes, approved; move to tasks.**

## Tasks

1. [andrew-waters/gannin#492](https://github.com/andrew-waters/gannin/issues/492) Put Claude Code behind a provider abstraction (satisfies R3, R4)
2. [andrew-waters/gannin#493](https://github.com/andrew-waters/gannin/issues/493) Specialists, workflows and routing, with review workflow runs (satisfies R1, R2, R3, R4, R7, R8, R10, R11, R12, R13, R14, R16, R17)
3. [andrew-waters/gannin#494](https://github.com/andrew-waters/gannin/issues/494) Workflow node editor, run picker and run view (satisfies R5, R6, R7, R9, R15, R18)

**Decisions:**

- Are these three tasks right? **Yes: three tasks in andrew-waters/gannin, in order (provider abstraction; specialists, workflows, routing and review runs; node editor, run picker and run view).**

## From the room

- are we seeing the fix as a unique agent or is it part of the existing initial agent  +prompt? (requirements)
- how would this happen? (requirements)
- Sorry, there is misuindertstanding - can we go bacl to the beginning of the review questions (requirements)
- can we include in here a decoupling of the current engine with claude - this might be a wider blast radius., but having coding workflows and review workflows that can use any provider would be very beneficial (requirements)
- i think we use workflows as a way of decoupling and each actiuvity has its own workflow with a default singular one - that way even asks and quick changes  and anything else in the future can adopt workflows. So design and refine, planning, quick change and asks alongside coding (picking up an issue) and reviewing are all good candidates. On reiviewing and coding, I might want to match the issue with a specific workflow, or for a review, i might want to route it based on the person, repo, type of change etc (requirements)

## Open questions

- What the provider abstraction must cover so a later provider can run a session (state, PR detection, changes, wrap-up, modes, sandboxes): settled in design
