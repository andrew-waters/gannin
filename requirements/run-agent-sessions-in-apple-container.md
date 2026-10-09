---
type: requirement
status: in-progress
summary: "Gannin can run its Claude Code sessions inside an Apple container sandbox it sets up itself, so an agent can only reach its own worktree and what it is given."
issues: [andrew-waters/gannin#8]
plans: [plans/2026-10-09-run-agent-sessions-in-apple-container.md]
---

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
