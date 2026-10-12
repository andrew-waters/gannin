---
title: Session rules
description: Guardrails that block or question the commands Claude runs in your sessions.
sidebar:
  order: 4
---

Session rules are your own checks on the commands Claude runs. They're set in Settings › General › Session rules, are kept on this Mac, and are off until you tick one.

They apply to sessions you start or resume after setting them, on this Mac, a server or a sandbox, Attended or Unattended.

## Ready-made rules

- No force push
- Push only to the session's branch (Claude has to name it, as `git push origin HEAD:<branch>`)
- No branch or tag deletes
- No gh release writes
- Limit PR comments and reviews, with a stepper for how many an hour per session

## Your own rules

Add Rule gives a rule a Name, a Pattern and a choice for When it matches:

- **Block**: the command doesn't run. Claude is told which rule stopped it so it can carry on another way.
- **Ask me**: the session goes to Needs you, even in Unattended, and you allow or deny.

The pattern is an extended regular expression (as `grep -E` reads it) matched against the whole command; plain words work as they are. An invalid pattern blocks every command until you fix it, and the pane says so.

A blocked command shows in the session's Activity with the rule's name.

## Protecting the rules themselves

While any rule is on, a session also can't change Gannin's settings, its own settings file or Claude Code's, or set git config or a git alias that changes what push does. Reading them is fine.

## What they can't stop

Rules match the words of a command as written. They don't understand it. That stops mistakes and casual prompt injection, but an encoded or scripted command can get round them. Treat them as a guardrail, not a security boundary: protect shared branches on GitHub too, and use a [sandbox](/docs/sessions/sandboxes/) when you need isolation.
