---
paths:
  - "Gannin/Sandbox/**"
---
# Sandboxed sessions

Work on This sessions and their helpers can run claude in an Apple `container` Linux VM, one per issue. Review, planning, Ask and `claude -p` stay on the Mac. It's the `container` CLI via `Shell.run` (here or ssh), never its Swift API. Everything Gannin makes carries label `dev.andon.gannin=1` (`SandboxImages.label`); cleanup touches nothing else.

## Version policy (`SandboxSupport`)
- `minimum` (below it, no sandbox), `tested` (Install/Update target, with its signed installer URL and SHA-256); newer runs with a note. To move: do the spike checks, then bump `tested`, `installer`, `installerSHA256` together (a test keeps them in step).
- `features` are flags checked by name in each subcommand's help, so a renamed flag is reported by name whatever the version.

## Runtime and setup
- `SandboxRuntime` reads a `SandboxBox` (`.local` or `.remote(connect:)`) in one probe script into `SandboxHost`; `problem` and `versionNote` give plain-words causes. Starts the service with `--disable-kernel-install`, sets the recommended kernel only when none is set. Local install downloads and hash-checks as the user, re-checks and installs in one admin prompt. `remoteInstallScript` runs over `ssh -t` (`withTerminal`, `remoteBash`); Gannin never sees the remote sudo password.
- Sandboxing turns on only when this Mac is ready (service, kernel, base image) and the Claude credential and signing key exist.

## Images
- `SandboxImages.baseContainerfile` (Claude Code's updater is off, so a new Claude Code needs a new base) is built as `gannin-base:<hash>`, retagged `latest`. A repo's `.gannin/sandbox/<repo>.Containerfile` (`FROM gannin-base`) builds as `gannin-<repo>:<hash of it and the base>` on the box from the checkout. `removeAll` deletes labelled containers and images from the CLI's JSON.

## Credentials (trust boundary)
- Keychain service `dev.andon.gannin.sandbox` (`Keychain` takes service and account). Only these go in: Claude's sign-in or an API key, a per-org fine-grained GitHub token (`GH_TOKEN`), a signing key (no passphrase), git name and email. Never the user's Claude or gh login, Gannin's token, or SSH keys.
- `ClaudeKind.signIn`: claude signs in inside the sandbox via Anthropic's flow; its login lives in `claudeFolder` (shared by every sandbox) and Gannin never reads it. `.apiKey` is passed as `ANTHROPIC_API_KEY`, the only Claude credential Gannin holds.
- Gannin never collects, stores or forwards a subscription's credentials (Claude Code's terms require Anthropic's own flow). A token an earlier build stored is removed at launch (`removeStoredSubscriptionToken`).
- `secrets.env` (0600) is written by `SessionStore.prepareSandbox` (over ssh stdin via `remoteSecretsScript` for a server, `Shell.run(_:_:input:)`), only when every credential is present. `inner.sh` reads and deletes it.
- House rules (`sandbox.claudeMemory`) travel in `secrets.env` and `inner.sh` writes them to `SandboxLaunch.houseRulesFile` in the shared config via a temp file, adding an import once to claude's `CLAUDE.md`, which is otherwise left alone.

## Placement
- `SandboxPlacement.decide`: sandbox once on, else the Mac with a `hostReason` when a repo is in `OrgConfig.reposNeedingMac` or the org has no GitHub token. `CodeSession.sandbox` is the container (`gannin-<session id>`). `startedBefore`: a session that began before sandboxing stays on the Mac; turning sandboxing off leaves sandboxed sessions sandboxed (their conversation is there). A Connect with command that isn't ssh can't be handed credentials, so isn't sandboxed (and says why).

## Launch (`SandboxLaunch`)
- `SessionScript.harnessStart` prepares the harness, then `hostSteps` checks the box (Apple Silicon, macOS 26+, container at least `minimum`), starts service and kernel, clones the issue's repos into `projects/` (a sandbox can't add clones the Mac sees), builds or finds the image, and unless the container is running recreates it with every mount at its real path (`pwd -P`; git records them).
- Mounts: harness read-only; tmpfs over `.worktrees/` and `projects/` with the issue's folder and the issue's repos' git dirs inside (`cloneRepos`, found by origin with `findClone`; the harness's own only when it's the code repo with no `projects/`). Each git dir is read-only so config and hooks can't be changed for Mac git to run; `objects`, `refs`, `logs`, `worktrees` are read-write inside it, except each existing `worktrees/<name>` outside the issue's folder (read-only, so another's `commondir` can't be repointed). `FETCH_HEAD` is linked into `logs/` on the Mac first. `refs/` stays writable, so any branch can move.
- Inside: `branch.autoSetupMerge`, gc and maintenance off, branch deletes blocked, rebase/pull print a harmless `packed-refs.lock` error (the sandboxed brief says so and to push with `git push origin HEAD`). The brief says only `projects/` repos exist (a clone made inside vanishes).
- Then mount the issue's session folder, the shared `claudeFolder` as `/root/.claude`, and the issue's `claude-home/projects` over its `projects/` (transcripts). Gannin and Orchard labels (`com.orchard.sandbox`) and the caps. `container exec -it` runs `innerScript`: reads secrets, writes the signing key under `/run`, sets git identity and signing, merges into the shared `.claude.json` with jq (`seedClaudeConfig`), runs `claudeSteps` with `CLAUDE_CONFIG_DIR`. Hooks write to the session folder at its real path (mounted) so the poll works as for local sessions, plus `sandbox` state. `modeBox` is `sandbox`.
- Activity log: the container's process follows `sandbox.log` (`activityLogName`); `inner.sh` writes `activityScript` to `/run` and sandboxed settings (`settings(sandboxed:)`) add hooks calling it. Events and tool names only, never a command, prompt, file, output or error text; tokens redacted by shape and value.
- Helpers share the issue's container: folders `helpers/<id>` inside the issue's (`directory(for:)` via `sandboxHelperParents`, `remoteDirectory(for:)` on a server), mounted on every start. The container stops when no session using it runs (`stopSandboxIfIdle`, tracked in `stoppingSandboxes` so a quick restart waits) and at quit (`stopSandboxesForQuit`, after the quit question); deleted with the issue's session. `launching` stops `open` starting a second terminal while one waits on a stop or secrets.

## Git on the Mac in sandbox-writable repos (`SandboxGitGuard`)
- A sandbox could set `core.fsmonitor`, a filter or diff driver, `core.sshCommand` or an include, or repoint a worktree's `.git`; a worktree's `.git` and `worktrees/` stay writable and a repo can be nested in a worktree. So before the Changes pane, Finish's worktree removal (`SessionChanges.guarded`), the `start.sh` harness pull (subshell), `openInEditor` and `LocalRepository.script` in a harness a sandboxed session runs in (`applies(to:)`, from `setRoots`, kept by `SessionStore` whether or not sandboxing is still on): `GIT_CONFIG_PARAMETERS` (kept for submodules) disables hooks, fsmonitor, submodules; each worktree's `.git` and `commondir` must lead back to a clone's `worktrees/`; a git dir under an issue's `.worktrees/` may hold only `allowedKeys`. Anything else is named and nothing runs.
- Resolve paths with `realPath` (`realpath`, as `pwd -P`), not Foundation's.

## Not done
- No egress allow list (open NAT; Mac services on all interfaces reachable at the gateway); commits signed with the sandbox's key, not the user's; Linux only.
