---
paths:
  - "Gannin/Git/**"
---

# Local git

- Use the git CLI via `Shell.run`, never a library, so the user's config, hooks, signing and credential helper apply. Never handle a git credential, and never let git prompt (`GIT_TERMINAL_PROMPT=0`, no stdin).
- Git in a repo a sandbox could have written must pass `SandboxGitGuard` (`LocalRepository.script` does via `applies(to:)`); see the sandbox rules.
- Force Push must be `--force-with-lease --force-if-includes` and confirmed, so the background fetch can't let it overwrite commits the user never had.
- The background fetch must never run beside a user-started action (`busy`).
- Create branches with `--no-track` so the first push publishes under the branch's own name.
- Delete a remote branch via `GitBranch.remoteRef` (its own ref or a local one's upstream, not assumed `origin/<name>`).
- `headUnpushed` gates Amend and Undo: ahead of upstream, or no upstream and on no remote branch. A branch just made from `origin/main` must not be able to take main's commit back.
- Stashing to switch branches uses the message `Gannin: left on <branch>` and is restored and dropped by SHA, never a bare pop (the stash stack is shared).
- Hunk stage, unstage and discard use `git apply` (`--cached`, `--cached -R`, `-R`); disable them with Hide whitespace on or a truncated diff, since the patch wouldn't match.
- Discarding a staged file that also has unstaged edits must say both go.
- Remove a worktree with force only after saying what's lost.
- Keep rename/delete/remove dialogs on `LocalRepository` so they survive the popover closing.
- Use `FixedSplit`, not `HSplitView`, so the split doesn't shift as content loads.

## Testing
- Only `SandboxGitGuardTests` touches this area; check everything else by hand in Work > Repositories after `scripts/relaunch.sh`, using a scratch repo.
