# andrew-waters/gannin#9: Show milestones and releases in the app with progress tracking

https://github.com/andrew-waters/gannin/issues/9

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 4 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

Gannin doesn't show GitHub milestones, though most other GitHub data is already in the app. That means nobody can see in Gannin what is planned for a milestone or release, or how far along it is, so they have to go to GitHub to check.

## Proposal

Add milestones and releases to the UI and track their progress.

Things still to decide (not yet known):

- **What "releases" means here.** It could mean GitHub Releases (tags and release notes), milestones used as releases, or both. How the two relate in the app is also open.
- **How progress is measured.** Options include closed vs open issues in a milestone (GitHub's own measure), PRs merged, or something else. It's also open whether progress should count across repos.
- **Where it goes in the UI.** A new page, a section on existing pages, or a filter on issue lists.
- **Read-only or editable.** Whether users can create or edit milestones, or assign issues to them, from Gannin. Any new GitHub write would need confirming first and adding to the confirmed writes in `CLAUDE.md`.
- **Sync.** How milestones and releases fit into the current sync rules.

## Acceptance

- [ ] Milestones for tracked repos show in the app, with title, due date and state
- [ ] Each milestone shows its progress (measure to be agreed, see above)
- [ ] Releases show in the app (meaning of "releases" to be agreed, see above)
- [ ] `CLAUDE.md` describes the new data, page or sync behaviour

## Context

Raised by andrew-waters. No parent issue, harness plan or requirement linked yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/9-show-milestones-and-releases-in-the-app/`: give each repo it touches a worktree there, on the branch `9-show-milestones-and-releases-in-the-app`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/9-show-milestones-and-releases-in-the-app/<name>" -b 9-show-milestones-and-releases-in-the-app origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/9-show-milestones-and-releases-in-the-app/gannin" -b 9-show-milestones-and-releases-in-the-app origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#9" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#9]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/9-show-milestones-and-releases-in-the-app/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
