---
paths:
  - "Gannin/Sessions/**"
---
# Sessions: shared invariants

## Talking to claude
- Never drive claude's menus to answer a question. `SessionStore.answer` sends Esc, then every answer as one message.
- Always send keys through `SessionTerminal.press`: Claude Code enables the kitty keyboard protocol, so Esc is `CSI 27 u` and Shift+Tab `CSI 9;2 u`. Raw bytes are ignored.
- Never trust hook escape codes (OSC 7777) to arrive: hooks run with no terminal. State comes from the files hooks write in the session folder, which `HookFileWatcher` reports changes to and `SessionStore.refreshLocal` reads.
- Never watch only the session folder: hooks write with `>`, which rewrites an existing file in place and raises no folder event. `HookFileWatcher` watches each file too.
- Never read hook files or scan the terminal screen on a timer on the main actor. Reads run detached; the screen is scanned only after it changes (`OutputReportingTerminalView`), once a second at most. `SessionStore.poll` stays as the safety net, and as the only reader of server sessions and of sandboxed ones, whose mounted folder isn't known to raise file events.
- Read the mode from the terminal footer (`ClaudeMode.fromFooter`) even for server sessions; that terminal is local.

## Trust boundaries
- Gannin's own writes to GitHub are confirmed first; a session's claude runs `gh` as the user and isn't. `SessionPrompts.feedback` asks it to reply on review threads it fixed (Settings › General › Agent, on by default), so keep that prompt to short replies on addressed threads, and the hourly comment limit in session rules counting `*/replies` writes.
- Never fall back to accept-edits or bypass mode when auto mode is unavailable. Disable Unattended and say why.
- Never read, store or pass on claude's login. It runs signed in as the user.
- Session rules match by split command words, not parsed commands, so encoded or scripted commands get round them. Never describe them as a security boundary.
- While any session rule is on, keep the rules guarding Gannin's preferences, Application Support, `.gannin/settings*` and Claude Code's settings, so a session can't switch its own rules off.
- Keep `SessionRules.hookCommand` self-contained (inline base64 bash using sed, awk, grep, date only), so no editable script exists on the box.

## Attachments (`SessionAttachments.swift`)
- Copy attachments only into `.gannin/attachments/` in the session's folder on its box: `.gannin/` is kept out of git in harness and plain worktrees alike, so they're never committed, and a sandbox mounts the issue's folder writable.
- Name them through `attachmentNames` with every name already there: names go into shell scripts and prompts, and share the folder with a quick change's screenshots, so a clash would overwrite one.
- Mark one sent only when `submit(_:withAttachmentsTo:)` has put a prompt naming it in the terminal.

## Testing
`SessionModeTests` covers mode parsing, `TranscriptReader`'s permission mode and `TerminalKeys.encode`; `SessionRulesTests` covers session rules; `SessionAttachmentsTests` covers attachment names, paths, the upload script and the prompt. Nothing covers the copy to a box, `SessionTerminal.press` or the rest of transcript parsing (Activity, cost, questions, plans); check those by hand in a running session.
