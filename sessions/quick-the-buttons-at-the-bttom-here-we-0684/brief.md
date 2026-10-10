# Quick change in andrew-waters/gannin: the buttons at the bttom here - we need to reword and / or

## A quick change

Started from a quick note in Gannin rather than a written-up issue, and there's no issue for it. It's meant to be small: a snag, a tweak or a one-line fix in andrew-waters/gannin. It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.

## The note

the buttons at the bttom here - we need to reword and / or exaplin. it's also in the deibar - these could do with making much better for the user

## Screenshots

Attached to the note. Look at each one (the Read tool shows images). They're on this box only: never commit them or copy them into a repo.

- `.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/.gannin/attachments/Screenshot-2026-10-10-at-13-14-55.png`

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This change's folder is `.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/`: give each repo it touches a worktree there, on the branch `quick-the-buttons-at-the-bttom-here-we-0684`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/<name>" -b quick-the-buttons-at-the-bttom-here-we-0684 origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (andrew-waters/gannin), and a clone made in it would vanish when it stops. If the change needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/gannin" -b quick-the-buttons-at-the-bttom-here-we-0684 origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- The change is in andrew-waters/gannin.
- Commit in the worktree, and open a pull request with `gh pr create`. There's no issue, so don't make one or invent a reference: put "Quick change, no issue." in its body where `Closes` would go, and keep the branch's name, `quick-the-buttons-at-the-bttom-here-we-0684`.
- A quick change needs no plan document. If it grows to need one, stop and say so instead.
- `.worktrees/quick-the-buttons-at-the-bttom-here-we-0684/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
