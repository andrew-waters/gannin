---
type: plan
status: Done
summary: A Work on This session says its change is ready for review by running a script in its folder; Gannin starts a reviewer helper on the same folder, passes its findings back to the working agent, and asks the reviewer to look again after each round of fixes, until it finds nothing more, three rounds have gone, or you stop it.
issues: [andrew-waters/gannin#68]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Pair review: a second agent reviews a session's work before it goes up

## Context

Work on This sessions already have helpers (`CodeSession.parentID`), and Review the Changes starts
one that can't edit (`isReviewer`, `--disallowedTools`), reads the issue's folder against
`origin/HEAD` and ends with a fenced JSON list of findings (`SessionStore.reviewPrompt`,
`SessionTranscript.findings`). Add to Comments turns those into diff comments to send. What's
missing is the loop: nothing starts the reviewer by itself, and nobody but you carries findings and
fixes between the two.

The hooks already write state files into the session's own folder (Application Support here,
`~/.gannin/sessions/<id>` on a server) that `SessionStore.poll` and `readRemote` read every second
or two; `changed` is a token that's compared, not a flag. The same pattern carries the new signal.

## Decisions

- **Signal.** The start script writes an executable `.worktrees/<branch>/.gannin/ready-for-review`
  for the issue's own session (not helpers, reviews, plans or Asks). Claude runs it with a note on
  what changed and where to look. It writes `review-request` (a fresh token and the note, one line)
  into the session's folder, which the poll reads like `changed`, here or over ssh. The brief's
  Working here says when: once the change is committed and built, before the pull request is opened
  as ready for review (a draft is fine), since ready starts the review clock. Its use is allowed in
  the session's settings so it never prompts. A script rather than a hook, as no tool call means
  "ready" by itself, and rather than a file in the worktree, which a server session's poll can't
  see without another ssh read.
- **Reviewer.** The existing reviewer helper (`startHelper(reviewer: true)`), same folder and
  branch, edits disallowed, with the team's review prompts and the harness's learnings, started in
  the background: its tab is added but not selected. Its first prompt is `reviewPrompt` plus the
  working agent's note.
- **Watching each other.** Gannin carries both ways, so neither polls the other. The reviewer's
  turn ending with its JSON list is a round: the findings are pasted into the working session when
  it's waiting for a prompt, else queued until its turn ends (`pendingPrompts`). The working agent
  fixes what it agrees with, says why not for the rest, commits, and runs the script again; that
  asks the reviewer to look again (pasted when idle, queued otherwise). Only one is working on the
  change at a time, and the reviewer can't edit, so they never touch the same files at once.
- **Stopping.** The loop ends when a round has no findings (Settled), after three rounds
  (`PairReview.maxRounds`; the third's findings still go across, marked as the last round, for the
  working agent to fix or leave for the PR description), or when you press Stop. A request after
  it's ended, or with pair review off, is answered in the working session ("no reviewer will look;
  carry on"), so claude never waits for nothing. After it settled, a new request starts a fresh
  loop, as the change has moved on; Review Now starts one whenever you like.
- **What you see.** The session's Agents section shows the loop: round, what's happening (reviewing,
  fixing), the last round's findings count and how it ended, with Stop and the reviewer's tab a
  click away. The end flags the session (tab, Dock, notification): "Review settled" or "Review
  stopped after 3 rounds". The reviewer's Activity keeps its findings with Add to Comments.
- **Where findings go.** Kept in the sessions only. Nothing is posted to GitHub: the PR may not
  exist yet, and Review with Claude is there for that.
- **Opt in.** Settings > General > Agent, "Review a session's work with a second agent"
  (`pairReview`), on by default; each session can turn it off or on in its Agents section
  (`CodeSession.pairReview`, nil for the default).
- **Cost.** The round limit caps it, and the reviewer only runs when asked. The reviewer is ended
  once the loop does, so it isn't left holding a terminal.

## Tasks

- [x] `SessionScript`: the `ready-for-review` script, written by the start script for issue sessions; the permission allowed in the session's settings
- [x] Poll and `readRemote` read `review-request`; a new token is a request
- [x] `PairReview` on `CodeSession` (reviewer, round, phase, last request and reply handled, findings, outcome), decoded leniently
- [x] Requests start the reviewer or ask it to look again; its finished rounds go to the working session; the loop ends settled, at the limit or stopped, and flags you
- [x] `SessionTranscript.listedFindings`: nil when the last reply has no JSON list, so "no findings" isn't confused with "no answer"
- [x] The brief's Working here says when to run the script
- [x] Settings toggle, the session's own choice and the loop's status and Stop in the Agents section
- [x] Tests for the round logic, the findings parse and the script
- [x] CLAUDE.md
