# andrew-waters/gannin#8: Run agent sessions in Apple container sandboxes, with optional local models

https://github.com/andrew-waters/gannin/issues/8

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 4 Oct 2026
- Assignees: @andrew-waters
- Board "Roadmap": Status Todo

## Description

## Problem

When Gannin starts an agent session (Work on This, Review with Claude, and so on), Claude Code runs directly on the user's Mac with the user's own permissions. It can read and write anything the user can: other repos, `~/.ssh`, keychains, cloud credentials, shell history and the rest of the home directory. Its network access is unrestricted too. A bad prompt, a prompt injection from an issue body or a dependency, or a mistaken command can reach well beyond the session's worktree.

Gannin is a Mac app, so it can use macOS primitives to contain this. My side project andrew-waters/orchard already integrates deeply with Apple's `container` framework (Containerization). Gannin should use the same primitives in a lighter way: not everything Orchard exposes, but enough to set itself up automatically so users can run agents in sandboxes safely without configuring anything.

Some users also want agents, or parts of agent work, to run against local models on Apple Silicon (for example oMLX or other MLX-based servers) instead of only hosted models, for privacy, cost or offline use. Gannin has no support for this today.

## Proposal

Two related capabilities, planned together because they share the runtime and settings work. The how below is a starting plan to be challenged, not a decision.

### 1. Sandboxed agent sessions

