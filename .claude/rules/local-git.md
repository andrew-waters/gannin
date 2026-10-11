---
paths:
  - "Gannin/Git/**"
---

# Local git

- It is the git CLI, never a library: `Shell.run` (bash, Homebrew folders on `PATH`, `GIT_TERMINAL_PROMPT=0`, no stdin, so nothing prompts) with the user's own config, hooks, signing and credential helper. Gannin never handles a git credential. `GitDiff` also serves sessions' Changes.
- Git run in a repo a sandbox could have written must go through `SandboxGitGuard` (see sandbox rules); `LocalRepository.script` does so via `applies(to:)`.
- `LocalClones` resolution order: folder saved in `localRepository.<owner/name>`, the harness checkout when the repo is the harness, a harness's `projects/<name>` (or `<group>/<name>`), then usual places (`SessionStore.existingCheckout`), each verified by its remotes. Clone goes to the project's harness `projects/<name>`, else `<workspace>/<owner>/<name>`.
- `LocalRepository` works one worktree at a time (`path`, remembered in `localRepositoryWorktree.<repo>`). One script reads a whole `GitSnapshot` via `GitParse` every 10 s while Gannin is active and on activation. Background fetch every 5 min while the page is open uses git, not the API budget, and never runs beside something the user started (`busy`). Actions refresh after running; failures show full output (`GitOutputSheet`).
- Force Push is `--force-with-lease --force-if-includes` so a background fetch can't make it overwrite commits the user never had; it is confirmed.
- Pull follows `pull.rebase`; on divergence git asks and Gannin asks Merge or Rebase.
- Hunk Stage/Unstage/Discard use `git apply --cached`, `--cached -R`, `-R`; disabled while Hide whitespace is on or the diff is cut short. Stage/discard of a staged file with unstaged edits must say both go.
- `LocalRepository.headUnpushed` (Amend/Undo only for an unpushed commit) = ahead of upstream, or no upstream and on no remote branch, so a branch just made from `origin/main` can't take main's commit back. Undo is `reset --soft`.
- New branches are made `--no-track` so the first push publishes under their own name. Remote branch deleted is `GitBranch.remoteRef` (the branch's own ref or a local one's upstream, e.g. `fix` tracking `origin/feature/fix`).
- Switching with changes: leave them (stashed as `Gannin: left on <branch>`, restored and dropped by SHA, never a bare pop) or bring them.
- Worktree locations: `<harness>/.worktrees/<branch>/<name>` for a clone in `projects/` (as sessions lay out), else `<clone>.worktrees/<branch>`. Remove is forced only after saying what's lost.
- Rename/delete/remove dialogs live on `LocalRepository` (`renamingBranch`, `deletingBranch`, `removingWorktree`, shown by `BranchDialogs`) so they survive the popover closing.
- `FixedSplit` (leading, or trailing with `fixing:`) is used instead of `HSplitView` so the split never shifts as content loads. `DiffScroll` sizes every row to the longest line measured in the monospaced font (a lazy stack can't measure undrawn rows).
- Tags: `ls-remote --tags` when History opens, to mark tags only local.
