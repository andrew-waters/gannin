# andrew-waters/gannin#467: Avoid sending duplicate review comments on follow-up reviews

https://github.com/andrew-waters/gannin/issues/467

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

Gannin doesn't keep a good enough record of the review comments it has already sent. So when a review is sent automatically and someone then follows up with another review on the same pull request, comments that were already posted can be sent again. That leaves duplicate comments on the PR.

Not yet known:
- Which automatic path posts the first review. It may be Review with Claude, but that hasn't been confirmed.
- Whether the duplicates are word-for-word or just cover the same point again.
- How Gannin records sent comments today, if it records them at all.
- Whether this also happens when both reviews are started by hand.

## Proposal

Keep track of which review comments have already been sent on a pull request, so a follow-up review doesn't post them again. How to track them and how to decide two comments are the same are still open questions.

## Acceptance criteria

- [ ] After an automatic review, a follow-up review on the same PR doesn't post comments that were already sent
- [ ] A follow-up review can still post new comments
- [ ] Docs: to be confirmed (whichever gannin.ai/docs page covers reviews, or "none")

## Context

- May tie in with andrew-waters/gannin#465. I couldn't read that issue while drafting, so how the two relate still needs checking.
- No parent issue, harness document or PR has been identified yet.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/467-avoid-sending-duplicate-review-comments/`: give each repo it touches a worktree there, on the branch `467-avoid-sending-duplicate-review-comments`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/467-avoid-sending-duplicate-review-comments/<name>" -b 467-avoid-sending-duplicate-review-comments origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/467-avoid-sending-duplicate-review-comments/gannin" -b 467-avoid-sending-duplicate-review-comments origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/467-avoid-sending-duplicate-review-comments/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#467" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/467-avoid-sending-duplicate-review-comments/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#467]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/467-avoid-sending-duplicate-review-comments/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