- **Execution modes per session:** `Host` (today's behaviour) and `Sandboxed` (Claude Code runs inside a lightweight Linux VM through Apple `container`). A setting picks the default; each session can override it.
- **Auto-configuration:** on first use Gannin detects whether Apple `container` is available, checks macOS version and hardware, and offers to install or start what is missing. Gannin builds or pulls a base image with Claude Code, git, gh and common toolchains, then caches it. The user should not need to write a Containerfile.
- **Filesystem:** mount only the session's worktree (`.worktrees/<branch>/<name>`) read-write, plus the session's `.gannin/` brief read-only. No home directory, no other repos, no `projects/` shared clones except through the worktree.
- **Credentials:** pass in only what the session needs, scoped and short-lived where possible (Anthropic API key or token, a GitHub token limited to the repo). Nothing from the user's keychain or `~/.ssh` is mounted by default.
- **Network:** a default policy (for example: allow the Anthropic API, GitHub and the configured package registries; deny everything else), with a per-repo allow list. Whether Apple `container` can enforce egress rules natively, or Gannin needs a proxy, is unknown (see Open questions).
- **Resource limits:** CPU and memory caps per session, so several sandboxed sessions do not freeze the machine.
- **Lifecycle:** create the container when the session starts, stop it when the session ends or is paused, and clean up images and volumes Gannin owns. Show sandbox state (running, stopped, failed) in the session view.
- **Hooks and session tracking keep working:** Gannin today reads `gh pr create` output and other hook events to update `session.json`. Those hooks must still reach Gannin from inside the sandbox (for example over a mounted socket or a mounted `.gannin/` path).
- **Fallback:** if sandboxing is unavailable (older macOS, Intel Mac, feature disabled), say so plainly and fall back to Host mode only with the user's consent.

### 2. Local model support

- **Model providers:** let a session, or a role within it, point at a local OpenAI-compatible or Anthropic-compatible endpoint (for example an oMLX or other MLX server on the host) as well as the hosted Anthropic API.
- **Discovery:** detect a running local server on known ports and list its models; otherwise let the user enter an endpoint.
- **Sandbox access:** a sandboxed session must be able to reach the host's local model server and nothing else on the host network.
- **Honest limits:** show which Gannin features need a hosted model (if any turn out to) and warn when a local model may be too weak for a task.

### Relationship with Orchard

Reuse Orchard's work on Apple `container` rather than reimplementing it. Options, to decide in the first step:

1. Depend on a Swift package extracted from Orchard (shared library, Gannin uses a subset).
2. Talk to the `container` CLI or its API directly, with Orchard as reference only.
3. Treat Orchard as an optional companion app that Gannin detects and drives.

### Suggested phases

1. **Spike:** confirm what Apple `container` gives us (mounts, networking, egress control, host socket access, start-up time), what Orchard already wraps, and pick an integration option. Write it up as a plan in the harness.
2. **Runtime and image:** detection, setup flow, base image build and cache, start and stop a container for a worktree.
3. **Sandboxed sessions:** run Claude Code inside, with worktree mounts, scoped credentials, hooks reaching Gannin, and the per-session mode toggle.
4. **Network policy and resource limits.**
5. **Local models:** provider settings, discovery, routing from the sandbox to the host server.
6. **Docs:** update `CLAUDE.md` for the new settings, stores and any new GitHub writes, plus a user-facing guide.

Each phase could become a sub-issue under this one.

## Acceptance

- [ ] A user on a supported Mac can turn on sandboxing and start a sandboxed session without writing any container configuration.
- [ ] Inside a sandboxed session the agent can read and write its worktree, run git, gh and the repo's build, and open a PR; it cannot read the user's home directory, other repos or keychain.
- [ ] Outbound network from the sandbox follows the configured policy; a request to a host not on the allow list fails.
- [ ] Session tracking (PR detection, `session.json` updates, workload and metrics) works the same in Sandboxed and Host modes.
- [ ] CPU and memory limits apply per sandboxed session.
- [ ] Sandboxes and images Gannin creates are cleaned up when sessions end or the feature is turned off.
- [ ] On an unsupported setup Gannin explains why and does not silently run unsandboxed.
- [ ] A session can be pointed at a local model endpoint on the host, including from inside a sandbox.
- [ ] `CLAUDE.md` and user docs describe the new behaviour.

## Open questions (unknown today)

- Which macOS version and hardware Apple `container` needs, and whether Gannin's current minimum macOS target supports it.
- Whether Apple `container` can restrict egress per container, or whether Gannin needs its own proxy.
- How the sandbox reaches Gannin's hooks and a local model server on the host, and whether that can be limited to just those.
- How Claude Code authentication works inside a sandbox (API key versus subscription login) and how to pass it safely.
- What Orchard's code is structured as today, and whether a shared package is practical.
- Whether App Sandbox or notarisation rules limit Gannin from managing containers directly.
- Which local model servers to support first (oMLX, other MLX servers, Ollama, LM Studio) and which API shape Claude Code can use with them.
- Performance cost: container start-up time and build speed for typical repos compared with Host mode.

## Context

- Related project: andrew-waters/orchard (Apple `container` integration).
- Not checked yet: duplicates in this repo, and Orchard's current API.

## Plans and requirements

From the team's harness repo, andrew-waters/gannin, which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.

### Sandboxed agent sessions

Plan, in progress, about this issue: `plans/2026-10-09-run-agent-sessions-in-apple-container.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-09-run-agent-sessions-in-apple-container.md)

Run Gannin Claude Code sessions inside Apple container sandboxes that Gannin sets up itself. Local models come later.

# Sandboxed agent sessions

Run Gannin Claude Code sessions inside Apple container sandboxes that Gannin sets up itself. Local models come later.

## Context

- Also looked at: i also have andrew-waters/orchard which has a lot of machinery we can lean on for this feature

## Requirement

In full in [requirements/run-agent-sessions-in-apple-container.md](../requirements/run-agent-sessions-in-apple-container.md).

**Problem:** Claude Code sessions started by Gannin run on the Mac as the user, able to read and write anything the user can (other repos, ~/.ssh, keychains, cloud credentials, shell history). A bad prompt, an injection from an issue body or a dependency, or a mistaken command can reach well beyond the session's worktree. It matters most for unattended (auto mode) sessions, which run commands nobody approves one by one.

**Goal:** Gannin can run its Claude Code sessions inside an Apple container sandbox it sets up itself, so an agent can only reach its own worktree and what it is given.

**Who it's for:** Anyone who runs Work on This sessions from Gannin on an Apple Silicon Mac, starting with the team that wants agents to work unattended without risking the rest of their machine.

**Scope:**

1. Settings to turn sandboxing on, which runs setup: detect Apple container, install it with one admin prompt, start its service, set the kernel and build the base image, with progress and plain errors.
2. Claude Code sign-in for sandboxes: a setup-token subscription token or an Anthropic API key, the user's choice, kept in the keychain.
3. A fine-grained GitHub token per org, with guidance to create it, kept in the keychain and passed in as GH_TOKEN.
4. Work on This sessions and their helpers run claude inside a container with only the session's folder and what git needs mounted, by default once sandboxing is on; Host can be picked when a session starts.
5. A per-repo setting marking a repo as needing the Mac, whose sessions start on the Host and say why.
6. A base image with Claude Code, git, gh, Node, Python and build tools; a repo can extend it with a Containerfile in the harness; Gannin builds and caches them.
7. CPU and memory caps per sandbox, with defaults in Settings.
8. Hooks, state, changed, PR detection, Changes, transcripts, the composer, modes and pair review work the same as on the Host.
9. The sandbox runs while the session's claude runs, is stopped when it exits or Gannin quits, comes back on resume, and is removed with Finish Session; turning sandboxing off removes what Gannin built.
10. Sandbox state (starting, running, stopped, failed) shown on the session.
11. Sandboxed sessions on a Connect with server that is a Mac with container installed: checked over ssh, service started, images built and containers run there, with mounts at the server's paths.

**Out of scope:**

- Local model support (oMLX, MLX, Ollama and the like): a follow-up plan built on the sandbox.
- An egress allow list or proxy: v1 sandboxes have open outbound network, and the protection is to files, keys and other repos.
- Sandboxing Review with Claude, planning, Ask sessions and claude -p runs: they stay on the host in v1.
- Installing Apple container on a remote Mac, or sandboxing on Linux servers (Apple container runs only on Apple Silicon Macs).

**Acceptance criteria:**

- **R1** When the user turns on sandboxing on a supported Mac without Apple container, the system shall offer to install it, and after one admin prompt shall start its service, set its kernel and build the base image with no container configuration from the user.
- **R2** When the Mac is not Apple Silicon on macOS 26, or setup fails, the system shall say why in plain words and keep sessions on the Host only with the user's consent, never silently.
- **R3** When sandboxing is on and a Work on This session starts for a repo not marked as needing the Mac, the system shall run its claude inside a container by default, and shall let the user pick Host for that session when it starts.
- **R4** When a session runs sandboxed, the agent shall be able to read and write the session's worktrees, commit, run the repo's Linux build and tests, push and open a pull request with gh.
- **R5** When a session runs sandboxed, the agent shall not be able to read the user's home directory, ~/.ssh, keychain, other repos' working trees or other sessions' folders.
- **R6** When a session runs sandboxed, the only credentials inside shall be the chosen Claude credential (subscription token or API key) and the org's fine-grained GitHub token.
- **R7** When the user sets up sandbox credentials, the system shall let them choose a setup-token subscription token or an API key for Claude, and guide them to create a fine-grained GitHub token per org, storing each in the keychain.
- **R8** When a repo is marked as needing the Mac, the system shall start its sessions on the Host and say so on the session.
- **R9** When a repo has a Containerfile for sandboxes in the harness, the system shall build an image from it on top of the base image, cache it, and rebuild it only when it or the base changes.
- **R10** When a session runs sandboxed, its state, changed signals, PR detection, Changes, transcript, Activity, questions, modes and pair review shall behave as they do on the Host.
- **R11** When a sandbox starts, the system shall apply the CPU and memory caps from Settings to it.
- **R12** When a sandboxed session's claude exits or Gannin quits, the system shall stop its container; when the session is resumed it shall start one again with the same folders; when the session is finished it shall remove it.
- **R13** When the user turns sandboxing off, the system shall remove the containers and images Gannin created, after confirming.
- **R14** When a session runs sandboxed, the system shall show its sandbox state (starting, running, stopped, failed) on the session, with the error when it failed.
- **R15** When the change ships, CLAUDE.md shall describe sandboxed sessions, their settings and stores.
- **R16** When sandboxing is on and sessions run on a Connect with server that is an Apple Silicon Mac on macOS 26 with container installed, the system shall run Work on This sessions there in a container on that Mac, with R4, R5, R6, R10, R11, R12 and R14 holding as they do locally.
- **R17** When the Connect with server has no container, is not a supported Mac, or its container service will not start, the system shall say which and how to fix it on that machine, and shall run there unsandboxed only with the user's consent.

**Decisions:**

- What is the smallest first version worth shipping? **Sandboxed sessions first. Local models are a follow-up, planned separately on top of the sandbox.**
- What network access should a sandboxed session get in the first version? **Open outbound network (NAT) in v1. An egress allow list through a Gannin proxy is a follow-up.**
- How should Claude Code sign in inside a sandbox? **The user picks in Settings: a subscription token from claude setup-token (CLAUDE_CODE_OAUTH_TOKEN) or an Anthropic API key (ANTHROPIC_API_KEY). Either is kept in the keychain by Gannin and passed in as an environment variable; nothing else from the keychain goes in.**
- Which GitHub credentials should a sandboxed session get? **A fine-grained personal access token the user creates for the org (contents, pull requests, issues), which Gannin walks them through, keeps in the keychain per org and passes in as GH_TOKEN. Neither Gannin's own GitHub token nor the gh login goes in.**
- Which sessions can run sandboxed in the first version? **Work on This sessions and their helpers (the pair reviewer included). Review with Claude, planning, Ask and claude -p runs stay on the host for now.**
- Once sandboxing is set up, how should new Work on This sessions start? **Opt in: off until turned on in Settings and setup finishes. From then on new Work on This sessions start sandboxed by default, and each can be switched to Host when it starts.**
- What should happen for repos that cannot build in a Linux sandbox, such as Xcode apps? **A repo can be marked as needing the Mac. Sessions for issues in such a repo start on the Host and say why; every other repo is sandboxed by default.**
- What image do sandboxes run? **A Gannin base image (Claude Code, git, gh, Node, Python, build tools) that needs no setup, which a repo can extend with a Containerfile kept in the harness. Gannin builds and caches both.**
- How far should Gannin go in installing Apple container? **Install it: detect it, offer to download Apple's signed installer from its GitHub release and run it with one admin prompt, then start the system service and set the recommended kernel.**
- Are the requirements and acceptance criteria (R1 to R15) right? **Yes, approved as written.**
- From the room: can sandboxes run on remote machines (ssh, then container)? How much goes in the first version? **Yes, in v1, for a Connect with box that is an Apple Silicon Mac on macOS 26 with container already installed. Gannin checks it over ssh, starts its service, builds the images and runs the containers there; when container is missing it says how to install it on that Mac rather than installing it.**
- Are the requirements right with remote sandboxes added (R16, R17)? **Yes, approved.**

## Design

Sandboxed sessions follow the server-session path Gannin already has, with `container exec` where ssh would be, and drive Apple's `container` CLI through `Shell.run`, using Orchard as a reference rather than a dependency.

**Runtime (`Gannin/Sandbox/`).** `SandboxRuntime` finds the `container` binary (Orchard's lookup: /usr/local/bin, /opt/homebrew/bin, a custom path), checks for Apple Silicon and macOS 26, reads `container system status`, and on setup downloads Apple's signed installer from its GitHub release, runs it with one admin prompt (`installer` through an AppleScript admin prompt, as Orchard's `runWithSudo` does), runs `container system start` with polling, and sets the recommended kernel. Each step reports progress and the CLI's own error in full (the `GitOutputSheet` pattern).

**Images.** `SandboxImages` builds `gannin-base:<version>` from a Containerfile shipped in the app bundle (Debian slim, Claude Code, git, gh with `gh auth setup-git`, Node, Python, build-essential). A repo's Containerfile in the harness (`.gannin/sandbox/<repo>.Containerfile`, starting `FROM gannin-base`) builds `gannin-<owner>-<repo>:<hash>`, the hash covering it and the base, so it rebuilds only when either changes. Builds stream into the session's sandbox status. Turning sandboxing off removes Gannin's containers and images (labelled `dev.andon.gannin=1`).

**Containers.** One per issue folder, named `gannin-<session id>`, created when the issue's session starts (`container run --detach --label ... --cpus N --memory M`, `sleep infinity` as its process), with mounts at their Mac paths: the harness read-only, an empty Gannin folder over `.worktrees/`, the issue's `.worktrees/<branch>/` read-write inside it, `projects/` read-write, the session folder read-write (which holds helpers' folders as `helpers/<id>/` for sandboxed sessions, so they're mounted from the start), and `<session folder>/claude-home` as `/root/.claude`. Credentials: the Claude credential (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`) and `GH_TOKEN` are written to a `0600` `secrets.env` in the session folder just before launch (over ssh on stdin for a server, never on a command line), which the in-container script exports and deletes, so they're in neither the container's config nor a process list. Network is the default NAT.

