# andrew-waters/gannin#3: Auto review when requested

https://github.com/andrew-waters/gannin/issues/3

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 4 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

Users are requested reviews from engineers - instead of waiting for the user to interact, there should be a user preference, overridable per org (but still a user preference) that automatically picks them up when the app syncs PRs. If not already, these should be a background task and the user sets the timeout - for example, check for PRs every minute. When the user completes a review, an option should be given (on by default) to watch for changes to those PRs and any comments on the PR itself - and automatically re-review without the user having to do it in the app. When unattended, the app should show the user a succinct view of everything communicated and all changes that they might not have seen, so they can catch up whilst AFK etc.

At the moment a requested review waits until the user opens it in the app. Anyone who gets review requests is affected.

## Proposal

1. **Auto review on request.** A user preference that starts a review automatically when PR sync finds a new review request for the user. The user sets a default, and can override it per org. The override is still the user's own setting, not an org-wide one.
2. **Background PR sync on a schedule the user sets.** PR sync runs as a background task at an interval the user chooses (for example, every minute). If sync already runs in the background, this part only adds the interval setting.
3. **Watch and re-review.** When a review is finished, offer an option, on by default, to watch that PR. If new commits are pushed or new comments are left on the PR, the app re-reviews it automatically, without the user doing anything in the app.
4. **Catch-up view.** When the app has been working unattended, show the user a short summary of what they may have missed on the PRs it is reviewing or watching: comments and other communication, new changes, and the reviews the app ran. This lets them catch up after being away.

## Acceptance

- [ ] Users can turn auto review on or off as a default, and override that per org
- [ ] A new review request found by sync starts a review when auto review is on for that org
- [ ] PR sync runs in the background at an interval the user sets
- [ ] When a review finishes, the user gets a "watch for changes" option, on by default
- [ ] On a watched PR, new commits or new PR comments trigger an automatic re-review
- [ ] A catch-up view lists comments, changes and automatic reviews the user hasn't seen since they were last active

## Open questions

- Does PR sync already run as a background task? This decides whether part 2 is only a setting or new work.
- Should automatic reviews and re-reviews post to GitHub on their own, or stay as drafts until the user confirms? The app currently confirms GitHub writes first, so posting automatically would change that rule.
- What are the minimum interval and the rate limits for background sync?
- Does "comments on the PR itself" mean only conversation comments, or review threads and inline comments too?
- When does watching a PR stop: on merge, on close, when the user stops it, or after a set time?
- How does the app tell the user is away, and what counts as "seen" for the catch-up view?
- How do automatic re-reviews stay under control on PRs that change often (debounce or batch them)?

## Context

Raised by andrew-waters. No parent issue, harness document or related PRs known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/3-auto-review-when-requested/`: give each repo it touches a worktree there, on the branch `3-auto-review-when-requested`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/3-auto-review-when-requested/<name>" -b 3-auto-review-when-requested origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#3" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#3]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land.
- `.worktrees/3-auto-review-when-requested/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
