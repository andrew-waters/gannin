# andrew-waters/gannin#37: Capture reviewer learnings in the harness and apply them in reviews

https://github.com/andrew-waters/gannin/issues/37

## Description

## Problem

During review, people often explain why code is the way it is: "we do x because of y". Right now that reasoning stays in the PR thread. Later reviews, including Review with Claude, don't see it, so the same questions come up again and the same changes get suggested again, even though someone already said why they are wrong for that part of the code.

## Proposal

Add **learnings** as a top-level document type in the harness, alongside `skills/`, `plans/`, `requirements/` and `findings/`.

- A learning is a rule or piece of reasoning given by a person during review. It is scoped to the code it applies to: a folder, a file or a range of lines in a repo.
- Gannin stores learnings by editing the harness git repo, so they are versioned and can be reviewed like every other harness document.
- Reviews look up the learnings that cover the files and lines in a diff and apply them, so a review doesn't contradict a rule a person has already set.

## Acceptance

- [ ] Learnings have their own place in the harness and a documented format.
- [ ] Each learning records its scope (repo plus folder, file or line range), the rule, the reason, and the review it came from.
- [ ] A learning can be captured from a reviewer's comment and written to the harness repo, with the user confirming the write.
- [ ] Reviews load the learnings whose scope overlaps the diff and follow them.
- [ ] Learnings appear in Gannin as a top-level harness feature.

## Unknown / to decide

- The folder name and front matter fields (for example `learnings/` with `repo`, `paths`, `lines`, `source`, `owner`, `status`).
- How captures happen: does Gannin propose a learning when it sees a "we do x because of y" comment, does a person mark it explicitly, or both?
- How line-range scopes stay accurate as code moves (anchor to a symbol, a commit SHA, or re-check them on each review).
- How learnings that are stale or contradict each other get flagged, edited or retired, and who can do that.
- Whether learnings go into the harness repo as a direct commit or as a PR.
- Which reviews read them: just Review with Claude, or Claude Code sessions working on the repo too.

## Context

- Related harness skills: `skills/create-pull-request.md` (hands review over to Review with Claude).
- No parent issue or harness plan has been identified.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/37-capture-reviewer-learnings-in-the/`: give each repo it touches a worktree there, on the branch `37-capture-reviewer-learnings-in-the`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/37-capture-reviewer-learnings-in-the/<name>" -b 37-capture-reviewer-learnings-in-the origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/37-capture-reviewer-learnings-in-the/gannin" -b 37-capture-reviewer-learnings-in-the origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#37" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#37]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/37-capture-reviewer-learnings-in-the/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
