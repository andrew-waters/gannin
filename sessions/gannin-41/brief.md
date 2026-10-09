# andrew-waters/gannin#41: Diffs are sometimes truncated in Claude Code sessions

https://github.com/andrew-waters/gannin/issues/41

- State: open
- Labels: bug
- Opened by: @dwrss, 7 Oct 2026

## Description

## Problem
When working on a PR or in a Claude Code session, the diff shown is sometimes truncated (part of the diff is missing). It's not yet known whether this also affects the code review window.

## Where
- Session Changes pane: `Gannin/Sessions/SessionChanges.swift` (the bash script that diffs each worktree against its merge base, and the parsing of its output).
- Review window: `Gannin/Sessions/PullRequestReview.swift` (`reviewedPullRequest`) builds each file's diff from the REST `pulls/{n}/files` `patch` field with `file.patch ?? ""`. GitHub omits `patch` for very large or binary diffs, so those files would show an empty or partial diff, and paging stops at 30 pages of 100 files.

## Acceptance criteria
- Reproduce the truncation in the Changes pane and note which sizes or cases trigger it.
- Confirm whether the review window is affected too (large files with no `patch`).
- A diff is either shown in full or says clearly that it has been cut off, with a way to see the rest (for example opening the file on GitHub).

_Captured from David's reMarkable 'Gannin Issues' note._

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/41-diffs-are-sometimes-truncated-in-claude/`: give each repo it touches a worktree there, on the branch `41-diffs-are-sometimes-truncated-in-claude`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/41-diffs-are-sometimes-truncated-in-claude/<name>" -b 41-diffs-are-sometimes-truncated-in-claude origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (andrew-waters/gannin), and a clone made in it would vanish when it stops. If the issue needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/41-diffs-are-sometimes-truncated-in-claude/gannin" -b 41-diffs-are-sometimes-truncated-in-claude origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/41-diffs-are-sometimes-truncated-in-claude/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#41" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#41]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/41-diffs-are-sometimes-truncated-in-claude/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
