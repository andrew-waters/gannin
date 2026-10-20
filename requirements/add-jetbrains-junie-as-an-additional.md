---
type: requirement
status: in-progress
summary: "A pair review can also use Junie as an extra reviewer, with both reviewers' findings sent back to the working agent together."
issues: [andrew-waters/gannin#420]
plans: [plans/2026-10-20-add-jetbrains-junie-as-an-additional.md]
---

# Junie as an additional pair reviewer

## Problem

A pair review has one reviewer, a second claude session. Two claude sessions share blind spots, and a team can't get a second opinion from a different model family (or from JetBrains Junie, which some use already).

## Goal

A pair review can also use Junie as an extra reviewer, with both reviewers' findings sent back to the working agent together.

## Who it's for

People running pair reviews who want a second opinion from a different model family than claude.

## Requirements

1. A per-project setting (a project is a harness plus its code repos), kept on this Mac, turns on extra reviewers from built-in presets; none on by default; Junie is the only preset
2. Each round runs the claude reviewer and every enabled extra reviewer and merges their findings
3. An extra reviewer runs as a one-shot process in a throwaway copy of the worktree
4. Local sessions only
5. Each finding shows which reviewer raised it

## Out of scope

- Replacing the claude reviewer
- User-defined reviewer commands: adding an agent is a code change
- Presets other than Junie in this version
- Other agents as the working agent, or for auto review, planning, Ask or Quick Change
- Installing or signing in to Junie for the user
- Sharing the setting with the team through the harness
- A per-repository or app-wide setting

## Acceptance criteria

- **R1** When a user opens a project in Org settings › Projects, the system shall offer a Junie reviewer toggle for pair reviews, off by default, kept on this Mac.
- **R2** When a pair review round runs in a session of a project with the Junie reviewer on, the system shall run the claude and Junie reviewers and send their findings to the working agent together, within the existing three-round limit.
- **R3** When Junie runs a review, the system shall run it in a throwaway copy of the session's worktree and discard any change it makes, so the session's worktree is never edited by it.
- **R4** When a session is sandboxed or remote, the system shall show the Junie reviewer as unavailable for it and say why.
- **R5** When Junie is missing, signed out or fails, the system shall report that on the session's panel and still complete the claude reviewer's round.
- **R6** When findings are shown or sent back, the system shall show which reviewer raised each one.
- **R7** When the Junie reviewer is off, the system shall run pair review exactly as it does today.
- **R8** The system shall have tests that cover reading Junie's findings and merging two reviewers' findings.
- **R9** The docs shall change: agents/pair-review.md (the extra reviewer, how to turn it on, what Junie needs, local only) and settings/org/projects.md (the toggle, its default and that it's kept on this Mac), with an Added line under Unreleased in CHANGELOG.md.
- **R10** .claude/rules/sessions-pair-review.md shall record how more than one reviewer is tracked and what a reviewer agent must provide.

## Open questions

- Issue #420's decisions and acceptance criteria say Junie-only, one setting and settings/app/general.md; they need updating to match these requirements.

Planned in [plans/2026-10-20-add-jetbrains-junie-as-an-additional.md](../plans/2026-10-20-add-jetbrains-junie-as-an-additional.md).
