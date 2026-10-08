# andrew-waters/gannin#42: Gannin covers day-to-day local git work without a separate git client

https://github.com/andrew-waters/gannin/issues/42

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 8 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

Gannin doesn't cover everyday local git work: cloning, switching branches, reviewing diffs, committing, syncing and tagging. Users keep a separate client such as GitHub Desktop open beside Gannin for this, which splits the flow from issue to PR across two apps. Gannin already handles issues, plans and sessions (Work on This, Draft Issues, opening PRs), but the local repository work in between is not covered well enough for a separate git client to be optional.

This issue lists the gaps and some ideas for closing them. The gap list uses GitHub Desktop as the reference point because it is a common, well-scoped desktop git client. Gannin's current git features were **not** audited for this draft, so each row needs checking against the code before work starts (see Unknowns).

## Gaps against a typical desktop git client

### 1. Repositories and cloning (minimum)
- Clone from a searchable list of the user's GitHub repos and orgs, or from a URL.
- Choose where the clone goes. The harness keeps shared clones in `projects/<name>`, so the default probably belongs there.
- Add an existing local repo.
- A repo switcher showing the current branch and dirty state for each repo.

### 2. Branches and worktrees (minimum)
- A branch picker: list local and remote branches, search, recent branches first, and show ahead/behind against upstream.
- Create a branch from a chosen base. Rename, delete and publish branches.
- Switching with uncommitted changes: offer to stash, carry the changes over, or cancel, as Desktop does.
- Worktrees, which Desktop doesn't support and which could set Gannin apart: list, create (one per issue or session), switch, and remove/prune. Show which worktree each branch is checked out in, and block checking out a branch that's already in another worktree.
- Tie this to Work on This: starting work on an issue could create or select the branch or worktree.

### 3. Changes and diffs (minimum)
- A list of changed files (staged, unstaged, untracked, conflicted).
- A file diff with syntax highlighting, unified and split views, a whitespace toggle and expandable context.
- Stage and unstage whole files, hunks or single lines.
- Discard changes to a file, hunk or line, with confirmation.
- Image and binary file handling (at least "binary changed" with sizes).
- Diff a commit, and compare a branch with its base (what the PR will contain).

### 4. Committing
- Summary and description fields with a length hint on the summary.
- Amend the last commit, and undo the last unpushed commit while keeping its changes.
- Co-author trailers (optional; Desktop has them).
- Respect the repo's hooks and signing config, and show hook failures clearly.

### 5. Syncing
- Fetch, pull and push, with ahead/behind counts and background fetch.
- Pull strategy (merge or rebase) following the user's git config.
- Force push with lease only, behind a confirmation.

### 6. Tags (minimum)
- List tags, create lightweight or annotated tags on a commit, and push and delete tags locally and on the remote.
- Possibly link this to releases (`gh release create`) later; not required here.

### 7. History
- A commit log for the branch, showing each commit's files and diff.
- Revert, cherry-pick onto another branch, and create a branch or tag from a commit.

### 8. Merging, rebasing and conflicts
- Merge another branch into the current one, or rebase onto it.
- A conflicted-files view: open in editor, take ours or theirs, mark resolved, then continue or abort.

### 9. Stash
- Stash, list, apply, pop and drop.

### 10. Pull requests and handoff
- Check out a PR's branch (or into a worktree) by number.
- Show the current branch's PR and check status.
- Open the repo or worktree in the user's editor, terminal or file manager.

## Proposal

Work in stages so the most common local git tasks move into Gannin as early as possible:

1. **Minimum for daily use:** clone/add repo, branch and worktree picker, changes view with diffs and hunk staging, commit, fetch/pull/push, tags.
2. **Daily comfort:** history view, stash, amend/undo, branch compare, PR checkout.
3. **Less frequent:** merge/rebase with conflict handling, cherry-pick/revert, hunk and line discard.

This is probably several issues. I suggest this becomes a parent issue with one sub-issue per area above.

How to build it isn't decided: shell out to the `git` CLI or use a library, and where the UI lives in Gannin.

## Acceptance

- [ ] Gannin's current git features are audited against the gap list, and each row is marked as present, partial or missing
- [ ] A user can clone a repo from their GitHub account into the expected location from Gannin
- [ ] A user can list, create, switch, publish and delete branches, and create, switch and remove worktrees, from Gannin
- [ ] A user can review file diffs and stage by file and by hunk, then commit, from Gannin
- [ ] A user can fetch, pull and push with ahead/behind shown
- [ ] A user can create, push and delete tags
- [ ] The stage 1 loop (clone, branch, review, commit, sync, tag) can be done end to end in Gannin without another git client

## Unknowns

- What git features Gannin already has. This draft was written without reading the repo, so some gaps may already be covered.
- What Gannin runs on and how it renders UI, which affects how practical rich diffs and hunk staging are.
- How Gannin authenticates with GitHub for clone and push (gh, a token, OS keychain), and whether it can reuse git's credential helper.
- Whether Work on This already creates branches or worktrees, and how a manual picker should fit with it.
- Whether repos outside the harness `projects/` folder should be supported.
- Which Desktop features (for example co-authors or hunk discard) are actually needed; this list is a superset to prune.

## Context

- Request: make Gannin cover everyday local git work so a separate git client isn't needed alongside it.
- Related Gannin features: Work on This, Draft Issues, Write Issue, `skills/create-pull-request.md`.
- No parent issue, harness document or prior issue linked yet. The duplicate search wasn't run (see note).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/42-gannin-covers-day-to-day-local-git-work/`: give each repo it touches a worktree there, on the branch `42-gannin-covers-day-to-day-local-git-work`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/42-gannin-covers-day-to-day-local-git-work/<name>" -b 42-gannin-covers-day-to-day-local-git-work origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/42-gannin-covers-day-to-day-local-git-work/gannin" -b 42-gannin-covers-day-to-day-local-git-work origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#42" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#42]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/42-gannin-covers-day-to-day-local-git-work/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
