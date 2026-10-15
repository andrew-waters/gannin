# andrew-waters/gannin#295: Sandbox starts race when a session and its helper start together

https://github.com/andrew-waters/gannin/issues/295

- State: open
- Opened by: @andrew-waters, 12 Oct 2026

## Description

## Problem

Two sessions sharing one sandbox container can start at the same moment, and when they do, they race to create it. One wins and the other is left for dead. The usual way to get there is a pair-review reviewer starting just as Gannin relaunches and resumes the working session it reviews. That's exactly what happened on andrew-waters/gannin#134 (PR #196): the review request was written on 10 October and picked up when Gannin relaunched on 12 October.

What the session folder showed:

- At 14:35:11 the session and its reviewer helper (`helpers/439A12AF…`) both ran their start scripts.
- The reviewer wrote `sandbox: failed: The sandbox didn't start. Run container logs gannin-f6037a52-… to see why.` at 14:35:14, and its `state` stayed `starting`.
- The working session wrote `sandbox: running` at 14:35:15 and carried on happily.

The cause is the check in `SandboxLaunch.hostSteps` (`Gannin/Sandbox/SandboxLaunch.swift`, around line 100). It runs `container list`; if the container isn't there, it runs `delete --force "$name"` and then `run --detach --name "$name"`. With two scripts in that window, both see nothing running, both delete and both run, and one `run` loses on the name. It could just as easily have gone the other way: the loser's `delete --force` can remove a container the winner has just started, taking the working session down with it.

A second thing, observed but not verified: asking for review again with `ready-for-review` afterwards got no response either. My guess is that Gannin hands the new request to the reviewer already there (`state: starting`, `sandbox: failed`) rather than starting a fresh one, so it pastes into a terminal that never got going.

## Proposal

- Make starts of the same container take turns on the box, then check again whether it's running once it's your turn: for example a `mkdir` lock in the issue's session folder, with a timeout and stale-lock handling, so it works here and over ssh without `flock`.
- When a reviewer helper's sandbox has failed, a new review request should start the reviewer afresh rather than talk to the one that never started.

## Acceptance criteria

- [ ] A session and its helper starting at once both end up in the one container, with neither failed nor deleted from under the other
- [ ] A `ready-for-review` after a reviewer failed to start gets a working reviewer
- [ ] A unit test on the start script covers the lock and the second check
- [ ] Docs: `sessions/sandboxes.md` only if the behaviour described there changes, else none

## Context

- Seen on andrew-waters/gannin#134 / #196, sandbox `gannin-f6037a52-6bec-4649-9f81-9bdeaa60c75c`
- Pair review: `plans/2026-10-09-pair-review.md`; sandboxes: `plans/2026-10-09-run-agent-sessions-in-apple-container.md`

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/295-sandbox-starts-race-when-a-session-and/`: give each repo it touches a worktree there, on the branch `295-sandbox-starts-race-when-a-session-and`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/295-sandbox-starts-race-when-a-session-and/<name>" -b 295-sandbox-starts-race-when-a-session-and origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/295-sandbox-starts-race-when-a-session-and/gannin" -b 295-sandbox-starts-race-when-a-session-and origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/295-sandbox-starts-race-when-a-session-and/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#295" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#295]` and a summary in its front matter as `~/Projects/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/295-sandbox-starts-race-when-a-session-and/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
