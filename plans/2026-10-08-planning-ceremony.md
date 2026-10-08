---
type: plan
status: Draft
summary: Planning as a live team ceremony under Rituals. Claude interviews the room with question cards, scouts the code when a question needs it, and fills in the requirement, scouting, breakdown and decisions as it goes. On Agree, the plan and requirement are committed to the harness and the sub-issues are made. At the end, Claude offers to save what worked as skills, prompts and learnings.
issues: [andrew-waters/gannin#51]
domains: [planning, sessions, harness]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Planning ceremony

## Context

Gannin already has most of planning's parts, but they're scattered and built for one person:

- **Planning sessions** (`Sessions/PlanningSession.swift`): a Claude Code terminal in the
  harness that asks questions and writes `plans/<date>-<slug>.md`. Documents can be shared in.
  What Claude found and proposed lives only in the scrollback and the file.
- **Draft Issues** (`Planning/DraftIssues.swift`): Claude breaks a plan or requirement into
  issues, which are edited in a sheet and then made as sub-issues on the workflow board.
- **Question cards** (`SessionQuestionCard`): AskUserQuestion's questions and options drawn as
  tiles with an Other field, answered by `SessionStore.answer`.
- **Prioritisation** (`Meetings/PrioritisationView.swift`), a ceremony run on the shared screen
  with a presenting mode.
- **Harness prompts, skills and learnings**, each with an editor that commits one file
  (`HarnessPromptEditor`, `HarnessSkillEditor`, `HarnessLearningEditor`).

The review tab (`PullRequestReviewView`) is the bar to match. Claude works behind it and ends
with structured output, which Gannin draws as findings to keep, edit or dismiss, with the
conversation beneath. Nothing reaches GitHub until Post Review.

## Decisions

These came from an interview on 8 October 2026.

### Ceremony shape

- **Live, all of it.** The team plans together in one meeting: the interview, scouting,
  breakdown and agreement. There's no async prep and no async sign-off.
- **One facilitator** drives Gannin on the shared screen. The room answers and the facilitator
  picks or types the answers. The page has a presenting mode, as Prioritisation's does: larger
  text, with editing controls put away until they're needed.
- **No agenda.** Each session is started on the spot. There's no queue, team file or board
  status to hand items over from Prioritisation.
- **How it differs from Prioritisation:** Prioritisation decides *what* and *when*. Planning
  decides *how*, and *in what pieces*.

### Inputs

Plan This starts a session from:

- **Any issue**, from its drawer, its context menu or the issue window.
- **A free topic**, typed into New Planning Session. A parent issue is made at Agree.
- **A field note** from Prioritisation (Plan This in its menu). The note is linked to the
  parent at Agree.
- **A harness requirement**, from its page. Its content seeds the Requirement pane.

### The interview

- **Claude interviews the room** with question cards: one question at a time, options as
  tiles, and an Other field for whatever the room says instead. It's AskUserQuestion, so the
  existing hook, `SessionQuestionCard` and `SessionStore.answer` carry it. The card is drawn
  large in the workspace rather than floating over a terminal.
- **The panes fill in as answers come.** Claude keeps the session's state in one file in its
  worktree (`.worktrees/plan-<slug>/planning.json`): the requirement (goal, why, non-goals,
  acceptance, open questions), scouting findings, the breakdown and decisions. The edit hook
  already tells Gannin when a file changes, so the panes redraw as Claude writes. The
  facilitator can edit any pane directly; those edits are sent to Claude with the next answer.
- **The interview is guided by the harness's planning skills and prompts**, picked when the
  session starts as they are now (`SessionLaunchSheet`, `use: planning`). This is how saved
  interview skills shape the next interview.

### Scouting

- **Claude asks to scout.** When a question depends on the code, Claude says so on a card
  ("Before asking about the API, I'll look at how billing calls it") and reads the code
  in the repos' clones (`projects/<name>`, or a worktree it adds), read-only. Then it carries on.
  The facilitator can also ask for a scout from the composer.
- **Findings land on the Scouting pane** (repo, `path` or `path#L10-L24`, what's there and why it
  matters), each with Keep and Dismiss, and they open at their lines in the editor or the
  Repositories page. While Claude scouts, the pane shows what it's reading so the room can follow.

### Outputs

On Agree:

- **A plan** in `plans/<date>-<slug>.md` following `STANDARDS.md`: front matter (`issues`
  naming the parent, `agreed_by`), then `## Requirement`, `## Scouting`, `## Breakdown` and
  `## Decisions`.
- **A requirement** in `requirements/`, the long-lived what and why, which the plan links to. If
  the session started from a requirement, that document is updated rather than a new one made.
- **Sub-issues** under the parent (the issue, or a new one for a topic or note) on the workflow
  board, made through Draft Issues' writes, each linking the plan so Work on This briefs it.

Estimates are out of scope.

### Sign-off

The facilitator ticks who was present and presses Agree. A confirmation lists everything that
will be written: the harness files (one commit) and each issue. Nothing is written before then.
The people ticked go in the plan's `agreed_by`.

### Saving what worked

After Agree, Claude offers to save what made this session go well, as a list to tick (`saves`
in its final output). Each one opens in its existing editor to adjust before it's committed:

- **Interview questions** as a skill (`skills/`), such as "interviewing for a billing change",
  which future planning sessions can pick.
- **Prompts the room typed** to steer Claude, as harness prompts with `use: planning`.
- **Breakdown patterns** as a skill: how this kind of work was split up.
- **Learnings**: rules and reasons the room stated about the code, as learnings for that repo
  (`ProposedLearning`, as reviews suggest them).

### Relationship to existing features

- **Planning sessions** become this workspace. Ad hoc solo planning uses the same UI from the
  Claude Code window, and the terminal stays reachable beneath for anything the panes don't cover.
- **Draft Issues** becomes the Breakdown pane, filled during the interview and edited in place.
  The sheet stays for harness documents outside planning.
- **Work on This** on a sub-issue already briefs the documents about its parent, so the plan's
  scouting carries into the engineer's session.
- **Epics:** a planned parent with sub-issues shows there with its plan.

### Spec stages (revised 8 October 2026)

After trying the first version, planning became a spec built in stages, in the spirit of spec-driven
development (Kiro's requirements, design and tasks; spec-kit's specify, plan and tasks):

- **Context:** what the room gives to read first.
- **Requirements:** what and why, not how, ending in acceptance criteria with ids (R1, R2), each
  testable ("When X, the system shall Y"). The code is looked at only when a question depends on it.
- **Design:** how. This is where the code is scouted (areas, patterns, risks) and the approach is
  settled.
- **Tasks:** the pieces, each naming the criteria it satisfies, so Agree can flag any criterion no
  task covers.
- **Agree.**

Requirements, Design and Tasks are each a loop that ends when the room approves it. Any stage can go
back to an earlier one with a reason: that stage reopens with a new round, and the stages after it
are marked Recheck until they're approved again. The plan is written as Requirement, Design and
Tasks, with each task's issue listing the criteria it satisfies. The earlier refine and scout loop
is gone; sessions from before it aren't carried over.

## Where it lives

- **Rituals › Planning** (`WorkloadTab.planning`), beside Standup and Prioritisation. It lists
  this project's planning sessions (in progress and agreed) with New Planning Session, and
  opens one as its workspace.
- **The workspace** (`PlanningWorkspaceView`) is laid out like the review tab. The question card
  is on top. Requirement, Scouting, Breakdown and Decisions are parts in a list beside the
  selected part. The conversation and composer are beneath, and present, Agree and save are in
  the bar. The same view is the session's tab in the Claude Code window.

## Slices

1. **Live interview workspace.** Rituals › Planning, Plan This, the workspace with question
   cards, panes fed by `planning.json`, scouting on request, the breakdown, presenting mode and
   Agree (plan, requirement and sub-issues).
2. **Save what worked.** The end-of-session offer, through the existing skill, prompt and
   learning editors.
3. **Follow-ups.** Field note and requirement inputs, if they don't fit in slice 1. Then the
   Board Hygiene flag for issues in progress with no plan.

## Open questions

- Should the shape of `planning.json` be a harness standard, so other tools can read a session
  in progress, or should it stay Gannin's own?
- Should the conversation beneath be the claude terminal itself, or a transcript view like the
  review tab's, with the terminal one click away?

## Tasks

- [ ] Iterate on the clickable mock (https://claude.ai/artifact/7zGbJqBa8VXvg3jsH4e6sG) until the workspace is right
- [ ] Agree this with the team (comment on andrew-waters/gannin#51)
- [ ] Split andrew-waters/gannin#51 into sub-issues, one per slice
- [x] Slice 1: live interview workspace (`PlanningWorkspaceView`, `PlanningAgreeSheet`,
      `PlanningPage`, Plan This); field notes and requirements as inputs still to do
- [ ] Try slice 1 end to end with the team
- [ ] Slice 2: save what worked
- [ ] Slice 3: follow-ups
