# andrew-waters/gannin#182: X sub-issues text on a completed plan doesn't update if a new one is added after completion

https://github.com/andrew-waters/gannin/issues/182

- State: open
- Opened by: @dwrss, 10 Oct 2026

## Description

<img width="813" height="99" alt="Image" src="https://github.com/user-attachments/assets/296cae8b-e51e-4ef6-84ff-9a15a66ca748" />

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Projects/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/182-x-sub-issues-text-on-a-completed-plan/`: give each repo it touches a worktree there, on the branch `182-x-sub-issues-text-on-a-completed-plan`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/182-x-sub-issues-text-on-a-completed-plan/<name>" -b 182-x-sub-issues-text-on-a-completed-plan origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/182-x-sub-issues-text-on-a-completed-plan/gannin" -b 182-x-sub-issues-text-on-a-completed-plan origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/182-x-sub-issues-text-on-a-completed-plan/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a draft pull request per repo with `gh pr create --draft`, putting "Closes andrew-waters/gannin#182" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#182]` and a summary in its front matter as `~/Projects/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/182-x-sub-issues-text-on-a-completed-plan/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.

## Scheduled run

Gannin started this session by itself, for the routine "Queue window". Nobody is watching it.

- Don't ask questions or wait for a plan to be approved: decide, write down why where the work is recorded (the plan, the commit, the pull request or the report), and carry on. If you can't go on without a person, stop and say why in your last message.
- You're in auto mode. A permission prompt or question waits for someone and holds the run up.
- It's stopped after 60 minutes or US$15.00 spent, whichever comes first, keeping what's done. Keep within that.
- Draft PR: once the change is committed, built and checked, push with `git push origin HEAD:<branch>` (this session's branch) and open a draft pull request (`gh pr create --draft`). Don't mark it ready for review or merge it.
