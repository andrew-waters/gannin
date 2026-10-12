---
title: Attended and Unattended
description: Whether Claude asks before edits and commands, and how to switch.
sidebar:
  order: 2
---

Every session is Attended or Unattended.

- **Attended**: Claude asks before edits and commands. This is Claude Code's default mode.
- **Unattended**: Claude carries on without asking. This is Claude Code's auto mode, so its own safety check still blocks risky actions.

Claude Code's other modes (Accept Edits, Plan Mode, Bypass Permissions) are only shown, by Claude's names, if a session is in one. Pick Attended or Unattended to leave it. Gannin never falls back to Accept Edits or Bypass.

## Switching

Use the Attended or Unattended menu in the composer under the terminal. Gannin switches by pressing Claude's own mode shortcut and reads the terminal's footer to check it landed. If it doesn't land, the session stays where it was and a line says so.

## When Unattended isn't available

Auto mode isn't available in every Claude Code setup. If a session can't reach it, Gannin remembers that for that machine (this Mac, the server, or the sandbox) until Claude next starts there, and the composer shows "Auto mode isn't available in this Claude Code". Unattended stays disabled.

## Leave Unattended

On a permission card, **Leave Unattended** means allow this one and stop asking: Claude is told yes, then the session switches to Unattended once the prompt has closed. It's also the last quick reply on a Needs you notification. It isn't offered if auto mode is unavailable or the session is already Unattended.

## Limits

Unattended doesn't make a session safe. For long unattended work, consider a [sandbox](/docs/sessions/sandboxes/) and [session rules](/docs/agents/session-rules/). [Routines](/docs/agents/routines/) always run Unattended.
