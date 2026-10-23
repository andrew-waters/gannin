# andrew-waters/gannin#463: New users are guided through setting up or linking a harness

https://github.com/andrew-waters/gannin/issues/463

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

Someone using Gannin for the first time has to set up a harness or link an existing one before most of the app is useful. Right now there is no guided path for this.

Unknown, to be filled in during triage:
- What a new user sees today before a harness is configured, and where they get stuck.
- Whether this affects only brand new users or also existing users adding a second harness.
- Whether any first-run or empty-state screens already exist that this should build on.

## Proposal

Add a guided flow for new users that walks them through either:
- creating a new harness, or
- linking an existing harness repo.

The how is not decided yet. Open questions:
- Where it starts (first launch, an empty state, Settings, or several of these).
- What steps it covers (for example GitHub auth and scopes, choosing the harness repo, cloning, the workflow board, investment tracking settings). The exact list is unknown.
- Whether creating a harness starts from a template, and if so which one.
- How it handles a harness that is only partly set up.

## Acceptance criteria

- [ ] A new user with no harness is offered a guided path to create one or link an existing one
- [ ] At the end of the flow the harness is linked and the app is usable without further manual setup (exact definition of "usable" to be agreed)
- [ ] The user can leave the flow and come back to it later
- [ ] Docs: the getting started / setup pages at gannin.ai/docs (exact pages unknown)

## Context

- Parent issue: none known
- Harness document: none found
- Related issues or PRs: not checked (duplicate search could not run in this session)

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/463-new-users-are-guided-through-setting-up/`: give each repo it touches a worktree there, on the branch `463-new-users-are-guided-through-setting-up`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/463-new-users-are-guided-through-setting-up/<name>" -b 463-new-users-are-guided-through-setting-up origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/463-new-users-are-guided-through-setting-up/gannin" -b 463-new-users-are-guided-through-setting-up origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/463-new-users-are-guided-through-setting-up/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#463" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/463-new-users-are-guided-through-setting-up/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#463]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/463-new-users-are-guided-through-setting-up/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
