# andrew-waters/gannin#442: Auto review: a held approval reads as approved in the record and the posted comment, and is easy to miss

https://github.com/andrew-waters/gannin/issues/442

- State: open
- Opened by: @row-han-solo, 21 Oct 2026

## Description

## Problem

When an automatic review's verdict is approve, nothing tells the PR's author that the approval hasn't been given. The review record in the harness says `"verdict": "approve"`, and a posted comment can say "Approving". Meanwhile GitHub shows no approval, and the review request stays pending. Authors read the record or the comment as approved and carry on, and PRs merge with no approval on GitHub.

It has happened on two plan PRs in a row:

- **ctrl-hub/harness#197.**
  - At 12:13 on 2026-10-21, the record commit `5a71850` set `"verdict": "approve"` in `.gannin/reviews/ctrl-hub/harness/197-andrew-waters.json` and resolved both findings. Nothing was posted to GitHub.
  - At 13:20 a review with one nit was posted as COMMENTED. Its body says "Approving, so work on ctrl-hub/product#3379 can carry on."
  - The record says `"event": "COMMENT"` with `"verdict": "approve"`. The PR merged with no approval.
- **ctrl-hub/harness#195.** The record says `"verdict": "approve"`, and GitHub has only a COMMENTED review. It merged the same way.
- **ctrl-hub/harness#196** shows the intended path. The approval was given from the review tab, the record says `"event": "APPROVE"`, and GitHub shows APPROVED.

Automatic reviews never approving is intended (docs: agents/auto-review). The problem is that the held approval is easy to miss, and two of its outputs read as an approval when there isn't one:

1. **Approve with no findings posts nothing.** In `AutoReview.postAutomatically`, `holdsForApproval` (`ApprovalQueue.swift`) holds the review back. The function then calls `recordReview(id)`. `ReviewRecord.updated` (`ReviewRecords.swift`) copies `review.verdict` into the record, so the committed record says approve while `event` stays at the earlier `COMMENT`.
2. **Approve with findings posts as a comment whose body says it approves.** `holdsForApproval` is false once a finding is kept, so the review goes out with the fixed `event: "COMMENT"`. Its body is Claude's summary, written for a verdict of approve.
3. **The only prompt to approve is the Inbox's Ready for your approval queue and one notification** (`noticeApproval`). Merging the PR takes it off `EngineerWatch.shared.waitingReviews`, so it drops out of the queue unapproved.

## Proposal

- The record shows a held approval as held, apart from what was posted to GitHub.
- A review posted as a comment doesn't say it approves.
- The reviewer is reminded of a held approval until they give it or dismiss it.

## Acceptance criteria

- [ ] The review record separates Claude's verdict from what reached GitHub. For example, it marks a held approval as held, or records the posted event alongside the verdict. A reader of `.gannin/reviews/` can tell an approved PR from one waiting on the reviewer.
- [ ] A review posted automatically with a verdict of approve doesn't claim to approve. Either the summary is written without approval wording, or the review adds a line saying the approval is waiting for the reviewer.
- [ ] A held approval stays in front of the reviewer, in the Inbox, the Dashboard and Waiting on You, until they give or dismiss it. A single notification isn't enough.
- [ ] Unchanged:
  - Automatic reviews still never submit `APPROVE` or `REQUEST_CHANGES`.
  - An approve with nothing to say still posts no comment.
  - Approving from the review tab still submits `APPROVE` and records `"event": "APPROVE"`, as on ctrl-hub/harness#196.
- [ ] Docs: `docs-site/src/content/docs/agents/auto-review.md` (Ready for your approval, and what an automatic post says), plus `agents/reviews.md` if the record's fields change.

## Context

- Records: ctrl-hub/harness:.gannin/reviews/ctrl-hub/harness/197-andrew-waters.json and ctrl-hub/harness:.gannin/reviews/ctrl-hub/harness/195-andrew-waters.json.
- First raised on ctrl-hub/harness#197 (https://github.com/ctrl-hub/harness/pull/197#issuecomment-6317226067).
- Related: andrew-waters/gannin#427, which added posted-review tracking (`postedEvent`).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/442-auto-review-a-held-approval-reads-as/`: give each repo it touches a worktree there, on the branch `442-auto-review-a-held-approval-reads-as`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/442-auto-review-a-held-approval-reads-as/<name>" -b 442-auto-review-a-held-approval-reads-as origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/442-auto-review-a-held-approval-reads-as/gannin" -b 442-auto-review-a-held-approval-reads-as origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/442-auto-review-a-held-approval-reads-as/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#442" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/442-auto-review-a-held-approval-reads-as/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#442]` and a summary in its front matter as `~/Projects/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/442-auto-review-a-held-approval-reads-as/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
