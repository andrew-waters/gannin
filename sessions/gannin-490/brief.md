# andrew-waters/gannin#490: Gannin can be installed with Homebrew as `gannin`

https://github.com/andrew-waters/gannin/issues/490

## Description

## Problem
There's no way to install Gannin with Homebrew yet. People who manage their Mac apps with Homebrew have to download and install it by hand.

## Proposal
Publish Gannin to Homebrew under the name `gannin`, so `brew install gannin` (or `brew install --cask gannin`) installs the app.

Still to decide:
- Whether it goes in the official `homebrew/cask` repo or in our own tap (for example `andrew-waters/tap`). That decides the exact install command and whether a tap step is needed.
- Whether `gannin` is free as a token in the chosen location.
- How the cask is kept up to date with each release: by hand, or by a step in the release process (`docs/RELEASING.md`).
- How it works alongside Sparkle updates (for example, marking the cask `auto_updates`).
- Whether the current release builds meet Homebrew's requirements (signing, notarisation, a stable download URL per version). Not checked.

## Acceptance criteria
- [ ] `gannin` can be installed with Homebrew on a clean Mac with a single documented command
- [ ] The installed app launches and updates normally
- [ ] There's a documented way to update the cask for each new release
- [ ] Docs: the install instructions at gannin.ai/docs mention Homebrew (exact page not yet identified)

## Context
Requested by andrew-waters. No parent issue, harness document or related PRs known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/490-gannin-can-be-installed-with-homebrew-as/`: give each repo it touches a worktree there, on the branch `490-gannin-can-be-installed-with-homebrew-as`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/490-gannin-can-be-installed-with-homebrew-as/<name>" -b 490-gannin-can-be-installed-with-homebrew-as origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/490-gannin-can-be-installed-with-homebrew-as/gannin" -b 490-gannin-can-be-installed-with-homebrew-as origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/490-gannin-can-be-installed-with-homebrew-as/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#490" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/490-gannin-can-be-installed-with-homebrew-as/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#490]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/490-gannin-can-be-installed-with-homebrew-as/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
