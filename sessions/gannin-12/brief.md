# andrew-waters/gannin#12: Watch an issue's PR for feedback while working on the issue

https://github.com/andrew-waters/gannin/issues/12

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 4 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

When a session is working on an issue and has opened a PR for it, there's no way to watch that PR for feedback, so new feedback can go unnoticed while the work carries on.

Not yet known:

- Which feedback counts: review comments, review states (changes requested, approved), CI check results, or all of these.
- Who should be told: the person running the session, the Claude Code session itself, or both.
- Where it should appear: in Gannin's UI, in the session, as a notification, or somewhere else.
- Whether this covers draft PRs as well as PRs that are ready for review.

## Proposal

While someone is working on an issue, watch its PR (or PRs, one per repo) for new feedback and show that feedback where the person working on the issue will see it. How the PR gets watched (polling, webhooks or hooks) hasn't been decided.

## Acceptance

- [ ] While an issue is being worked on, new feedback on its PR shows up without anyone having to check GitHub by hand
- [ ] Which kinds of feedback are covered is decided and written down (see the open questions in Problem)
- [ ] Only PRs linked to the issue being worked on are watched

## Context

- Related flow: `skills/create-pull-request.md` (Gannin finds a session's PRs through `head:<branch>` and the URL from `gh pr create`)
- Parent issue: none given
- Harness document: none given

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/12-watch-an-issue-s-pr-for-feedback-while/`: give each repo it touches a worktree there, on the branch `12-watch-an-issue-s-pr-for-feedback-while`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/12-watch-an-issue-s-pr-for-feedback-while/<name>" -b 12-watch-an-issue-s-pr-for-feedback-while origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/12-watch-an-issue-s-pr-for-feedback-while/gannin" -b 12-watch-an-issue-s-pr-for-feedback-while origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#12" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#12]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/12-watch-an-issue-s-pr-for-feedback-while/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
