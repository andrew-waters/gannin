---
type: skill
name: create-pull-request
description: >
  Open a pull request from a session's worktree with gh pr create, linked to its issue, built once and described the team's way; use when work on an issue branch is ready to go up for review (or as a draft).
repos: all
status: active
owner: andrew-waters
---

# Create a pull request

## Context

Use this when the changes in a session's worktree are ready to go up as a pull request: at the end of Work on This for an issue, or when asked to "open a PR", "put this up" or "raise a PR". It covers the checks before pushing, the branch, the description and opening the PR. It doesn't review the PR (that's Review with Claude) or merge it.

Arguments (all optional):

- `issue`: the issue the PR is for, as `owner/repo#123`. By default it's the issue in the session's brief (`.worktrees/<branch>/.gannin/`).
- `draft`: open as a draft. Use this when work is still under way or something in Rules can't be met yet.
- `repo`: which worktree under `.worktrees/<branch>/` to open the PR from, when the issue touches more than one. Each repo gets its own PR.

Why it matters: Gannin finds a session's PRs through `head:<branch>` and the URL its hooks catch from `gh pr create`, links PRs to issues through closing references, and starts the review clock (time to first review) when a PR is ready for review. If the branch, the closing reference or the draft state is wrong, the workload, the issue's timeline and the metrics are wrong too.

## Steps

1. **Find the worktree and the issue.** Work in `.worktrees/<branch>/<name>`, the worktree made from the shared clone in `projects/<name>`. Never work in `projects/<name>` itself or in the harness root.
   ```bash
   cd .worktrees/<branch>/<name>
   git status --short
   git branch --show-current   # should be <number>-short-title, e.g. 123-fix-sync-footer
   ```
   If the branch doesn't follow `<issue number>-short-title`, stop and say so rather than renaming a branch that's already pushed. The one exception is a quick change Gannin started with no issue: its branch is `quick-short-title-<4 characters>` and its brief says there's no issue (see Rules).

2. **Read the issue again** so the PR answers what was asked:
   ```bash
   gh issue view <number> --repo <owner>/<repo> --comments
   ```
   Also read any plans and requirements about it in the harness (`plans/`, `requirements/`, the brief lists them). Note anything in scope that isn't done; it goes in the description. A quick change with no issue has no issue to read: its note, in the brief, is what was asked.

3. **Look over the whole diff against the base**, committed or not:
   ```bash
   git fetch origin
   git diff origin/HEAD...HEAD --stat
   git diff origin/HEAD...HEAD
   git status --short
   ```
   Remove debugging code, stray files and anything unrelated to the issue. Commit what's left in logical commits with messages in the imperative.

4. **Check the repo's own rules.** Read the repo's `CLAUDE.md` and do what it asks. For the Gannin app (the repo with `project.yml`):
   - `Gannin.xcodeproj` isn't checked in; if files were added or removed, run `xcodegen generate` but don't commit the project.
   - `project.yml`'s `MARKETING_VERSION` stays at the `0.0.0` placeholder (`ci.yml` enforces it; the version comes from the release tag).
   - A change someone using the app would notice gets a line in `CHANGELOG.md` under `## [Unreleased]`, in an `Added`, `Changed` or `Fixed` group (add the group if it isn't there), written for them in the style of the entries below it. That section becomes the next release's notes on GitHub and in Sparkle's update panel (`docs/RELEASING.md`). CI, docs and harness files (plans, sessions, skills, prompts) need none.
   - If the change alters behaviour that `CLAUDE.md` describes (a store, a page, a setting, a sync rule), update `CLAUDE.md` in the same PR, in its style.
   - GitHub calls stay reads, except the confirmed writes `CLAUDE.md` lists; a new mutation must be confirmed first and noted there.

5. **Build once, at the end.** Builds slow the whole machine, so don't build after each edit; do one pass when the change is complete. For the Gannin app:
   ```bash
   xcodegen generate
   xcodebuild -project Gannin.xcodeproj -scheme Gannin -destination 'platform=macOS' build 2>&1 | tail -n 40
   ```
   Capture the result the first time; don't run it again just to see the output. For other repos, run the build or tests their `CLAUDE.md` names, scoped to what changed. TODO: the harness doesn't say what the build and test commands are for repos other than Gannin. CI (`ci.yml` for Gannin) does the broad pass.

6. **Push the branch:**
   ```bash
   git push -u origin HEAD
   ```

7. **Start from the repo's PR template**, if it has one:
   ```bash
   ls .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE 2>/dev/null
   ```
   The Gannin app's is `.github/pull_request_template.md`: the sections below, then a checklist. Copy it into the description file, fill each section, replace its HTML comments, and tick only what's true: the changelog box or the "no user-facing change" box (one of the two), the build and tests only if they ran in this session, `CLAUDE.md` and `MARKETING_VERSION` as checked in step 4, and the screenshots box when there's no UI change or Verified has them (a session that can't capture the app leaves it unticked and says so in Verified). Leave a box unticked rather than ticking it hopefully, and say why in Verified. A repo with no template gets the description below.

8. **Write the description** in a file, so it isn't mangled by the shell (from the template, when there is one):
   ```markdown
   Closes <owner>/<repo>#<number>

   ## What
   What changes for the person using it, in a few sentences.

   ## Why
   The problem from the issue, and any decision made along the way (link the plan in the harness if there is one).
   If the change sets aside one of the goals in the session's brief (a PR larger than its size goal, say), name the goal and say why.

   ## How
   The approach and where to start reading: the main types and files.

   ## Verified
   What was built or tested and how; what wasn't and why.

   ## Not in this PR
   Anything from the issue left for later, with its issue if there is one.
   ```
   Use `Closes` only when the PR finishes the issue; use `Part of <owner>/<repo>#<number>` when it doesn't, so the issue isn't closed early. For a quick change with no issue, the first line is `Quick change, no issue.` instead, and Why gives the note.

9. **Open the PR with `gh pr create`** (not a web page or another client: the session's hook reads its output to record the PR in `session.json`):
   ```bash
   gh pr create --base <default branch> --head <branch> \
     --title "<short title, imperative, no issue number>" \
     --body-file /tmp/pr-body.md [--draft]
   ```
   Print the URL it returns.

10. **Check it landed right:**
    ```bash
    gh pr view --json url,isDraft,closingIssuesReferences,statusCheckRollup
    ```
    `closingIssuesReferences` should hold the issue (when `Closes` was used). If checks fail, read them with `gh run view <run id> --log-failed`, fix, commit and push; don't open a second PR.

11. **Ready for review.** If it opened as a draft and Rules are now met, `gh pr ready`. Request reviewers if asked. TODO: the harness doesn't say who reviews which repo or whether a CODEOWNERS file decides it.

## Rules

- One PR per repo per issue, from the issue's branch (`<number>-short-title`, or a quick change's `quick-…`). Don't push to the default branch, and don't force-push a branch someone has reviewed without saying so.
- Every PR names its issue (`Closes` or `Part of`, as `owner/repo#number`). If there's no issue, stop and ask rather than opening an unlinked PR. The exception is a quick change Gannin started without one (its brief says so, and its branch is `quick-…`): don't file an issue or invent a reference; put `Quick change, no issue.` where `Closes` would go. Gannin still finds the PR by its branch, and it counts in pull request metrics, though not in issue metrics or on the board.
- Open as a draft until the build passes and the description's Verified section is honest. Ready for review starts the review clock, so mark it ready only when it really is.
- Say what was and wasn't verified. Don't claim a build or test passed unless it ran in this session.
- A user-facing change to the Gannin app comes with its `CHANGELOG.md` entry in the same PR; the template's checklist asks for it.
- Keep the PR to the issue. Unrelated fixes get their own issue and PR.
- No Claude attribution anywhere: no `Co-Authored-By: Claude` trailers on commits, no "Generated with Claude Code" lines in the PR body.
- No em dashes, en dashes or the single-character ellipsis in the title, body or commit messages.
- Never commit `projects/`, `.worktrees/`, `Gannin.xcodeproj`, secrets or anything from the session's `.gannin/` folder.
- Don't merge, approve or close anything; that's for people.
- Close to: Review with Claude reviews an existing PR and posts a review; this skill only opens one. If both are asked for, open the PR first, then hand over.
- TODO: the harness has no `STANDARDS.md` covering code or PR conventions; follow it once one exists.
