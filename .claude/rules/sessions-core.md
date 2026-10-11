---
paths:
  - "Gannin/Sessions/**"
---
# Sessions: shared invariants

## Talking to claude
- Never drive claude's menus to answer a question. `SessionStore.answer` sends Esc, then every answer as one message.
- Always send keys through `SessionTerminal.press`: Claude Code enables the kitty keyboard protocol, so Esc is `CSI 27 u` and Shift+Tab `CSI 9;2 u`. Raw bytes are ignored.
- Never trust hook escape codes (OSC 7777) to arrive: hooks run with no terminal. State comes from the files hooks write in the session folder, which `SessionStore.poll` reads.
- Read the mode from the terminal footer (`ClaudeMode.fromFooter`) even for server sessions; that terminal is local.

## Trust boundaries
- Never fall back to accept-edits or bypass mode when auto mode is unavailable. Disable Unattended and say why.
- Never read, store or pass on claude's login. It runs signed in as the user.
- Session rules match by split command words, not parsed commands, so encoded or scripted commands get round them. Never describe them as a security boundary.
- While any session rule is on, keep the rules guarding Gannin's preferences, Application Support, `.gannin/settings*` and Claude Code's settings, so a session can't switch its own rules off.
- Keep `SessionRules.hookCommand` self-contained (inline base64 bash using sed, awk, grep, date only), so no editable script exists on the box.

## Testing
`SessionModeTests` covers mode parsing, `TranscriptReader`'s permission mode and `TerminalKeys.encode`; `SessionRulesTests` covers session rules. Nothing covers `SessionTerminal.press` or the rest of transcript parsing (Activity, cost, questions, plans); check those by hand in a running session.
