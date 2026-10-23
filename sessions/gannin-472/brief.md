# andrew-waters/gannin#472: Planning only suggests repos that accept issues, and follows an org-level issue strategy stored in the harness

https://github.com/andrew-waters/gannin/issues/472

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

When planning mode creates tickets, it suggests repos that have issues turned off. Those suggestions can't be used: an issue can't be filed there.

Orgs also keep their issues in different places, and Gannin has no way to know which approach an org uses. For example:

- **One central repo.** All issues go in one repo (at work we use a repo called `product`), whichever code repo the work touches.
- **Spread across repos, collected on a board.** Each issue goes in the repo it concerns, and a GitHub Project gathers them all.

Without this, planning has to guess the repo for each ticket, and in a central-repo org it suggests the wrong one.

## Proposal

1. When planning suggests a repo for a ticket, leave out any repo that has issues turned off.
2. Add an org-level setting for the issue strategy, with at least these two options:
   - **Central repo**: every issue goes in one named repo (for example `product`).
   - **Per repo, collected on a project**: each issue goes in the repo it touches, then gets added to a named GitHub Project.
3. Save the setting in the harness so the whole team shares it, rather than keeping it on one person's machine.
4. Planning (and possibly the other issue-creating flows) uses the setting to pick the repo and, where it applies, the project.

## Unknowns

- How planning picks the repos it suggests today. Not looked at for this draft.
- Where in the harness the setting should live (file path, format) and whether it sits next to the existing org settings such as Issue workflow and How we track investments.
- How this fits with the existing Issue workflow board setting: does the per-repo strategy reuse that board, or name its own project?
- Whether other flows (New Issue, Write Issue, Draft Issues, Quick Change, `skills/create-issue.md`) should follow the setting too, or only planning for now.
- What to do when there's no setting yet: a default strategy, or a prompt asking the org to choose.
- Whether an org needs a mixed or override option (for example a central repo with exceptions).
- What planning should do when the central repo has issues turned off, or can't be reached.

## Acceptance criteria

- [ ] Planning never suggests a repo with issues turned off
- [ ] An org can choose its issue strategy (central repo, or per repo collected on a project) and name the repo or project it uses
- [ ] The choice is saved in the harness and read back by everyone working on that org
- [ ] Under the central repo strategy, planning files tickets in the named repo
- [ ] Under the per repo strategy, planning suggests only repos that accept issues and adds each ticket to the named project
- [ ] Docs: the planning and settings pages at gannin.ai/docs (exact pages to be confirmed)

## Context

- Raised by andrew-waters. No parent issue, harness document, PRs or findings linked yet.
- Related: `skills/create-issue.md` step 8 (workflow board) and step 5 (investment tracking setting) depend on similar org settings.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/472-planning-only-suggests-repos-that-accept/`: give each repo it touches a worktree there, on the branch `472-planning-only-suggests-repos-that-accept`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/472-planning-only-suggests-repos-that-accept/<name>" -b 472-planning-only-suggests-repos-that-accept origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/472-planning-only-suggests-repos-that-accept/gannin" -b 472-planning-only-suggests-repos-that-accept origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/472-planning-only-suggests-repos-that-accept/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#472" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/472-planning-only-suggests-repos-that-accept/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#472]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/472-planning-only-suggests-repos-that-accept/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
