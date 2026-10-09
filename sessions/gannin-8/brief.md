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
