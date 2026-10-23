# andrew-waters/gannin#465: Ready to approve: hold auto reviews that would approve until a person signs off, then post the approval to GitHub

https://github.com/andrew-waters/gannin/issues/465

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 23 Oct 2026

## Description

## Problem

When an automatic review decides a PR should be approved, the result goes to GitHub with nobody looking at it first. Nobody signs off on the approval, and if the person then reviews the PR themselves, they can end up posting a second, duplicate set of comments on top of the automatic one.

PRs the automatic review would approve are also hard to pick out. Nothing makes them stand out as ready for a quick look and sign-off.

## Proposal

A "Ready to approve" queue: PRs that an automatic review would approve wait there for a person to sign off.

- When an automatic review would approve a PR, Gannin holds that review locally and does not post it to GitHub.
- PRs with a held approval go into the Ready to approve queue, so they're easy to find and act on.
- From the queue the user can open the PR, scan the held review (its summary and any comments) and sign off on the approval.
- Signing off posts the approval to GitHub as a single review and takes the PR out of the queue. The held review is posted once, never on top of a copy that has already gone up, so there are no duplicate comments.

Auto reviews that would not approve (comment or request changes) are out of scope here, unless we decide otherwise (see Open questions).

## Acceptance criteria

- [ ] An auto review whose outcome is approve posts nothing to GitHub until the user acts.
- [ ] PRs with a held approval appear in a Ready to approve queue, clearly marked as needing sign-off.
- [ ] The user can open the PR from the queue and read the held review's summary and comments before deciding.
- [ ] Signing off posts one approving review to GitHub, including the held comments, and removes the PR from the queue.
- [ ] Signing off never posts the held comments twice, and they never end up duplicated alongside an automatic post.
- [ ] Docs: which pages at gannin.ai/docs change is not known yet (likely the review / Review with Claude pages).

## Open questions

The request doesn't say, and I haven't checked the code for:

- How the automatic review works today: what triggers it, and whether it currently posts approvals, comments or both straight to GitHub.
- Where the Ready to approve queue lives: a list or section of its own, a filter or badge in the existing PR list, a notification, or something else.
- What the user can do besides sign off: edit the held comments, drop some of them, downgrade to a comment-only review, or throw the held review away.
- What happens to a held review when new commits are pushed to the PR: discard it, mark it stale, or re-run the review.
- What happens to a queued PR that someone else approves, merges or closes on GitHub first.
- Whether held reviews expire or persist across app restarts.
- Whether non-approving auto reviews should also be held, or keep posting as they do now.
- Whether this is a setting (on by default or opt-in), or applies to every repo.
- Whether posting the approval is a new GitHub mutation that has to be confirmed and listed in `.claude/rules/fetching.md`.

## Context

Raised by andrew-waters. No parent issue, harness document or related PRs are known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/465-ready-to-approve-hold-auto-reviews-that/`: give each repo it touches a worktree there, on the branch `465-ready-to-approve-hold-auto-reviews-that`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/465-ready-to-approve-hold-auto-reviews-that/<name>" -b 465-ready-to-approve-hold-auto-reviews-that origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/465-ready-to-approve-hold-auto-reviews-that/gannin" -b 465-ready-to-approve-hold-auto-reviews-that origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/465-ready-to-approve-hold-auto-reviews-that/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#465" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/465-ready-to-approve-hold-auto-reviews-that/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#465]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/465-ready-to-approve-hold-auto-reviews-that/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
