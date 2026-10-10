# andrew-waters/gannin#127: when runnign in a sandbox, the user should be able to 

https://github.com/andrew-waters/gannin/issues/127

## A quick change

Started from a quick note in Gannin rather than a written-up issue (Gannin filed andrew-waters/gannin#127 from the note). It's meant to be small: a snag, a tweak or a one-line fix in andrew-waters/gannin. It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.

## The note

when runnign in a sandbox, the user should be able to  update the sahred claude md file - rules such as no coauthoring and attribution and anythign else that could be considered house rules should land in the sandboxes. This can be written up as an issue that bring sthe feature, not mentionin the lack of attribution

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/127-when-runnign-in-a-sandbox-the-user/`: give each repo it touches a worktree there, on the branch `127-when-runnign-in-a-sandbox-the-user`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/127-when-runnign-in-a-sandbox-the-user/<name>" -b 127-when-runnign-in-a-sandbox-the-user origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. You're in a sandbox: only the repos already under `projects/` are here (andrew-waters/gannin), and a clone made in it would vanish when it stops. If the issue needs another repo, stop and ask the user to clone it into `projects/` on their Mac and restart the session. Commits are signed for you. The repos' git dirs are read-only apart from what commits, fetches and worktrees write, so git config and hooks can't be changed, no upstream is recorded (push with `git push origin HEAD` and open the PR with `gh pr create --head <branch>`), branches can't be deleted, and an error about packed-refs.lock after a rebase or pull is expected and harmless.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/127-when-runnign-in-a-sandbox-the-user/gannin" -b 127-when-runnign-in-a-sandbox-the-user origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/127-when-runnign-in-a-sandbox-the-user/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#127" in its body so it links to the issue.
- A quick change needs no plan document. If it grows to need one, stop and say so instead.
- `.worktrees/127-when-runnign-in-a-sandbox-the-user/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
