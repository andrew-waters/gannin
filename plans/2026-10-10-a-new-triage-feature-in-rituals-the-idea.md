---
type: plan
status: in-progress
summary: "A Triage ritual that reads each team's own way of marking loose priority (a board field like Now/Next/Later, or labels, with a starter scheme for teams with none) and, in a live session, has AI suggest priorities from issues and other signals."
issues: [andrew-waters/gannin#154, andrew-waters/gannin#155, andrew-waters/gannin#156, andrew-waters/gannin#157, andrew-waters/gannin#158, andrew-waters/gannin#159, andrew-waters/gannin#160, andrew-waters/gannin#161, andrew-waters/gannin#162, andrew-waters/gannin#163, andrew-waters/gannin#164, andrew-waters/gannin#165]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-10
requirement: requirements/a-new-triage-feature-in-rituals-the-idea.md
---

# Triage in Rituals

A Triage ritual that reads each team's own way of marking loose priority (a board field like Now/Next/Later, or labels, with a starter scheme for teams with none) and, in a live session, has AI suggest priorities from issues and other signals.

## Context

- Also looked at: a new triage feature in Rituals that accommodates the different ways teams mark loose priority on GitHub issues (a board field such as Now, Next, Later, labels, and others), with AI bubbling up priorities in an interactive session from issues, MCP connectors and skills (product metrics, health and observability), while still supporting simple cases. Customer feedback is a possible future harness feature.

## Requirement

In full in [requirements/a-new-triage-feature-in-rituals-the-idea.md](../requirements/a-new-triage-feature-in-rituals-the-idea.md).

**Problem:** Whoever owns priority (usually the product lead) sorts the backlog into the team's loose priority buckets (Now/Next/Later on a board field, labels, or similar) every week. It's slow: the issues and the signals that should shape priority (customer feedback, product metrics, health) are scattered, and each team marks priority its own way.

**Goal:** In one weekly pass, every open issue in the project has a priority in the team's own scheme: new issues get one and existing ones are re-checked and moved, with the result written back to GitHub. Success: after the weekly pass no open issue in the project is without a bucket, and the product lead does the pass in Gannin rather than on GitHub.

**Who it's for:** The product lead (or whoever owns priority), weekly.

**Scope:**

1. Let a project define its priority scheme: ordered buckets backed by a single-select field on one board, or by labels
2. Give every open issue a priority in the team's scheme, new ones first, then re-check existing ones
3. Write chosen priorities back to GitHub, confirmed first
4. Run a live Claude Code session beside the queue (as planning does, with the user's MCP connectors and the team's skills) that suggests a bucket with reasons for each issue and can be asked to dig into one
5. Have Claude suggest a bucket for each issue, with its reasons, drawing on the issue, its activity, the harness, and the team's MCP connectors and skills (product metrics, health and observability)
6. A Triage row under Rituals for the weekly pass
7. Prioritisation's Triage list counts an issue as untriaged by the priority scheme, when one is set
8. The queue works without Claude: keys for buckets, skip, back, and write
9. With no scheme set, offer a one-click starter scheme (Now, Next, Later as labels)
10. The team's harness prompts with use: triage (and the skills they name) tell the session what to look at, picked when the session starts

**Out of scope:**

- Priority kept only in Gannin, never written to GitHub (later)
- Customer feedback as a source (a possible future harness feature)
- Counting how often suggestions are accepted
- Priority across projects or orgs: a scheme is per project
- Ranking within a bucket
- Gannin choosing or configuring MCP connectors: they're the user's own in Claude Code

**Acceptance criteria:**

- **R1** When a project's priority scheme is saved, the system shall keep its ordered buckets, each mapped to an option of a single-select field on one board or to a label, as a team file in the project's harness.
- **R2** When no scheme is set and the product lead picks the starter scheme, the system shall propose Now, Next and Later as labels, create any missing labels in the project's repos once confirmed, and save the scheme.
- **R3** The system shall list Triage under Rituals in the sidebar, with the number of the project's open issues that have no bucket.
- **R4** When reading an issue's bucket, the system shall use the scheme's field option or label on GitHub; an issue with none is untriaged, and one with labels of more than one bucket is flagged as conflicting.
- **R5** When the product lead starts a pass, the system shall queue, one at a time, the project's untriaged and conflicting open issues first, then bucketed ones with activity since the last pass (comments, linked PRs, label or field changes), with number keys to pick a bucket and arrows to skip or go back.
- **R6** When the product lead reviews the pass, the system shall list every change and, only once confirmed, write it to GitHub (adding the bucket's label and removing the others', or setting the field and adding the issue to the board if needed), updating the local issue history at once.
- **R7** When Claude Code isn't available or no session is started, the system shall let the product lead triage the whole queue without suggestions.
- **R8** When the product lead starts Triage with Claude, the system shall start a live Claude Code session in the harness with the triage prompts and skills picked at launch, the scheme and the queue's issues.
- **R9** When the session suggests a bucket for an issue, the queue shall show the suggestion with its reasons and the sources it drew on beside that issue, and one key shall accept it.
- **R10** When the product lead asks about the issue in view, the system shall send the question to the session and show its answer without leaving the queue.
- **R11** When a harness prompt says use: triage, the system shall offer it, and the skills it names, when a triage session starts, with its defaults ticked.
- **R12** When a scheme is set, Prioritisation's Triage list shall count an issue as untriaged by the scheme instead of by its workflow board Status.
- **R13** When a pass ends, Triage shall show how many of the project's open issues still have no bucket.
- **R14** When the product lead turns on Re-check all, the system shall queue every open bucketed issue after the untriaged and conflicting ones.
- **R15** When a pass's changes are written, the system shall record the pass's date in the project's triage team file, so the next pass knows what has changed since.

**Decisions:**

- Who feels the triage problem most, and when? **The product lead, on a weekly cadence.**
- What does the weekly triage need to produce? **Every open issue bucketed: new issues get a priority and existing ones are re-checked and moved, written back to GitHub.**
- Which ways of marking priority must v1 support? **A single-select board field (e.g. Now/Next/Later) and labels.**
- What's the smallest version worth shipping? **The triage queue with Claude suggesting buckets, drawing on MCP connectors and skills from the start.**
- How does Triage relate to Prioritisation's Triage list? **A new Triage ritual; Prioritisation keeps its list but reads untriaged from the new scheme.**
- How should Claude's suggestions work? **A live Claude Code session beside the queue writes a suggestion and reasons per issue; the product lead can ask it to dig in; accepting stays a click in the queue.**
- What must the simple case support? **Both: a one-click starter scheme (Now/Next/Later labels) and the queue working without Claude.**
- How does the session know which connectors and skills to use? **The team's harness prompts with use: triage, naming skills and saying which connectors to check, picked at start as Work on This picks prompts. Connectors are whatever the user has in Claude Code.**
- How will you know Triage is working? **The backlog is fully bucketed after each weekly pass, done in Gannin; Triage shows the count still untriaged.**
- Are the requirements right? **Yes, approved as R1 to R13.**
- Are the revised requirements right? **Yes: R5 revised, R14 and R15 added.**

## Design

Triage is a Rituals page (`WorkloadTab.triage`, `Gannin/Triage/`) over a per-project **priority scheme**, with a keyboard queue that works on its own and an optional live Claude session beside it.

**Scheme.** `PriorityScheme` (ordered `PriorityBucket`s: name, colour slot, `githubValue`; tracking by labels or a single-select field on one board) kept as `.gannin/triage.json`, a project team file, edited in Settings › Issues and staged with the other pending harness changes. The label-or-field mapping and the planning and writing of changes come out of investments into a shared `TrackedValue` (`plan` to add/remove labels or set/clear a field, adding to the board; `apply` writing them, creating missing labels, updating the issue history), which investments then use too. Starter scheme: Now, Next, Later as labels, missing labels created once confirmed.

**Reading.** An issue's bucket is its label or field option; none is untriaged, labels of two buckets is conflicting. The sidebar row shows the untriaged count; Prioritisation's Triage list uses the scheme when one is set.

**Queue.** `TriageQueue`, following `InvestmentTriage`: one issue at a time, untriaged and conflicting first (newest first), then bucketed issues with activity since `PriorityScheme.lastPass` (a new optional `IssueRecord.updatedAt`, which comments and label changes move, filled as issues are next fetched, plus the record's board moves, reopenings, sub-issues and linked PRs' dates), or every bucketed one with Re-check all; number keys pick a bucket, arrows skip and go back, choices collect until Review and Write (confirmed, then written one at a time with progress). Writing a pass stages `lastPass` in `.gannin/triage.json` with today's date, committed with the other pending harness changes. At the end, the count still untriaged.

**With Claude.** Start with Claude shows `SessionLaunchSheet` with prompts and skills of the new `PromptUse.triage`, then `SessionStore.startTriage` makes a `CodeSession` with `TriageInfo`, always on this Mac in the harness (so the user's MCP connectors are there), folder `.worktrees/triage-<date>-<id>/`. Gannin writes the scheme and queue there (`queue.json`); claude writes `suggestions.json` (per issue: bucket, reasons, sources it used, what it couldn't reach), working a few issues ahead of where the product lead is (Gannin writes the current position), read on each `changed` signal as planning's state is. The queue shows the suggestion, reasons and sources; Return accepts. Ask about this issue pastes the question to the session with the issue named (`SessionStore.submit`), and the answer shows in a drawer with the terminal, as planning's does.

**Why.** It reuses the investments model and writer, the investment queue, team files, prompt uses and the planning session's state-file loop, so the new code is mostly the page, the session's instructions and the scheme editor.

**Naming.** Prioritisation's one-shot Triage with Claude (`TriageWithClaudeSheet`) is renamed Suggest Fields, so Triage means only the ritual.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Meetings/PrioritisationView.swift`: Rituals > Prioritisation already has a Triage list: open issues with no Status on the workflow board, or not on it. A new Triage ritual overlaps with it.
- `andrew-waters/gannin` `Gannin/Meetings/PrioritisationView.swift#L300-L330`: triage(board:) counts an issue as untriaged when it has no Status on the workflow board; R12 switches it to the scheme when one is set.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/`: Planning sessions (CodeSession.planning, PlanningState) already run claude live in the harness, writing a JSON state file that Gannin reads on each changed signal. Triage can follow that.
- `andrew-waters/gannin` `Gannin/Harness/HarnessPrompts.swift`: HarnessPrompt's use list (work, review, planning, ask, session) gains triage; PromptPickerSections already lets a launch pick prompts and skills.
- `andrew-waters/gannin` `Gannin/Investments/InvestmentConfig.swift#L88-L160`: InvestmentTracking (.gannin, .labels, .projectField(number, title, field)) and InvestmentCategory.githubValue: exactly the label-or-field mapping a priority bucket needs.
- `andrew-waters/gannin` `Gannin/Investments/InvestmentWrites.swift#L9-L160`: InvestmentChange.plan works out add/remove labels or set/clear a field (adding to the board); InvestmentWriter.applyOnGitHub writes them, creates missing labels and updates the issue history; InvestmentConfirmation confirms. Triage should share this rather than copy it.
- `andrew-waters/gannin` `Gannin/Investments/InvestmentTriage.swift`: The one-at-a-time queue: issue card, number keys for categories, arrows to skip or go back, the suggestion marked, choices collected until Review. The Triage queue follows it.
- `andrew-waters/gannin` `Gannin/Harness/HarnessTeamData.swift#L8-L29`: TeamFile lists per-project files (recap.json, prioritisation.json); the scheme becomes .gannin/triage.json, a project file staged and committed with the other pending changes.
- `andrew-waters/gannin` `Gannin/Harness/HarnessPrompts.swift#L7-L25`: PromptUse gains .triage; launchInstructions(use:) and PromptPickerSections already handle picking prompts and skills.
- `andrew-waters/gannin` `Gannin/Sessions/PlanningSession.swift#L92-L125`: startPlanning makes a CodeSession in the harness with its own .worktrees/<branch>/ folder, a prompt with instructions for a JSON state file, and the picked prompts. A triage session follows it.
- `andrew-waters/gannin` `Gannin/Sessions/PlanningWorkspace.swift#L247-L270`: refreshPlanning reads the state file on each changed signal (locally or over ssh) and decodes it leniently. Triage reads its suggestions the same way.

**Risks:**

- `andrew-waters/gannin` `STANDARDS.md`: The harness has no STANDARDS.md or plans/_template.md; the plan will follow the shape of the existing plans (front matter type, status, summary, issues, domains, touches, owner).
- `andrew-waters/gannin` `Gannin/Sessions/ClaudeRunner.swift`: MCP connectors live in each person's own Claude Code setup, not Gannin's. ClaudeRunner runs claude -p with only the tools it's given, so suggestions that need connectors depend on what the product lead has connected, and need tools allowed explicitly.
- `andrew-waters/gannin` `Gannin/Meetings/TriageWithClaude.swift`: Triage with Claude already exists on Prioritisation: a one-shot claude -p suggesting board fields, investment category and agent fit for the newest 20. Two Claude triage features will confuse unless their names and roles are kept apart.
- `andrew-waters/gannin` `Gannin/Sessions/ClaudeRunner.swift`: MCP connectors are each person's own in Claude Code, so the session must run on this Mac (as Ask does), never in a sandbox or on a server where they may not be set up, and must say what it couldn't reach.
- `andrew-waters/gannin` `Gannin/Investments/InvestmentWrites.swift`: A backlog of hundreds of issues means hundreds of writes; they're a point each and one at a time, which is fine, but the session suggesting all of them up front costs tokens. Suggest a little ahead of where the product lead is.
- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift`: IssueRecord keeps no updatedAt (only IssueTextIndex does), so 'activity since the last pass' needs it added as an optional field (as author was) and asked for in the issue queries; until refetched, older records fall back to their board moves, reopenings, sub-issues and linked PRs.

**Decisions:**

- How should Triage reuse the investments label/field code? **Extract a shared TrackedValue (plan and write labels or a board field) that investments and Triage both use, refactoring investments first.**
- What happens to Prioritisation's existing Triage with Claude? **Renamed Suggest Fields, kept on Prioritisation, so Triage means only the new ritual.**
- Which bucketed issues come up for re-check? **Those with activity since the last pass, after untriaged and conflicting ones; Re-check all as a toggle. The last pass's date is kept in the project's triage file.**
- Is the design right? **Yes, approved.**

## Tasks

1. [andrew-waters/gannin#155](https://github.com/andrew-waters/gannin/issues/155) Extract TrackedValue from investments (satisfies R6)
2. [andrew-waters/gannin#156](https://github.com/andrew-waters/gannin/issues/156) Priority scheme model and team file (satisfies R1, R4)
3. [andrew-waters/gannin#157](https://github.com/andrew-waters/gannin/issues/157) Scheme editor and starter scheme (satisfies R1, R2)
4. [andrew-waters/gannin#158](https://github.com/andrew-waters/gannin/issues/158) Triage page under Rituals (satisfies R3, R13)
5. [andrew-waters/gannin#159](https://github.com/andrew-waters/gannin/issues/159) Keep updatedAt on issues (satisfies R5)
6. [andrew-waters/gannin#160](https://github.com/andrew-waters/gannin/issues/160) The triage queue (satisfies R5, R7, R14)
7. [andrew-waters/gannin#161](https://github.com/andrew-waters/gannin/issues/161) Review and write a pass (satisfies R6, R13, R15)
8. [andrew-waters/gannin#162](https://github.com/andrew-waters/gannin/issues/162) Prioritisation reads the scheme; rename Suggest Fields (satisfies R12)
9. [andrew-waters/gannin#163](https://github.com/andrew-waters/gannin/issues/163) Triage prompts in the harness (satisfies R11)
10. [andrew-waters/gannin#164](https://github.com/andrew-waters/gannin/issues/164) Start a triage session (satisfies R8, R9)
11. [andrew-waters/gannin#165](https://github.com/andrew-waters/gannin/issues/165) Suggestions and questions in the queue (satisfies R9, R10)

**Decisions:**

- Are the tasks right? **Yes, the 11 tasks are approved.**
