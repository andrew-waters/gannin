# andrew-waters/gannin#475: Option to exclude draft pull requests from the pull request list

https://github.com/andrew-waters/gannin/issues/475

## Description

## Problem

Draft pull requests show up in the pull request list with no way to hide them. Anyone who only wants PRs that are ready for review has to scan past drafts.

Still unknown:
- Which list this means. It could be the main pull request list, a session's PR list, the review queue or somewhere else.
- Who is affected most, for example reviewers or people tracking their own work.

## Proposal

Add an option that hides draft pull requests from the list.

Still to decide:
- Whether it's a toggle or filter in the list itself, or a setting.
- Whether it is on or off by default.
- Whether the choice is remembered between launches, and whether it applies to every list or only one.

## Acceptance criteria

- [ ] The list has an option to exclude draft pull requests
- [ ] When the option is on, draft PRs don't appear in the list. When it's off, they appear as they do today
- [ ] Docs: which pages at gannin.ai/docs change is not yet known (likely the page that describes the pull request list)

## Context

Requested by andrew-waters. No parent issue, harness document or related PRs have been identified.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/475-option-to-exclude-draft-pull-requests/`: give each repo it touches a worktree there, on the branch `475-option-to-exclude-draft-pull-requests`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/475-option-to-exclude-draft-pull-requests/<name>" -b 475-option-to-exclude-draft-pull-requests origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/475-option-to-exclude-draft-pull-requests/gannin" -b 475-option-to-exclude-draft-pull-requests origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/475-option-to-exclude-draft-pull-requests/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#475" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/475-option-to-exclude-draft-pull-requests/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#475]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/475-option-to-exclude-draft-pull-requests/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
