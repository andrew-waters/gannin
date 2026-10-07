# andrew-waters/gannin#39: Store scorecards and other team data in the harness so changes are shared with everyone

https://github.com/andrew-waters/gannin/issues/39

## Description

## Problem

Scorecards, and possibly other team data, are not stored in the harness. A change one person makes is not seen by the rest of the team. Everyone should be working from the same data.

Unknown:
- Where scorecards are stored today (local app storage, settings, or somewhere else).
- Which other data is meant by "other data". This needs a list before work starts.

## Proposal

Give scorecards (and the other data, once it is listed) a representation in the harness, so the harness becomes the single source for them. When anyone changes a scorecard, the change goes to the harness and everyone sees it.

Not decided yet:
- The file format and where in the harness these files live.
- How a change reaches the harness (for example, a commit made automatically or one the user confirms) and how other people's copies pick it up.
- What happens when two people change the same item at the same time.
- How data stored today moves into the harness.

## Acceptance

- [ ] Scorecards are represented in the harness.
- [ ] A scorecard change made by one person is visible to everyone else on the team.
- [ ] The other data types in scope are listed, and each one is either stored in the harness or split into its own issue.
- [ ] Existing scorecard data is kept when it moves into the harness.

## Context

Raised by andrew-waters. No parent issue, harness document or related PR has been identified yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/39-store-scorecards-and-other-team-data-in/`: give each repo it touches a worktree there, on the branch `39-store-scorecards-and-other-team-data-in`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/39-store-scorecards-and-other-team-data-in/<name>" -b 39-store-scorecards-and-other-team-data-in origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/39-store-scorecards-and-other-team-data-in/gannin" -b 39-store-scorecards-and-other-team-data-in origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#39" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#39]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/39-store-scorecards-and-other-team-data-in/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
