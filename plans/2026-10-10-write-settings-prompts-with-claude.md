---
type: plan
status: in-progress
summary: "Write Settings' Claude prompts (house rules, saved prompts, drafting guidance) by talking them through with Claude in a sheet, saved only when the draft is used."
issues: [andrew-waters/gannin#145]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Write Settings' prompts with Claude

Settings has prompts for Claude that you write by hand, with no help. This adds a conversation with
Claude to write them: it asks what it needs, drafts, and refines; the draft is written to the setting
only when you say so.

## Decisions

- **Which prompts:** all of Settings' prompts without help already: House rules for Claude
  (Settings › Sandbox), each saved prompt (Settings › General) and the drafting guidance per kind
  (Settings › Harness). The harness's prompts already have Draft with Claude in their editor.
- **Where:** a sheet over the Settings window, never the Claude Code window.
- **How it runs:** `ClaudeRunner` (`claude -p` as you, `--resume` for the conversation, no tools),
  as Draft with Claude does. No new credentials; it's your Claude Code usage.
- **Starting point:** what's in the setting, to improve on; Look It Over asks for suggestions. Empty
  starts from what you say.
- **Saving:** explicit. Use This Draft writes it; Cancel (asked once anything's changed) leaves the
  setting as it was. The draft is editable, and Claude sees your edits each turn.
- **Afterwards:** the conversation is forgotten when the sheet closes.

## Tasks

- [x] `PromptWriting`: purposes, the first prompt and follow-ups, reading replies
- [x] `PromptWritingSheet` and `WriteWithClaudeButton`
- [x] House rules, saved prompts and drafting guidance get the button
- [x] Tests (`PromptWritingTests`)
- [x] CLAUDE.md
