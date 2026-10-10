# andrew-waters/gannin#130: this should be a table

https://github.com/andrew-waters/gannin/issues/130

## A quick change

Started from a quick note in Gannin rather than a written-up issue (Gannin filed andrew-waters/gannin#130 from the note). It's meant to be small: a snag, a tweak or a one-line fix in andrew-waters/gannin. It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.

## The note

this should be a table

## Screenshots

Attached to the note. Look at each one (the Read tool shows images). They're on this box only: never commit them or copy them into a repo.

- `.worktrees/130-this-should-be-a-table/.gannin/attachments/Screenshot-2026-10-10-at-10-11-21.png`

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/130-this-should-be-a-table/`: give each repo it touches a worktree there, on the branch `130-this-should-be-a-table`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/130-this-should-be-a-table/<name>" -b 130-this-should-be-a-table origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (andrew-waters/gannin), and a clone made in it would vanish when it stops. If the issue needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/130-this-should-be-a-table/gannin" -b 130-this-should-be-a-table origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/130-this-should-be-a-table/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#130" in its body so it links to the issue.
- A quick change needs no plan document. If it grows to need one, stop and say so instead.
- `.worktrees/130-this-should-be-a-table/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
