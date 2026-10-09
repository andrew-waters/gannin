---
type: plan
status: done
summary: "A Claude Code session in Gannin can be switched between Attended (claude asks before edits and commands) and Unattended (Claude Code's auto mode, no prompts), mid-session, so sessions don't stall while nobody's watching."
issues: [andrew-waters/gannin#52, andrew-waters/gannin#53, andrew-waters/gannin#54]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-08
requirement: requirements/working-on-code-witrh-an-agent-should-be.md
---

# Attended and unattended agent sessions

A Claude Code session in Gannin can be switched between Attended (claude asks before edits and commands) and Unattended (Claude Code's auto mode, no prompts), mid-session, so sessions don't stall while nobody's watching.

## Requirement

In full in [requirements/working-on-code-witrh-an-agent-should-be.md](../requirements/working-on-code-witrh-an-agent-should-be.md).

**Problem:** Sessions stall at Needs you on permission prompts while nobody is watching. Today the only way to let a trusted session run on, or rein it back in for a risky step, is to click into its terminal and cycle claude's modes with Shift+Tab.

**Goal:** Switch a running session between Attended (claude's default mode, asking before edits and commands) and Unattended (Claude Code's auto mode) from Gannin, and see which it's in.

**Who it's for:** Engineers running Claude Code sessions from Gannin, often several at once and not watching each tab.

**Scope:**

1. A control by a session's composer showing Attended or Unattended, read from the transcript's permissionMode, that switches the running session.
2. 'Leave Unattended' on the permission card (SessionQuestionCard) and as an action on its Needs you notification.
3. Leave Unattended on a waiting permission prompt approves that prompt (Yes), then switches to auto mode, and says so ('Allow this and stop asking').
4. When auto mode isn't available, Unattended is disabled with a line saying why; nothing falls back to accept edits or bypass.

**Out of scope:**

- Choosing a mode when a session starts (Work on This sheet, a Settings default).
- The Agents page and menu bar.
- Accept edits, bypass permissions and plan mode as choices.

**Done when:**

- A session tab's control shows Attended or Unattended, matching claude's own mode within a few seconds of it changing, including a change made in the terminal with Shift+Tab.
- Switching to Unattended puts a running session in auto mode, and back to Attended puts it in default mode, without restarting claude, here and on a Connect with server.
- Leave Unattended on a waiting permission card, or on its notification, lets that action run and the session carries on without further prompts.
- With auto mode unavailable, Unattended can't be picked and says why; the session's mode is unchanged.
- A switch that doesn't land within one cycle of modes stops and says so, leaving the session as it was.

## Scouting

- **Area** `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L22-L29`: claude is started with --model and, for reviewers, --disallowedTools; no --permission-mode, so sessions start in the user's own default mode.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1152`: SessionStore.press sends keys to claude encoded for the kitty protocol; Shift+Tab, which cycles claude's modes, could be sent the same way.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L226-L229`: Each session has its own --settings file with hooks; a permissions.defaultMode could go there too. The Notification hook already marks permission prompts as Needs you.
- **Risk** `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift`: Gannin doesn't track which mode claude is in; the transcript's user records carry permissionMode, which TranscriptReader could read to show it.
- **Risk** `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1152`: Shift+Tab cycles claude's modes in an order that depends on which are enabled, so switching by keys must press, read permissionMode back from the transcript, and stop on the target; the transcript only updates on the next record.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionComposer.swift#L311-L360`: The permission card reads the prompt's own choices off the terminal (permissionChoices) and answers with sendKeys (Esc for Deny); Leave Unattended would sit beside these.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L750-L760`: Needs you notifications carry up to four quick replies as UNNotificationActions whose identifier is 'keys:' plus the keys to send; Leave Unattended can be one, if it fits within four.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1146-L1165`: press encodes keys for the kitty protocol (Esc as CSI 27 u); Shift+Tab would need its own encoding (CSI 9;2 u) as it isn't a single scalar.
- **Risk** `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L22-L29`: Auto mode isn't always in claude's Shift+Tab cycle (it depends on the account, the Claude Code version and settings), so cycling may never reach it; Gannin must stop after a full cycle and say why.
- **Risk** `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift`: The transcript's permissionMode is only written with the next record, so after a Shift+Tab on an idle session it stays stale; it can't confirm a switch on its own.
- **Pattern** `andrew-waters/gannin` `Gannin/Sessions/SessionActions.swift#L86-L106`: permissionChoices reads claude's menu off the terminal's last screen lines (screenLines). claude's footer names the mode the same way ('auto mode on', 'accept edits on', 'plan mode on', nothing for default), and the terminal is local even for ssh sessions, so the mode can be read at once there too. The footer wording is claude's and may change between versions.

## Breakdown

1. [andrew-waters/gannin#53](https://github.com/andrew-waters/gannin/issues/53)
2. [andrew-waters/gannin#54](https://github.com/andrew-waters/gannin/issues/54)

## Decisions

- What do interactive and passthrough mean? **Claude's permission mode: interactive asks before edits and commands, passthrough runs without asking, switched mid-session.**
- What's the pain that makes switching worth building? **Sessions get stuck on permission prompts while nobody's watching; people want to let a trusted session run free and rein it in for risky steps.**
- Which Claude Code mode is passthrough? **Auto mode: no prompts, with Claude Code's safety check still blocking risky actions.**
- What are the two modes called? **Attended and Unattended (from the room), naming whether someone is watching; Claude Code's own mode names appear only in help text.**
- What's the smallest version worth shipping? **The switch by the composer, plus Leave Unattended on the permission card and its notification. Starting modes and the Agents page come later.**
- What happens to a waiting prompt on Leave Unattended? **It's approved, then the session switches to auto mode.**
- What if auto mode isn't available? **Say so and stay Attended; no fallback to accept edits or bypass. Revisited by the room and kept.**
- Is the requirement right? **Yes.**
- Is the breakdown right? **Merge showing and switching the mode into one piece; Leave Unattended from Needs you stays its own.**
- Is the two-piece breakdown right? **Yes, agreed.**

## From the room

- Should we call this attended and unattended (refine)
- We want to revisit "What if auto mode isn't available?". We said "Say so and stay Attended; no fallback to accept edits or bypass.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)

## Open questions

- The harness has no STANDARDS.md or plans/_template.md; the plan will follow existing plans' front matter.
