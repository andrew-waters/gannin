# andrew-waters/gannin#464: New windows ask which org and project to open

https://github.com/andrew-waters/gannin/issues/464

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

When a new window opens, it doesn't ask which org and project it should show. This affects anyone who works across more than one org or project.

Not yet known:
- What a new window shows today (the last-used org and project, the same as the window it was opened from, or something else).
- Whether this covers every new window (for example on first launch or when restoring windows) or only windows opened from a running app.

## Proposal

When a new window opens, ask the user which org and project to open in it.

Open questions:
- Should the picker be skippable, for example with a default or a "remember this" option?
- What happens if the user has only one org or one project: ask anyway, or skip the question?
- What happens if the user dismisses the picker without choosing?

## Acceptance criteria

- [ ] Opening a new window asks which org and project to open before showing content
- [ ] The window then opens on the org and project the user chose
- [ ] Behaviour for the open questions above is decided and implemented
- [ ] Docs: which pages at gannin.ai/docs change: unknown, to be confirmed (likely any page that covers windows or switching org or project)

## Context

Raised by andrew-waters. No parent issue, harness document, PRs or findings are linked yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/464-new-windows-ask-which-org-and-project-to/`: give each repo it touches a worktree there, on the branch `464-new-windows-ask-which-org-and-project-to`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/464-new-windows-ask-which-org-and-project-to/<name>" -b 464-new-windows-ask-which-org-and-project-to origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/464-new-windows-ask-which-org-and-project-to/gannin" -b 464-new-windows-ask-which-org-and-project-to origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/464-new-windows-ask-which-org-and-project-to/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#464" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/464-new-windows-ask-which-org-and-project-to/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#464]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/464-new-windows-ask-which-org-and-project-to/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
