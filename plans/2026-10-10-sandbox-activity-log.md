---
type: plan
status: In review
summary: A sandbox's container now runs a follower of an activity log its sessions write (events and tool names only, tokens redacted), so container logs and Orchard show whether it's working, waiting, stuck or finished.
issues: [andrew-waters/gannin#152]
domains: [sandbox, sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Show what's happening inside a sandboxed session

## Context

Answering the issue's first question: sandboxed sessions produced no logs anywhere outside Gannin's
terminal. It wasn't a bug in delivery, it was never captured. The container's main process was
`sh -c "trap 'exit 0' TERM; sleep infinity & wait"`, and Claude Code ran through
`container exec -it` into the session's terminal tab. `container logs` (and so Orchard, which lists
sandboxes by their `com.orchard.sandbox` labels) only shows the main process's output, which was
nothing. The hooks' state files and the transcript in `claude-home` exist, but nothing outside Gannin
reads them.

The silence wasn't a recorded decision. Nothing in the plan or requirement for sandboxes
(andrew-waters/gannin#8) mentions logs, so this plan writes one down.

## Decisions

- **Where:** an activity log, `sandbox.log` in the issue's session folder on the Mac (mounted inside
  at its real path, shared by the issue's session and its helpers), which the container's main
  process follows with `tail -n 200 -F`. So `container logs <name>` and `-f` show it, Orchard shows it,
  and the file outlasts the container. Gannin's own UI is unchanged: its terminal and Activity pane
  already show everything.
- **What's withheld (security):** the log has events and tool names only: inner.sh's own steps and
  failures, Claude Code starting, a prompt arriving (not its text), each tool used by name, a tool
  failing (not its error), waiting for you, a turn ending, exiting. Never a command, prompt, file's
  contents, tool output or error text, since any of those can hold a token or a secret file's
  contents. Each line is also stripped of control characters, capped at 500 characters, and redacted
  for the sandbox's own `GH_TOKEN` and `ANTHROPIC_API_KEY` values and for token shapes (`ghp_` and
  kin, `github_pat_`, `sk-ant-`, private key headers), as a second line of defence.
- **How:** `inner.sh` writes `SandboxLaunch.activityScript` to `/run/gannin-activity` (outside every
  mount, as the signing key is) and exports the log's path and a label (`#152`, or `#152 review` for a
  helper). A sandboxed session's settings (`SessionScript.settings(sandboxed:)`) add a hook on
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUseFailure, Notification (permission prompts and
  dialogs), Stop and SessionEnd that calls it. Sessions on the Mac get no extra hooks.
- **Not done:** no rotation (lines are short, and the file goes with the session's folder); a
  sandbox already running when this ships keeps `sleep infinity` until it next starts.

## Tasks

- [x] Container's main process follows `sandbox.log`; `inner.sh` gets its path (`SandboxLaunch.hostSteps`)
- [x] `activityScript`, written and used by `inner.sh`, with redaction
- [x] Activity hooks for sandboxed sessions' settings, here and on a server
- [x] Tests: the follower, the hooks only when sandboxed, and the script's redaction
- [x] Docs: Sessions › Sandboxes, "Seeing what a sandbox is doing"; CLAUDE.md; CHANGELOG
- [ ] Built and tested on a Mac (`xcodebuild test`), and checked with a real sandbox's `container logs`
