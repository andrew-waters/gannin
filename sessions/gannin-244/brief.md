# andrew-waters/gannin#244: Give the header's status a fixed-size slot so loading and re-review do not move anything

https://github.com/andrew-waters/gannin/issues/244

- State: open
- Labels: bug
- Opened by: @dwrss, 11 Oct 2026
- Parent: #241 Text above the diff on the pull request review screen is shown in a long, thin column that gets narrower on re-review (https://github.com/andrew-waters/gannin/issues/241)

## Description

Wrap the `status` view in a slot of fixed size so the working, Posted, Not running and Review ready states take the same width, and make sure the meta items appearing when `pullRequest` loads do not change row 1's layout.

Checked by building and watching the header before and after the diff loads, then running Review Again several times: the title and reference keep the same width each time.

Satisfies:

- **R3**: When the diff finishes loading, the system shall leave the header's layout and width unchanged.
- **R4**: When the review is run again, the system shall leave the header's layout and width unchanged, however many times it is re-run.

Planned in [Text above the diff on the pull request review screen is shown in a long, thin column that gets narrower on re-review](https://github.com/andrew-waters/gannin/blob/HEAD/plans/2026-10-11-text-above-the-diff-on-the-pull-request.md).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/244-give-the-header-s-status-a-fixed-size/`: give each repo it touches a worktree there, on the branch `244-give-the-header-s-status-a-fixed-size`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/244-give-the-header-s-status-a-fixed-size/<name>" -b 244-give-the-header-s-status-a-fixed-size origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/244-give-the-header-s-status-a-fixed-size/gannin" -b 244-give-the-header-s-status-a-fixed-size origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/244-give-the-header-s-status-a-fixed-size/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#244" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#244]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/244-give-the-header-s-status-a-fixed-size/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
