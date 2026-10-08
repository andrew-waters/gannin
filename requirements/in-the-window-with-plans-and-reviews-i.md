---
type: requirement
status: done
summary: "Start an open-ended Claude Code conversation about anything from the Claude Code window, beside plans and reviews, with the harness's skills and MCP, the code clones and Gannin's org data within reach, and grab what it produces without leaving Gannin."
issues: [andrew-waters/gannin#55]
plans: [plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md]
---

# Ad hoc sessions in the Claude Code window

## Problem

Every Claude Code session in Gannin starts from something: an issue (Work on This), a PR (Review with Claude) or a topic (planning). Ask is a one-shot `claude -p` over Gannin's org data. Ad hoc work that isn't tied to any of that, such as asking how many users logged in today (which may need the code to find where that's stored), or pulling a CSV from the database through a skill or MCP, happens outside Gannin in a separate Claude Code terminal, and its files are fished out of Finder.

## Goal

Start an open-ended Claude Code conversation about anything from the Claude Code window, beside plans and reviews, with the harness's skills and MCP, the code clones and Gannin's org data within reach, and grab what it produces without leaving Gannin.

## Who it's for

Anyone on the team using Gannin who has a one-off question or task for Claude that isn't about one issue, PR or plan: engineers, leads, and people pulling data for others (the facilitator pulling CSVs from the database today).

## Requirements

1. Ask's place is taken by general-purpose ad hoc sessions: an interactive Claude Code session in a tab of the Claude Code window, with the harness's skills and MCP servers, not tied to an issue, PR or plan and not limited to org, code or harness questions (closes andrew-waters/gannin#6).
2. Show every file the session writes in the session's own view, each one clickable to open, reveal, drag out or save elsewhere, without going to Finder.
3. Each research session runs in its own folder under the window's project's harness (`.worktrees/ask-<slug>/`), so the harness's CLAUDE.md, skills and MCP config apply and the files it writes stay out of the team's documents.
4. Files a research session writes stay in its folder on this Mac by default, listed in the UI to open, reveal, drag out or save elsewhere.
5. Committing a research file to the harness is a very explicit act: one file at a time, from its own clearly labelled action (never the default click, a drag or Return), through a sheet that names the file, shows its contents or a preview, says where it'll go and warns that it may hold sensitive data, with a deliberate confirm. Claude in the session can never commit one, and nothing is committed automatically.
6. A committed research file goes in `research/<date>-<slug>/` in the project's harness, one folder per conversation, with a short README naming the conversation's title and question; Research is listed under Harness like Plans and Findings.
7. Research conversations are kept until deleted: listed under Agents in an Ask group with their title and files, reopened by resuming the conversation (`claude --resume`), and deleted (folder and files) only after a confirmation.
8. A session starts with Gannin's org data (Ask's OrgContext JSON: workload, issues, delivery, harness, time off) written into its folder and named in its brief as available, not as the subject; the code clones in the harness's `projects/` are reachable when a question needs them.
9. Starting one: New Ask from the Claude Code window's + menu, the Agents page and the command palette opens a box for the first message, with the harness's saved prompts and skills to pick beside it (the team's prompts gain an ad hoc use); Return starts it. Its title comes from the first message and can be renamed. Several can be open at once, each in its own tab.

## Out of scope

- Keeping the one-shot `claude -p` Ask beside it.
- Committing anything automatically, or recording an ad hoc session in the harness (no `sessions/` commit as Work on This does).
- Sharing a live session with others or syncing it between Macs.
- Gannin managing database credentials or MCP servers: they're the user's and the harness's Claude Code config.
- Running ad hoc sessions on a Connect with server (a later issue).

## Acceptance criteria

- **R1** When you pick New Ask from the Claude Code window's + menu, the Agents page or the command palette, the system shall offer a box for a first message with the project's saved prompts and skills to pick, and start an interactive Claude Code session in a new tab when you press Return, with no issue, PR or plan chosen.
- **R2** When an ad hoc session starts, the system shall run it in its own folder in the window's project's harness checkout (`.worktrees/ask-<slug>/`), so the harness's CLAUDE.md, skills and MCP servers apply and the code clones in `projects/` are reachable.
- **R3** When an ad hoc session starts, the system shall write Gannin's org data (workload, issues, delivery, harness documents, time off) into its folder and tell Claude it's there to use if a question needs it, without framing the session around it.
- **R4** While an ad hoc session is open, the system shall list every file written in its folder, whether by Claude's edits, a script or an MCP tool, within seconds of it appearing, each with its name, size and time.
- **R5** When you click a listed file, the system shall open it; its menu and drag shall let you open it with, reveal it, save a copy elsewhere or drop it into another app, without going through Finder.
- **R6** The system shall never commit, push or copy into the harness a file an ad hoc session wrote unless you choose Commit to Harness on that one file and confirm a sheet that previews it, says it'll go to `research/<date>-<slug>/` with a short README, and warns it may hold sensitive data; the confirm shall not be the default button, and Claude in the session shall have no way to trigger it.
- **R7** When a research file has been committed, the system shall list `research/` under Harness in the sidebar like Plans and Findings.
- **R8** When Gannin is quit and reopened, the system shall still list ad hoc sessions under Agents › Ask with their titles and files, and reopening one shall resume the conversation.
- **R9** When you delete an ad hoc session and confirm, the system shall end Claude, remove its folder and every file in it, and stop listing it.
- **R10** When ad hoc sessions ship, the system shall no longer offer one-shot Ask; its sidebar row and palette entry shall start an ad hoc session instead, and CLAUDE.md shall describe the new behaviour (closing andrew-waters/gannin#6).
- **R11** When Settings › General › Connect with names a server, the system shall still run ad hoc sessions on this Mac, so their files can be grabbed directly.

Planned in [plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md](../plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md).