**Launch.** `CodeSession` gains `sandbox` (nil on the Host; the container name otherwise, decoded with `decodeIfPresent`) and `isSandboxed`. `SessionScript.harnessStart` splits: the Mac part (clone or pull, info/exclude, copy brief and settings) runs first through `Shell.run`; then the terminal runs `container exec -it --env ... <name> bash <start.sh>`, packed as `remoteCommand` packs today, whose script only `cd`s to the harness and runs `claude --session-id`/`--resume`. Hooks keep their absolute paths because the session folder is mounted at the same path; the local poll reads them as for any local session. `findTranscript` also looks in the session's `claude-home`. `modeBox` gets a `sandbox` key. Helpers of a sandboxed session `exec` into the parent's container.

**On a server.** A sandboxed session with Connect with runs the same steps on the box: `SandboxRuntime` takes a `Shell.Runner` (`.local` or `.ssh`), so the checks (`uname -m`, `sw_vers`, `container system status`), `container system start`, image builds (the base Containerfile sent over ssh) and `container run` happen there, with mounts at the box's paths (its harness checkout, `~/.gannin/sessions/<id>`). The terminal runs Connect with, then `container exec -it` on the box, wrapped as `remoteCommand` is. `readRemote` keeps reading hooks over ssh, and looks for the transcript in the session's `claude-home` as well as `$HOME/.claude`. Changes keeps using the ssh runner, since the paths are the box's. Nothing is installed on a server: a missing or unsupported `container` is reported with the steps to fix it there (R17).

