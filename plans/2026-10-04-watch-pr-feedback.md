---
type: plan
status: In Review
summary: Keep watching a session's PRs across launches, notice new replies on review threads, announce everything new at once, and optionally send it to Claude.
issues: [andrew-waters/gannin#12]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Watch an issue's PR for feedback

## Context

Most of this was already there. `SessionStore.watchPullRequests` fetches every session's PRs (found by
`head:<branch>` and the URLs its hooks catch from `gh pr create`) every 90 seconds, 30 while checks run,
and flags the session when a check newly fails or a reviewer says something new: its tab is marked, the
Dock counts it and a notification goes out. The PRs pane offers the feedback ticked, to send to Claude.

What was missing:

1. What had been seen was kept for the launch only, and the first look after a launch only learns what's
   there, so feedback that came while Gannin was closed was never flagged.
2. A thread was seen once by its ID, so a new reply on a thread already open never flagged.
3. One pass flagged the first new failure or the first new feedback, and the rest went unmentioned.
4. Nothing went to the session's Claude unless sent by hand from the PRs pane.

## Decisions

- Covered: checks newly failing, unresolved review threads on lines that still exist (new, or with a new
  reply from someone other than the PR's author), and reviews with words (comment or changes requested).
  Conversation comments, approvals and changes in review decision, conflicts and merges aren't flagged yet.
- Told: the person running the session, as before (tab, Dock, notification, Agents' Waiting on You), with
  everything new in one notification. Claude is told too when the session says so: a toggle in the PRs
  pane, starting from Settings > General > Agent > Send new PR feedback to Claude (off by default).
  It's pasted when Claude is waiting for a prompt, else when it next finishes its turn; a session that
  isn't running isn't started for it.
- Drafts are watched like any other PR.
- Only the session's PRs are watched: its branch's and those it opened.

## Tasks

- [x] Keep what's been seen with the session (`CodeSession.pullRequestsSeen`), so a relaunch catches up
- [x] Key a thread by its latest comment, skipping replies from the PR's author
- [x] One notification for everything new across the session's PRs
- [x] Send new feedback to Claude: the user's default in Settings, the session's own choice in the PRs pane
- [x] CLAUDE.md
