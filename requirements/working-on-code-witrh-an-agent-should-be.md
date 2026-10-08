---
type: requirement
status: in-progress
summary: "Switch a running session between Attended (claude's default mode, asking before edits and commands) and Unattended (Claude Code's auto mode) from Gannin, and see which it's in."
issues: [andrew-waters/gannin#52]
plans: [plans/2026-10-08-working-on-code-witrh-an-agent-should-be.md]
---

# Attended and unattended agent sessions

## Problem

Sessions stall at Needs you on permission prompts while nobody is watching. Today the only way to let a trusted session run on, or rein it back in for a risky step, is to click into its terminal and cycle claude's modes with Shift+Tab.

## Goal

Switch a running session between Attended (claude's default mode, asking before edits and commands) and Unattended (Claude Code's auto mode) from Gannin, and see which it's in.

## Who it's for

Engineers running Claude Code sessions from Gannin, often several at once and not watching each tab.

## Requirements

1. A control by a session's composer showing Attended or Unattended, read from the transcript's permissionMode, that switches the running session.
2. 'Leave Unattended' on the permission card (SessionQuestionCard) and as an action on its Needs you notification.
3. Leave Unattended on a waiting permission prompt approves that prompt (Yes), then switches to auto mode, and says so ('Allow this and stop asking').
4. When auto mode isn't available, Unattended is disabled with a line saying why; nothing falls back to accept edits or bypass.

## Out of scope

- Choosing a mode when a session starts (Work on This sheet, a Settings default).
- The Agents page and menu bar.
- Accept edits, bypass permissions and plan mode as choices.

## Acceptance

- A session tab's control shows Attended or Unattended, matching claude's own mode within a few seconds of it changing, including a change made in the terminal with Shift+Tab.
- Switching to Unattended puts a running session in auto mode, and back to Attended puts it in default mode, without restarting claude, here and on a Connect with server.
- Leave Unattended on a waiting permission card, or on its notification, lets that action run and the session carries on without further prompts.
- With auto mode unavailable, Unattended can't be picked and says why; the session's mode is unchanged.
- A switch that doesn't land within one cycle of modes stops and says so, leaving the session as it was.

## Open questions

- The harness has no STANDARDS.md or plans/_template.md; the plan will follow existing plans' front matter.

Planned in [plans/2026-10-08-working-on-code-witrh-an-agent-should-be.md](../plans/2026-10-08-working-on-code-witrh-an-agent-should-be.md).
