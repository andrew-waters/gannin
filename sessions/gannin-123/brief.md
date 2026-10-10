# andrew-waters/gannin#123: Start work on a small change straight from a quick note, without filing an issue first

https://github.com/andrew-waters/gannin/issues/123

## Description

## Problem

Small changes to a repo (snags, tweaks, one-line fixes) currently need an issue filed before Gannin will start work on them through Work on This. For changes this size, writing up a full issue first is more effort than the change, so they either get skipped or get done outside Gannin.

## Proposal

A quick way to describe a small change and start working on it straight away, as if it were an issue:

- Type a short description of what to do.
- Attach screenshots (and possibly other images).
- Pick the repo.
- Start work immediately, the same way Work on This does for an issue: a worktree, a branch and a session brief that holds the note and screenshots.

The UI and the name for this are not decided yet.

## Open questions

These are unknown and need deciding before or during the work:

- **Does a GitHub issue get created at all?** Options include never, created silently in the background when work starts, or created only when a PR is opened. `skills/create-pull-request.md` currently requires every PR to name its issue (`Closes` or `Part of`) and a branch named `<issue number>-short-title`, so without an issue those rules and Gannin's PR to issue linking need a different answer.
- **Branch naming** when there's no issue number.
- **Where screenshots live:** only in the local session brief (`.gannin/`), or uploaded to GitHub if an issue or PR is created.
- **Metrics and the workflow board:** whether these changes should count in workload, cycle time and review metrics, and whether they should appear on the board.
- **Size limit:** whether anything stops this being used for work that really should be a proper issue.

## Acceptance

- [ ] A short description and one or more screenshots can be entered for a chosen repo.
- [ ] Work can start from that note immediately, with a worktree and branch created as with Work on This.
- [ ] The note and screenshots are available to the session the same way an issue's body is.
- [ ] Opening a PR from that work follows an agreed rule for issue linking (see Open questions), and `skills/create-pull-request.md` and `CLAUDE.md` are updated to match.

## Context

- Related harness skills: `skills/create-issue.md` (files issues, doesn't start work), `skills/create-pull-request.md` (requires a linked issue and an issue-numbered branch).
- No parent issue known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/123-start-work-on-a-small-change-straight/`: give each repo it touches a worktree there, on the branch `123-start-work-on-a-small-change-straight`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/123-start-work-on-a-small-change-straight/<name>" -b 123-start-work-on-a-small-change-straight origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (andrew-waters/gannin), and a clone made in it would vanish when it stops. If the issue needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/123-start-work-on-a-small-change-straight/gannin" -b 123-start-work-on-a-small-change-straight origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/123-start-work-on-a-small-change-straight/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#123" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#123]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/123-start-work-on-a-small-change-straight/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
