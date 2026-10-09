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
2. Claude Code sign-in for sandboxes, the user's choice: Claude's own sign-in inside the sandbox, kept by Claude Code in a folder the user's sandboxes share and never seen or stored by Gannin, or an Anthropic API key kept in the keychain.
3. A fine-grained GitHub token per org, with guidance to create it, kept in the keychain and passed in as GH_TOKEN.
4. A sandbox commit signing key, made by Gannin (or pasted in), kept in the keychain, with guidance to add its public key to GitHub, so commits made in a sandbox are signed and carry the user's name and email.
5. Work on This sessions and their helpers run claude inside a container with only the session's folder and what git needs mounted, by default once sandboxing is on; Host can be picked when a session starts.
6. A per-repo setting marking a repo as needing the Mac, whose sessions start on the Host and say why.
7. A base image with Claude Code, git, gh, Node, Python and build tools; a repo can extend it with a Containerfile in the harness; Gannin builds and caches them.
8. CPU and memory caps per sandbox, with defaults in Settings.
9. Hooks, state, changed, PR detection, Changes, transcripts, the composer, modes and pair review work the same as on the Host.
10. The sandbox runs while the session's claude runs, is stopped when it exits or Gannin quits, comes back on resume, and is removed with Finish Session; turning sandboxing off removes what Gannin built.
11. Sandbox state (starting, running, stopped, failed) shown on the session.
12. Sandboxed sessions on a Connect with server that is a Mac with container installed: checked over ssh, service started, images built and containers run there, with mounts at the server's paths.
13. A Remote machines section in Settings showing the Connect with box's architecture, macOS, container version and service state, with Start Service, and Install or Update (to the tested version in the app's support policy) run in a terminal over `ssh -t` where the user types the box's admin password.

## Out of scope

- Local model support (oMLX, MLX, Ollama and the like): a follow-up plan built on the sandbox.
- An egress allow list or proxy: v1 sandboxes have open outbound network, and the protection is to files, keys and other repos.
- Sandboxing Review with Claude, planning, Ask sessions and claude -p runs: they stay on the host in v1.
- Installing or updating Apple container on a remote Mac without the user there to type its admin password, or sandboxing on Linux servers (Apple container runs only on Apple Silicon Macs).

## Acceptance criteria

- **R1** When the user turns on sandboxing on a supported Mac without Apple container, the system shall offer to install it, and after one admin prompt shall start its service, set its kernel and build the base image with no container configuration from the user.
- **R2** When the Mac is not Apple Silicon on macOS 26 or later, or setup fails, the system shall say why in plain words and keep sessions on the Host only with the user's consent, never silently.
- **R3** When sandboxing is on and a Work on This session starts for a repo not marked as needing the Mac, the system shall run its claude inside a container by default, and shall let the user pick Host for that session when it starts.
- **R4** When a session runs sandboxed, the agent shall be able to read and write the session's worktrees, commit, run the repo's Linux build and tests, push and open a pull request with gh.
- **R5** When a session runs sandboxed, the agent shall not be able to read the user's home directory, ~/.ssh, keychain, other repos' working trees or other sessions' folders.
- **R6** When a session runs sandboxed, the only credentials inside shall be Claude's own login for that user (from its sign-in inside a sandbox) or the chosen API key, the org's fine-grained GitHub token and the sandbox signing key.
- **R7** When the user sets up sandbox credentials, the system shall let them choose Claude's own sign-in inside the sandbox, completed through Anthropic's flow and never collected, stored or passed on by Gannin, or an API key kept in the keychain, and shall guide them to create a fine-grained GitHub token per org, kept in the keychain.
- **R8** When a repo is marked as needing the Mac, the system shall start its sessions on the Host and say so on the session.
- **R9** When a repo has a Containerfile for sandboxes in the harness, the system shall build an image from it on top of the base image, cache it, and rebuild it only when it or the base changes.
- **R10** When a session runs sandboxed, its state, changed signals, PR detection, Changes, transcript, Activity, questions, modes and pair review shall behave as they do on the Host.
- **R11** When a sandbox starts, the system shall apply the CPU and memory caps from Settings to it.
- **R12** When a sandboxed session's claude exits or Gannin quits, the system shall stop its container; when the session is resumed it shall start one again with the same folders; when the session is finished it shall remove it.
- **R13** When the user turns sandboxing off, the system shall remove the containers and images Gannin created, after confirming.
- **R14** When a session runs sandboxed, the system shall show its sandbox state (starting, running, stopped, failed) on the session, with the error when it failed.
- **R15** When the change ships, CLAUDE.md shall describe sandboxed sessions, their settings and stores.
- **R16** When sandboxing is on and sessions run on a Connect with server that is an Apple Silicon Mac on macOS 26 or later with container installed, the system shall run Work on This sessions there in a container on that Mac, with R4, R5, R6, R10, R11, R12 and R14 holding as they do locally.
- **R17** When the Connect with server has no container, is not a supported Mac, or its container service will not start, the system shall say which and how to fix it on that machine (offering Install, Update or Start Service where R19 can), and shall run there unsandboxed only with the user's consent.
- **R18** When a session runs sandboxed, every commit it makes shall be signed with the sandbox signing key and carry the user's git name and email; sandboxing shall not turn on until a signing key is set up, and the system shall guide the user to add its public key to GitHub as a signing key.
- **R19** When the user opens Remote machines in Settings, the system shall show the Connect with box's architecture, macOS, container version and service state; when container is missing or older than the tested version it shall offer Install or Update, run over `ssh -t` in a terminal where the user types the box's admin password, and when the service is stopped it shall offer Start Service.
- **R20** When the system checks Apple container on this Mac or a Connect with box, it shall judge it against a support policy shipped in the app (a minimum version, a tested version, and the tested version's installer with its SHA-256) and against the features Gannin relies on: below the minimum, or missing a feature, it shall not sandbox and shall say what's missing and offer Update; between the minimum and the tested version it shall run and offer Update; newer than the tested version it shall run and note that it hasn't been tested. Install and Update shall fetch the tested version's installer and check its hash before running it, and shall list the sandboxed sessions an update would stop and ask first.

## Open questions

- ~~Whether nested virtiofs mounts work on Apple container~~: they do, with `--tmpfs` over `.worktrees/` and `projects/` and binds inside (the plan's spike results).

Planned in [plans/2026-10-09-run-agent-sessions-in-apple-container.md](../plans/2026-10-09-run-agent-sessions-in-apple-container.md).
