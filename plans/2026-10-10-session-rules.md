---
type: plan
status: In progress
summary: Session rules, set in Settings › General › Session rules, enforced by a PreToolUse hook Gannin writes into every session's settings on each start and resume, so a session can't run what they block whatever Claude decides.
issues: [andrew-waters/gannin#129]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Session rules

## Context

House rules and the brief ask Claude to behave; an injected prompt or a confused turn can ignore
them, and a sandbox limits what a session can reach, not what it does with it. The issue asks for
rules set by the user alone, off by default, checked outside Claude on every action, with a few
ready-made ones (no force push, push only to the session's branch, no branch or tag deletes, no
`gh release` writes, at most N PR comments or reviews an hour), custom block or ask rules, shown in
Activity with the rule's name, and out of the session's reach.

## Decisions

- **Enforced by a Claude Code `PreToolUse` hook**, not by asking. Gannin already writes every
  session's `--settings` from scratch on each start and resume (`SessionStore.open`), here, on a
  server and in a sandbox alike, so the rules ride along with no new moving parts. Claude Code
  snapshots hooks when it starts, so editing a settings file mid-session changes nothing, and a
  hook's `deny` wins over any `allow` claude or the user's own settings have.
- **The whole check is inline in the hook's command** (bash, sed, awk, grep, date only, which a
  Mac, a server and the sandbox image all have), with no script file for a session to edit. The
  one piece of state, the comment count, is a file in the session's folder.
- **Blocked means `permissionDecision: deny`** with a reason naming the rule and saying it can't
  be changed from the session, so Claude carries on another way. **Ask** is `permissionDecision:
  ask`: a permission prompt even in auto mode, which the existing `Notification` hook turns into
  Needs you, and the question card's Allow or Deny resolves.
- **Activity shows it from the transcript**: a tool result that is the hook's denial marks the
  event "blocked by <rule>". No extra file to poll.
- **Kept out of reach**: while any rule is on, a built-in guard blocks Bash commands and edits
  that touch Gannin's preferences or Application Support (`dev.andon.gannin`), a session's
  `.gannin/settings*.json`, Claude Code's own settings files or `disableAllHooks`.
- **Stored on this Mac** as JSON in `UserDefaults` (`sessionRules`), the user's own setting like
  the rest of Settings › General; never in the harness, where a session could commit it.

### Limits, said plainly

Matching is on the command's words, segment by segment. It stops the ordinary ways of doing each
thing, mistakes and casual injection, not a determined attacker: `bash -c "$(printf %s <base64> | base64 -d)"`, a
script written to disk and run, or an alias would get round it. Branch protection on GitHub is the
real wall for a shared branch. A wrapper for `git` and `gh` outside the session's reach (and
server-side checks for MCP GitHub tools beyond comments) is the next step, left for a follow-up.

## Tasks

- [x] `SessionRules` (`Sessions/SessionRules.swift`): the ready-made rules, custom rules, stored
      on this Mac, and the hook command built from them.
- [x] `SessionScript.settings` adds the rules' `PreToolUse` group when any rule is on, for the
      session's branch.
- [x] The transcript marks a tool call the rules blocked; Activity shows the rule's name.
- [x] Settings › General › Session rules (`SessionRulesSection`): the ready-made rules to tick,
      the comment limit, and custom rules (name, pattern, Block or Ask me).
- [x] Tests: the hook run in bash against each rule, the count limit, ask, the guard, and no rules
      meaning no hook.
- [x] Pair review round 1: quoted and tabbed commands, flags in any order, gh's flags before
      its verb, `-c` and `git config` that change push, `update-ref -d`, pushes naming the
      branch, GitHub MCP writes only, custom rules before the count, invalid patterns and a
      broken hook failing closed, reads of the guarded files allowed.
- [x] Docs: Settings › General's page, the sessions guide, CHANGELOG.
- [ ] Try each rule in an Unattended session on this Mac, a server and a sandbox (needs a Mac).
