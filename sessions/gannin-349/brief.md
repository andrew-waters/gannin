# andrew-waters/gannin#349: Posting a review includes comments someone else has already posted

https://github.com/andrew-waters/gannin/issues/349

- State: open
- Labels: bug
- Opened by: @dwrss, 14 Oct 2026

## Description

## Problem
Gannin can still post a review comment (finding) that someone else has already left on the PR. The review is drafted against the PR as it was when Claude reviewed it, and nothing checks for comments added since before the draft is sent. The author gets duplicate comments.

## Where
- `PostReviewSheet.post(_:)` and `GitHubAPI.postReview(repo:number:commit:event:body:comments:)` in `Gannin/Sessions/PullRequestReview.swift`: they post the comments built by `ReviewedPullRequest.comments(for:draft:)` without comparing them to what is now on the PR.
- The automatic path in `Gannin/Sessions/AutoReview.swift` (`postAutomatically`), which also ends in `postReview`.

Suggested approach (from the note): re-fetch the PR's review comments and threads just before posting, and drop or flag findings whose file and line already carry a comment saying the same thing.

## Acceptance criteria
- [ ] Just before a review is posted (manually or automatically), Gannin checks the PR for comments added since the review was drafted.
- [ ] A finding that someone else has already raised on the same line is not posted again, and the user is told it was left out.
- [ ] If the check fails, the user can still post, and the failure is shown rather than silent.
- [ ] Docs: the page at gannin.ai/docs that describes posting a review (`docs-site/src/content/docs/agents/`) says what is checked, or "none" if no page describes it.

## Context
Not yet known whether the comparison should be exact text, same line, or same thread; worth deciding when picked up.

_Captured from David's reMarkable 'Gannin Issues' note._

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/349-posting-a-review-includes-comments/`: give each repo it touches a worktree there, on the branch `349-posting-a-review-includes-comments`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/349-posting-a-review-includes-comments/<name>" -b 349-posting-a-review-includes-comments origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/349-posting-a-review-includes-comments/gannin" -b 349-posting-a-review-includes-comments origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/349-posting-a-review-includes-comments/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#349" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#349]` and a summary in its front matter as `~/Projects/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/349-posting-a-review-includes-comments/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