**Lifecycle.** The container stops (`container stop`) when the last session using it exits (`terminated`), on `end`, and on quit (`QuitGuard` stops them all and says so); `open` starts it again before exec on resume; `finish` and `remove` delete it after removing the worktrees on the Mac. Session state shows Starting sandbox, Running, Stopped and Failed with the error.

**Settings.** Settings > General > Agent gains a Sandbox section: on or off (setup runs on turning it on), Claude credential (subscription token from `claude setup-token`, run in a sheet, or API key), CPU and memory per sandbox. Keychain is parameterised (service and account) for the Claude credential and a fine-grained GitHub token per org, set in Settings > Harness with a link that opens GitHub's new-token page with the scopes named. A per-repo Needs the Mac checkbox follows `reposWithoutReview` (OrgConfig, Settings > Repositories, shared through the harness as team exclusions). Work on This's launch sheet shows Sandboxed or Host, defaulting to Sandboxed when it's on and the repo doesn't need the Mac, and saying why when it can't be.

**Why this way.** It reuses the remote session machinery (packed command, poll, Changes) instead of a parallel path, keeps every Mac-side tool working by mounting at the same paths, and avoids pinning to the container Swift API, which changes between releases and has no exec anyway.

**Areas it touches:**

- `andrew-waters/orchard` `Orchard/Services/ContainerBackend.swift`: ContainerBackend protocol and LiveContainerBackend over apple/container 1.5.0's ContainerAPIClient (XPC): create with virtiofs mounts (ro supported), env, CPU and memory limits, ports, network; start, stop, kill, delete, logs, stats. Pure of SwiftUI, takes Orchard's own model types.
- `andrew-waters/orchard` `Orchard/Services/SystemService.swift`: Detection and setup: XPC ping, version check against the supported container version, `container system start` then polling, kernel set --recommended. Doesn't install container; links to its release page. @MainActor ObservableObject, coupled to Orchard's alerts and settings.
- `andrew-waters/orchard` `Orchard/Services/CommandRunner.swift`: Shells out to the container CLI (run, streaming, sudo through an AppleScript admin prompt); binary found in /usr/local/bin, /opt/homebrew/bin and the like (SettingsStore). Used for system start, build, builder, dns and exec.
- `andrew-waters/orchard` `Orchard/Services/ImageBuildService.swift`: `container build` with file, tag, arch, build args, streamed output. Caching is the container image store and BuildKit's.
- `andrew-waters/orchard` `Orchard/Services/ModelBackend.swift`: Local model discovery (Ollama 11434, LM Studio 1234, MLX 8080/8000, oMLX recognised) via /v1/models with a short timeout, and ModelBridge: a container reaches the host through the vmnet gateway address; the host server must bind 0.0.0.0. Injects OPENAI_BASE_URL/OLLAMA_HOST, not ANTHROPIC_BASE_URL.
- `andrew-waters/orchard` `Orchard/Services/Sandbox.swift`: A sandbox is a labelled container with a model endpoint; isolated means on a host-only network. Nothing Claude Code specific.
- `andrew-waters/gannin` `project.yml#L4-L5`: Gannin targets macOS 26, as Apple container and Orchard do; not App Sandboxed, so it can drive container.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L52-L116`: harnessStart: clone or pull the harness, exclude projects/ and .worktrees/, copy brief and settings into .worktrees/<branch>/.gannin/, cd to the harness root and run claude --session-id or --resume. claude adds its own worktrees from projects/<name> with absolute paths.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L723-L782`: launch: local sessions run bash start.sh through $SHELL -l -i -c in a SwiftTerm LocalProcessTerminalView, env stripped of CLAUDE_CODE_*; remote ones run the Connect with command.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L11-L147`: CodeSession: a sandbox field goes beside connect and remoteWorkspace, decoded with decodeIfPresent in the hand-written init(from:); modeBox (SessionMode.swift#L137) needs a sandbox box key.
- `andrew-waters/gannin` `Gannin/Auth/Keychain.swift`: One fixed service and account for the GitHub token; the Claude credential and per-org PATs need it parameterised.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L1546-L1648`: Settings > General > Agent (SessionSettingsSection), Claude Code section with Workspace and Connect with: where Sandbox settings go.
- `andrew-waters/gannin` `Gannin/Sessions/QuitGuard.swift#L54-L90`: Quit, end (SessionStore.swift#L696), remove (#L701-L721), finish (SessionActions.swift#L480-L487) and terminated are where containers stop and are removed.

**Patterns to follow:**

- `andrew-waters/orchard` `Orchard/Services/TerminalLauncher.swift`: Interactive shells are `container exec -it <id> <shell>` in an external terminal; no exec API. Gannin would run the same command in its own SwiftTerm terminal, as it runs ssh for server sessions today.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L316-L337`: remoteCommand packs start.sh, brief and settings into one base64 bootstrap and runs it through the Connect with command ({command} placeholder). A `container exec -it <name> {command}` runs the same way, so the sandbox can follow the server-session path.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L234-L296`: Hooks write state, started, pr, changed and statusline to the session folder by absolute path, read by the 1s local poll (SessionStore.swift#L1096-L1125). Mounting the session folder at the same path in the sandbox keeps them working unchanged.
- `andrew-waters/gannin` `Gannin/Metrics/OrgConfigStore.swift#L14`: reposWithoutReview (a Set per org, Needs Review checkbox in OrgSettingsView, shared through the harness as TeamExclusions) is the pattern for a per-repo needs-the-Mac flag.

**Risks:**

- `andrew-waters/orchard` `Orchard/Services/ContainerBackend.swift`: All Orchard's container code is in its app target; reuse means extracting a package or copying. Pinned to container 1.5.0, whose API still moves between releases.
- `andrew-waters/orchard` `scratch/docs/plans/plan-local-models-mlx.md`: Orchard's own plan warns against claiming isolation beyond Apple's VM boundary plus the network setting; oMLX has an Anthropic-compatible API, which is what Claude Code would need.
- `andrew-waters/gannin` `Gannin/Sessions`: A session runs claude in the harness root and claude adds worktrees from the shared clones in projects/<name>. A git worktree's .git points back into its clone's .git, so mounting only .worktrees/<branch>/ breaks git; the sandbox needs the clones' git directories too, or its own clones.
- `andrew-waters/gannin` `project.yml`: The sandbox is a Linux VM: macOS-only builds (xcodebuild, Swift with AppKit, Gannin itself, Orchard) cannot run inside it.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1074-L1080`: findTranscript scans the Mac ~/.claude/projects. In a VM claude writes its transcript to the VM HOME, so its ~/.claude needs mounting from a per-session folder on the Mac and findTranscript needs to look there.
- `andrew-waters/gannin` `Gannin/Sessions/SessionChanges.swift#L119-L129`: Changes, removeWorktrees and editors run git on the host against worktree paths; worktree .git files hold absolute paths, so they only work if the sandbox mounts things at the same absolute paths as on the Mac (else a container exec Shell.Runner, like the ssh one).
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L82-L98`: With the harness read-only inside, the clone or pull and the info/exclude step have to run on the Mac before the container starts; only the claude part of start.sh runs inside.
- `andrew-waters/orchard` `Orchard/Services/ContainerBackend.swift`: Nested mounts (an empty folder over .worktrees/ with the branch folder mounted inside it, rw projects/ inside a ro harness) are unproven on Apple container virtiofs: the first task spikes it.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift`: A fresh claude-home means Claude Code first-run prompts (theme, folder trust, onboarding) inside the sandbox; Gannin should seed claude-home (.claude.json with onboarding done and the harness path trusted) before the first exec.

**Decisions:**

- How should the sandbox see the harness and the code? **Same paths as on the Mac, masked: the harness read-only, an empty folder over .worktrees/ with only the issue's .worktrees/<branch>/ read-write inside it, projects/ read-write, the session's own folder read-write, and a per-session folder as claude's ~/.claude. Git, hooks, Changes and editors keep working on the Mac. The agent can write to the project's shared clones, not to other sessions or anything else.**
- How should Gannin use Orchard's work? **Drive the container CLI through Shell.run, with Orchard as reference for binary lookup, system start and polling, kernel set and build flags. No shared package and no dependency on Orchard or the container Swift API.**
- Should helpers share their parent's sandbox? **One sandbox per issue: the issue's session creates the container and helpers run in it with container exec. It stops when the last of them exits.**
- Is the design right, with remote sandboxes in it? **Yes, approved.**

## Tasks

1. [andrew-waters/gannin#77](https://github.com/andrew-waters/gannin/issues/77) Spike: prove masked same-path mounts and exec in Apple container (satisfies R5)
2. [andrew-waters/gannin#78](https://github.com/andrew-waters/gannin/issues/78) Sandbox runtime: detect, install and start Apple container (satisfies R1, R2, R17)
3. [andrew-waters/gannin#79](https://github.com/andrew-waters/gannin/issues/79) Sandbox settings and credentials in the keychain (satisfies R6, R7)
4. [andrew-waters/gannin#80](https://github.com/andrew-waters/gannin/issues/80) Sandbox images: base image and per-repo Containerfiles (satisfies R1, R9, R13)
5. [andrew-waters/gannin#81](https://github.com/andrew-waters/gannin/issues/81) Needs the Mac per repo, and Sandboxed or Host at launch (satisfies R3, R8)
6. [andrew-waters/gannin#82](https://github.com/andrew-waters/gannin/issues/82) Run Work on This sessions in a container on this Mac (satisfies R4, R5, R6, R10, R11)
7. [andrew-waters/gannin#83](https://github.com/andrew-waters/gannin/issues/83) Sandbox lifecycle, helpers in the same sandbox, and status (satisfies R10, R12, R14)
8. [andrew-waters/gannin#84](https://github.com/andrew-waters/gannin/issues/84) Sandboxed sessions on a remote Mac over Connect with (satisfies R16, R17)
9. [andrew-waters/gannin#85](https://github.com/andrew-waters/gannin/issues/85) Document sandboxed sessions in CLAUDE.md and a user guide (satisfies R15)

**Decisions:**

- Are the tasks right? **Yes, approved.**

## From the room

- it would be good to be able to SSH then run container if thats possible - so the sandboxes can be on remote machines (design)

## Open questions

- Whether nested virtiofs mounts (an empty folder over .worktrees/, rw folders inside a ro harness) work on Apple container: spiked first; if not, the harness is mounted read-write minus .worktrees/ and other sessions are hidden another way.

### Sandboxed agent sessions

Requirement, in progress, about this issue: `requirements/run-agent-sessions-in-apple-container.md` (https://github.com/andrew-waters/gannin/blob/main/requirements/run-agent-sessions-in-apple-container.md)

Gannin can run its Claude Code sessions inside an Apple container sandbox it sets up itself, so an agent can only reach its own worktree and what it is given.

# Sandboxed agent sessions

## Problem

Claude Code sessions started by Gannin run on the Mac as the user, able to read and write anything the user can (other repos, ~/.ssh, keychains, cloud credentials, shell history). A bad prompt, an injection from an issue body or a dependency, or a mistaken command can reach well beyond the session's worktree. It matters most for unattended (auto mode) sessions, which run commands nobody approves one by one.

## Goal

Gannin can run its Claude Code sessions inside an Apple container sandbox it sets up itself, so an agent can only reach its own worktree and what it is given.

## Who it's for

Anyone who runs Work on This sessions from Gannin on an Apple Silicon Mac, starting with the team that wants agents to work unattended without risking the rest of their machine.

## Requirements

1. Settings to turn sandboxing on, which runs setup: detect Apple container, install it with one admin prompt, start its service, set the kernel and build the base image, with progress and plain errors.
2. Claude Code sign-in for sandboxes: a setup-token subscription token or an Anthropic API key, the user's choice, kept in the keychain.
3. A fine-grained GitHub token per org, with guidance to create it, kept in the keychain and passed in as GH_TOKEN.
4. Work on This sessions and their helpers run claude inside a container with only the session's folder and what git needs mounted, by default once sandboxing is on; Host can be picked when a session starts.
5. A per-repo setting marking a repo as needing the Mac, whose sessions start on the Host and say why.
6. A base image with Claude Code, git, gh, Node, Python and build tools; a repo can extend it with a Containerfile in the harness; Gannin builds and caches them.
7. CPU and memory caps per sandbox, with defaults in Settings.
8. Hooks, state, changed, PR detection, Changes, transcripts, the composer, modes and pair review work the same as on the Host.
9. The sandbox runs while the session's claude runs, is stopped when it exits or Gannin quits, comes back on resume, and is removed with Finish Session; turning sandboxing off removes what Gannin built.
10. Sandbox state (starting, running, stopped, failed) shown on the session.
11. Sandboxed sessions on a Connect with server that is a Mac with container installed: checked over ssh, service started, images built and containers run there, with mounts at the server's paths.

## Out of scope

- Local model support (oMLX, MLX, Ollama and the like): a follow-up plan built on the sandbox.
- An egress allow list or proxy: v1 sandboxes have open outbound network, and the protection is to files, keys and other repos.
- Sandboxing Review with Claude, planning, Ask sessions and claude -p runs: they stay on the host in v1.
- Installing Apple container on a remote Mac, or sandboxing on Linux servers (Apple container runs only on Apple Silicon Macs).

## Acceptance criteria

- **R1** When the user turns on sandboxing on a supported Mac without Apple container, the system shall offer to install it, and after one admin prompt shall start its service, set its kernel and build the base image with no container configuration from the user.
- **R2** When the Mac is not Apple Silicon on macOS 26, or setup fails, the system shall say why in plain words and keep sessions on the Host only with the user's consent, never silently.
- **R3** When sandboxing is on and a Work on This session starts for a repo not marked as needing the Mac, the system shall run its claude inside a container by default, and shall let the user pick Host for that session when it starts.
- **R4** When a session runs sandboxed, the agent shall be able to read and write the session's worktrees, commit, run the repo's Linux build and tests, push and open a pull request with gh.
- **R5** When a session runs sandboxed, the agent shall not be able to read the user's home directory, ~/.ssh, keychain, other repos' working trees or other sessions' folders.
- **R6** When a session runs sandboxed, the only credentials inside shall be the chosen Claude credential (subscription token or API key) and the org's fine-grained GitHub token.
- **R7** When the user sets up sandbox credentials, the system shall let them choose a setup-token subscription token or an API key for Claude, and guide them to create a fine-grained GitHub token per org, storing each in the keychain.
- **R8** When a repo is marked as needing the Mac, the system shall start its sessions on the Host and say so on the session.
- **R9** When a repo has a Containerfile for sandboxes in the harness, the system shall build an image from it on top of the base image, cache it, and rebuild it only when it or the base changes.
- **R10** When a session runs sandboxed, its state, changed signals, PR detection, Changes, transcript, Activity, questions, modes and pair review shall behave as they do on the Host.
- **R11** When a sandbox starts, the system shall apply the CPU and memory caps from Settings to it.
- **R12** When a sandboxed session's claude exits or Gannin quits, the system shall stop its container; when the session is resumed it shall start one again with the same folders; when the session is finished it shall remove it.
- **R13** When the user turns sandboxing off, the system shall remove the containers and images Gannin created, after confirming.
- **R14** When a session runs sandboxed, the system shall show its sandbox state (starting, running, stopped, failed) on the session, with the error when it failed.
- **R15** When the change ships, CLAUDE.md shall describe sandboxed sessions, their settings and stores.
- **R16** When sandboxing is on and sessions run on a Connect with server that is an Apple Silicon Mac on macOS 26 with container installed, the system shall run Work on This sessions there in a container on that Mac, with R4, R5, R6, R10, R11, R12 and R14 holding as they do locally.
- **R17** When the Connect with server has no container, is not a supported Mac, or its container service will not start, the system shall say which and how to fix it on that machine, and shall run there unsandboxed only with the user's consent.

## Open questions

- Whether nested virtiofs mounts (an empty folder over .worktrees/, rw folders inside a ro harness) work on Apple container: spiked first; if not, the harness is mounted read-write minus .worktrees/ and other sessions are hidden another way.

Planned in [plans/2026-10-09-run-agent-sessions-in-apple-container.md](../plans/2026-10-09-run-agent-sessions-in-apple-container.md).

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/8-run-agent-sessions-in-apple-container/`: give each repo it touches a worktree there, on the branch `8-run-agent-sessions-in-apple-container`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/8-run-agent-sessions-in-apple-container/<name>" -b 8-run-agent-sessions-in-apple-container origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/8-run-agent-sessions-in-apple-container/gannin" -b 8-run-agent-sessions-in-apple-container origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/8-run-agent-sessions-in-apple-container/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#8" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#8]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/8-run-agent-sessions-in-apple-container/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
