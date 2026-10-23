# andrew-waters/gannin#480: When I click "WOrk on This" and caldue has questions, it

https://github.com/andrew-waters/gannin/issues/480

## A quick change

Started from a quick note in Gannin rather than a written-up issue (Gannin filed andrew-waters/gannin#480 from the note). It's meant to be small: a snag, a tweak or a one-line fix in andrew-waters/gannin. It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.

## The note

When I click "WOrk on This" and caldue has questions, it should call AskUserQuestion

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/480-when-i-click-work-on-this-and-caldue-has/`: give each repo it touches a worktree there, on the branch `480-when-i-click-work-on-this-and-caldue-has`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/480-when-i-click-work-on-this-and-caldue-has/<name>" -b 480-when-i-click-work-on-this-and-caldue-has origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/480-when-i-click-work-on-this-and-caldue-has/gannin" -b 480-when-i-click-work-on-this-and-caldue-has origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/480-when-i-click-work-on-this-and-caldue-has/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#480" in its body so it links to the issue. Before opening it as ready for review, run `.worktrees/480-when-i-click-work-on-this-and-caldue-has/.gannin/ready-for-review "<what changed and where to look>"` and wait for its outcome (opening it as a draft first is fine).
- A quick change needs no plan document. If it grows to need one, stop and say so instead.
- `.worktrees/480-when-i-click-work-on-this-and-caldue-has/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
