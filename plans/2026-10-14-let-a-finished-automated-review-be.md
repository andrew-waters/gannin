---
type: plan
status: in-progress
summary: "The background reviewer (pair review) on ongoing work finishes and ends. After the user makes more changes, clicking Review Now in the session panel does nothing, so there's no way to launch it again."
issues: [andrew-waters/gannin#350, andrew-waters/gannin#353, andrew-waters/gannin#354, andrew-waters/gannin#355]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-14
requirement: requirements/let-a-finished-automated-review-be.md
---

# Relaunch a finished automated review

The background reviewer (pair review) on ongoing work finishes and ends. After the user makes more changes, clicking Review Now in the session panel does nothing, so there's no way to launch it again.

## Requirement

In full in [requirements/let-a-finished-automated-review-be.md](../requirements/let-a-finished-automated-review-be.md).

**Problem:** The background reviewer on ongoing work finishes (settled, round limit or stopped) and its session is ended. When the user makes more changes and clicks Review Now in the session panel, nothing visibly happens, so they can't launch the reviewer again.

**Goal:** After making more changes to ongoing work, the user can launch the background reviewer again from the session panel, sees it start, and it reviews the work as it is now.

**Who it's for:** People working on an issue in a Gannin session with pair review on.

**Scope:**

1. Make Review Now start the reviewer again after its loop has finished, and show that it has
2. Say why when it can't start, instead of doing nothing

**Out of scope:**

- Watched reviews of pull requests (AutoReview)
- Starting the reviewer automatically when changes appear
- Posting anything to GitHub from the loop
- Changing the 3-round limit

**Acceptance criteria:**

- **R1** When the loop is over (settled, at the round limit or stopped) and the user clicks Review Now, the system shall start a new round, and the panel's status shall show the reviewer is looking.
- **R2** When Review Now starts the reviewer, the system shall make that visible to the user (the reviewer's tab shows it working).
- **R3** When a new round starts after more changes, the reviewer shall look at every change in the worktree as it is now, committed or not, and leave out findings already dealt with.
- **R4** When Review Now can't start the reviewer, the system shall tell the user why instead of doing nothing.
- **R5** When the work ships, the pair review page under docs-site/src/content/docs/agents/ shall describe how to launch the reviewer again, and CHANGELOG.md shall have an Unreleased line.

**Decisions:**

- Does 'launched again' mean one finished review session or the background reviewer as a whole? **The background reviewer.**
- What situation hurts today? **The review finished and there is no way to restart it after making more changes.**
- Is this about PR reviews? **No: it's about ongoing work with the background reviewer, not PRs.**
- Where did the room look for a way to restart it? **The session panel's Review Now.**
- What happened when Review Now was clicked? **Nothing happened.**
- Are the requirements right? **Yes, move to design.**

## Design

**Approach.** Make Review Now on a finished loop reliably start a round and show it, inside the existing path, with no separate reproduction step. Review Now calls `reviewRequested(id, note: "", byYou: true)` (`PairReview.swift`), which for a finished loop builds a fresh `PairReview` (keeping `reviewerID` and `lastReply`), sets `phase = .reviewing`, and hands the look-again prompt to `send(_:toReviewer:)`. That queues it in `pendingPrompts` and calls `open(reviewer)`, because settling or the limit ended the reviewer's terminal. The prompt is only pasted when the reviewer's state changes to `.idle` (`SessionStore.setState`), and the reviewer's tab is only added in the background, so a click gives no sign anything started.

**Changes.**
1. Review Now reveals the reviewer's tab (`reveal(reviewer.id)`), as the room asked (R2).
2. The relaunch is made robust where the prompt can be lost: when the reviewer's terminal has ended, relaunch it and queue the prompt as `reviewAgain` in `AutoReview.swift` does, and treat a reviewer left in `.exited` or `.stopped` as unable to take a paste (R1).
3. When the round can't start (`send` returns false, the reviewer's Claude Code has exited, or the working session isn't running so findings have nowhere to go), record why on `PairReview.note` so the panel's Status line says it, instead of returning silently (R4).
4. The existing look-again prompt (every change in the worktree as it is now, committed or not, leaving out what's been dealt with) stays, which covers R3.
5. Cover it with `PairReviewTests`; update `agents/pair-review.md` and add a CHANGELOG line (R5).

**Risks.** The exact reason the click does nothing hasn't been reproduced; if a manual try after the change still shows nothing, the task is reopened rather than patched around. `isRunning` stays true while only the shell is left after claude exits, so state decides whether a paste is safe. 'Never post to GitHub from this loop' must hold.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L145-L212`: reviewRequested(byYou: true) starts a fresh loop after settled/limit/stopped and resumes the reviewer helper via send(toReviewer:) with pendingPrompts + open(reviewer); settled and limit end the reviewer's terminal.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L286-L322`: PairReviewSection's Review Now is disabled unless the working session's terminal is running. The reviewer is resumed in the background with no tab revealed, so a click can look like nothing happened.
- `andrew-waters/gannin` `docs-site/src/content/docs/agents/pair-review.md#L21-L23`: Describes Review Now and the fresh loop after Settled; needs the finished-loop relaunch described.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/AutoReview.swift#L353-L383`: reviewAgain queues pendingPrompts and open()s a finished session, and failure is noted rather than silent; sendPendingPrompt pastes it when the state becomes idle (SessionStore.setState).
- `andrew-waters/gannin` `.claude/rules/sessions-pair-review.md`: Rules to keep: after limit/Stop a request from the working agent is answered 'carry on'; after Settled a fresh loop starts; never post to GitHub from this loop. PairReviewTests covers the rules.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1043-L1072`: The queued prompt is only sent on a transition to .idle; a resumed claude that never reports idle leaves the round waiting with no feedback.

**Decisions:**

- Should Review Now bring the reviewer's tab to the front? **Yes, bring it forward.**
- Reproduce the cause before fixing? **No: skip the reproduce-first step and fix in the existing path, checking by hand afterwards.**
- Is the revised design right? **Yes, move to tasks.**

## Tasks

1. [andrew-waters/gannin#353](https://github.com/andrew-waters/gannin/issues/353) Review Now starts the reviewer again after a finished loop, and shows it (satisfies R1, R2, R3)
2. [andrew-waters/gannin#354](https://github.com/andrew-waters/gannin/issues/354) Say why when Review Now can't start the reviewer (satisfies R4)
3. [andrew-waters/gannin#355](https://github.com/andrew-waters/gannin/issues/355) Document relaunching the reviewer and add a changelog line (satisfies R5)

**Decisions:**

- Are the tasks right? **Yes, the plan is ready.**

## From the room

- The review finished and there is no way to restart it if I make more changes (requirements)
- This is not about PRs, this is about ongoing work with the background reviewer (requirements)
