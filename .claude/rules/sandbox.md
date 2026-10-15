---
paths:
  - "Gannin/Sandbox/**"
---
# Sandboxed sessions

Work on This sessions and their helpers run claude in an Apple `container` VM, one per issue; review, planning, Ask and `claude -p` stay on the Mac. Use the `container` CLI through `Shell.run`, never its Swift API.

## Credentials (trust boundary)
- Only these go in: Claude's sign-in or an API key, a per-org fine-grained GitHub token, a signing key, git name and email. Never the user's Claude or gh login, Gannin's token, or SSH keys.
- Never collect, store or forward a Claude subscription's credentials; it signs in inside the sandbox via Anthropic's flow. `removeStoredSubscriptionToken` clears any stored by an earlier build.
- Write `secrets.env` as 0600, only when every credential is present, and have `inner.sh` delete it after reading.

## Mounts
- Mount the harness read-only.
- Mount each git dir read-only, with only `objects`, `refs`, `logs` and `worktrees` writable inside, so a sandbox can't change config or hooks that Mac git would then run. Other issues' worktrees stay read-only.
- Mount everything at its real path (`pwd -P`), as git records paths.
- The `dev.andon.gannin=1` label (`SandboxImages.label`) goes on everything Gannin makes; cleanup must touch nothing without it.
- Stop the container when no session using it runs and at quit; delete it with the issue's session.
- Sessions that need the Mac (`OrgConfig.reposNeedingMac`) or an org with no GitHub token run on the Mac (`SandboxPlacement.decide`).
- Never move a session between the Mac and a sandbox once it has started: its conversation lives where it began (`SandboxPlacement.startedBefore`). Turning sandboxing off leaves sandboxed sessions sandboxed.
- Never sandbox a session whose Connect with command isn't ssh: it can't be handed credentials. Say why.
- Turn sandboxing on only when the service, kernel and base image are ready and the Claude credential and signing key exist.
- Helpers share their issue's container, with their folders under the issue's (`SessionStore.sandboxHelperParents`); every start must mount them.

## Starting
- Never delete or run a container outside `sandbox.lock` (in the issue's folder), and check that it's running only after taking it: a session and its helper starting together both see it missing, and the loser's `delete --force` removes the winner's container.
- Release the lock explicitly (`sandbox_unlock`), not with a trap: `fail` and the final `exec` replace the shell.

## Activity log
- Log events and tool names only, never a command, prompt, file, output or error text, and redact tokens by shape and value.

## Git on the Mac in sandbox-writable repos (`SandboxGitGuard`)
- A sandbox can set `core.fsmonitor`, filter or diff drivers, `core.sshCommand` or includes, or repoint a worktree's `.git`. Run the guard before any Mac git touches such a repo: the Changes pane, Finish's worktree removal, the `start.sh` harness pull, `openInEditor`, and `LocalRepository.script` in a harness a sandboxed session runs in.
- Set `GIT_CONFIG_PARAMETERS` to disable hooks, fsmonitor and submodules; require each worktree's `.git` and `commondir` to lead back to a clone's `worktrees/`; allow only `allowedKeys` in a git dir under an issue's `.worktrees/`. Otherwise name the problem and run nothing.
- Resolve paths with `SandboxGitGuard.realPath`, not Foundation's.

## Version policy
- Bump `SandboxSupport.tested`, `installer` and `installerSHA256` together, after the spike checks; a test keeps them in step.

## Known gaps
- No egress allow list (open NAT); commits are signed with the sandbox's key; Linux only.

## Testing
- `SandboxGitGuardTests`, `SandboxLaunchTests`, `SandboxCredentialsTests`, `SandboxImagesTests`, `SandboxPlacementTests`, `SandboxRuntimeTests`.
- Unit tests can't start a container; mounts and launch behaviour need Apple `container` on a real Mac.
