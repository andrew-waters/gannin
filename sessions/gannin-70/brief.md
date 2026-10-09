# andrew-waters/gannin#70: Work on This tells the agent the project's goals and tracked metrics

https://github.com/andrew-waters/gannin/issues/70

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 9 Oct 2026

## Description

## Problem

When an agent starts on an issue through Work on This, it isn't told the project's goals. So it can make choices that work against them without knowing it. This matters most when the org tracks metrics like lines of code changed and files touched: an agent that doesn't know these are watched may produce a large, sprawling change where a smaller one would have done.

## Proposal

When someone clicks Work on This, put the project's goals into the agent's context automatically, with caveats attached:

- The goals are guidance, not hard rules. The agent may depart from one when it has good reason.
- When it does, it should say so and give its reasons (for example in the PR description), rather than ignoring the goal without comment.
- If the org tracks metrics such as lines changed and files touched, tell the agent which ones, so it can keep changes focused where the work allows.

## Unknowns

- Where a project's goals are defined today, or whether they need somewhere new to live.
- Which metrics Gannin tracks per org, and whether the list of metrics to pass on should be configurable.
- The exact caveat wording, and where the goals go: the session brief in `.worktrees/<branch>/.gannin/`, or somewhere else.
- Whether the user can see or edit the injected goals before the agent starts.
- What happens when a project has no goals set (probably inject nothing).

## Acceptance

- [ ] Starting Work on This on an issue in a project with goals gives the agent those goals, with the caveat that they can be set aside when there's good reason.
- [ ] If the org tracks metrics like lines changed or files touched, the agent is told which ones.
- [ ] The agent is asked to explain any departure from a goal.
- [ ] Projects without goals behave as they do today.

## Context

Related: `skills/create-pull-request.md`, where the PR description's Why section could carry any explanation for setting a goal aside.

Not checked for duplicates yet: the GitHub search wasn't permitted in this session.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/70-work-on-this-tells-the-agent-the-project/`: give each repo it touches a worktree there, on the branch `70-work-on-this-tells-the-agent-the-project`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/70-work-on-this-tells-the-agent-the-project/<name>" -b 70-work-on-this-tells-the-agent-the-project origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/70-work-on-this-tells-the-agent-the-project/gannin" -b 70-work-on-this-tells-the-agent-the-project origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/70-work-on-this-tells-the-agent-the-project/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#70" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#70]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/70-work-on-this-tells-the-agent-the-project/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
