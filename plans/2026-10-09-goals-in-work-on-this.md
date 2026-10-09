---
type: plan
status: Done
summary: Work on This puts the project's org-wide goals into the session's brief, the ones a change can move (PR size, files changed, cycle time and the like), as guidance the agent may set aside when it says why in the pull request.
issues: [andrew-waters/gannin#70]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# The project's goals in a Work on This brief

## Context

An agent started with Work on This wasn't told what the team measures, so it could make a large,
sprawling change where the team watches PR size and files changed. The goals already exist: the
project's scorecard (`OrgConfig.measurables`, its `scorecard.json`, else the Settings › Goals
targets seeded as weekly ones), which the Dashboard and Scorecards read.

## Approach

- `SessionBrief.make` takes the project's measurables and adds a Goals section before Working
  here (`SessionBrief.goalsSection`).
- Only org-wide goals (no team) with a target and a metric a change moves are listed, each with
  its target and what it asks of the change (`SessionBrief.advice`). Review metrics, open PRs,
  issue cycle time and numbers entered by hand are left out.
- The section says they're guidance: set one aside when the issue is better served, and say
  which and why in the PR description's Why. `skills/create-pull-request.md` says the same.
- No goals with targets, no section: the brief is as before.
- The goals aren't shown or edited before the session starts; the brief is committed to the
  harness, and the launch sheet's note can tell the agent otherwise.

## Tasks

- [x] Goals section in `SessionBrief`, passed from `WorkOnThisLauncher.start`
- [x] Why in `skills/create-pull-request.md`
- [x] Tests (`SessionBriefGoalsTests`)
- [x] CLAUDE.md
