# andrew-waters/gannin#68: Start a second agent to review a session's work when it says it's ready for review

https://github.com/andrew-waters/gannin/issues/68

## Description

## Problem

When an agent works on an issue (Work on This), the only check on its code before a person sees it is the agent's own judgement that it's done. Nothing in the session asks a second agent to look at the change while the work is still in progress, so mistakes are first caught at PR review or later.

## Proposal

When the working agent considers the change ready for review, it signals that, and Gannin starts a second agent to review the code. The two then work together: each watches for changes from the other (the reviewer's findings, the original agent's fixes) until the review settles.

The signal could be a hook or a status the session emits as JSON (for example alongside the session's `session.json`). Which of these to use has not been decided.

## Open questions

- **Signal**: a hook, a status field in emitted JSON, or something else? What exactly counts as "ready for review" (for example, before or after `gh pr create`, or a draft PR)?
- **Reviewer**: is it Review with Claude, a new agent type, or something else? Does it run in the same worktree or a separate one?
- **Watching each other**: how each agent notices the other's changes (file changes in the worktree, commits, review comments, a shared status file), and how they avoid editing the same files at once.
- **Stopping**: what ends the loop (reviewer has no more findings, a round limit, a person stepping in) and what the person sees when it ends.
- **Where findings go**: kept in the session, posted as PR review comments, or both.
- **Opt in**: always on, per session, or a setting.
- **Cost**: two agents per session costs more tokens and machine time; whether that needs a limit.

## Acceptance

- [ ] A session can signal that its work is ready for review in a defined way.
- [ ] That signal starts a reviewing agent on the same change.
- [ ] The working agent sees the reviewer's findings, and the reviewer sees the working agent's follow-up changes, without a person passing them across.
- [ ] The loop has a defined end, and the person can see its outcome.

## Context

Related: Work on This, Review with Claude, the session hook that records `gh pr create` in `session.json`, and `skills/create-pull-request.md` (ready for review starts the review clock, so the agent review probably needs to happen before a PR is marked ready). No parent issue, plan or requirement known.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/68-start-a-second-agent-to-review-a-session/`: give each repo it touches a worktree there, on the branch `68-start-a-second-agent-to-review-a-session`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/68-start-a-second-agent-to-review-a-session/<name>" -b 68-start-a-second-agent-to-review-a-session origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/68-start-a-second-agent-to-review-a-session/gannin" -b 68-start-a-second-agent-to-review-a-session origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#68" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#68]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/68-start-a-second-agent-to-review-a-session/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
