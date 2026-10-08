# andrew-waters/gannin#58: Ask tab: Files pane listing what the session wrote

https://github.com/andrew-waters/gannin/issues/58

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 8 Oct 2026
- Parent: #55 Ad hoc sessions in the Claude Code window (https://github.com/andrew-waters/gannin/issues/55)

## Description

Beside the terminal, in place of Changes: files under `files/` and the rest of the folder (not `.gannin/` or `context/`), plus `SessionTranscript.filesEdited` paths outside it, with name, size and time. Refresh on `changed` and a two-second folder poll while the tab is open (MCP writes fire no hook). Click opens; drag is a file promise; context menu: Open With, Reveal in Finder, Save a Copy, Copy. Commit to Harness sits apart at the end (wired in the commit task).

**Checked by:** a file written by Write, by a Bash script and by an MCP tool each appears within a few seconds; drag into Mail attaches it; Save a Copy writes it elsewhere.

Satisfies:

- **R4**: While an ad hoc session is open, the system shall list every file written in its folder, whether by Claude's edits, a script or an MCP tool, within seconds of it appearing, each with its name, size and time.
- **R5**: When you click a listed file, the system shall open it; its menu and drag shall let you open it with, reveal it, save a copy elsewhere or drop it into another app, without going through Finder.

Planned in [Ad hoc sessions in the Claude Code window](https://github.com/andrew-waters/gannin/blob/HEAD/plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md).

## Plans and requirements

From the team's harness repo, andrew-waters/gannin, which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.

### Ad hoc sessions in the Claude Code window

Plan, in progress, about this issue: `plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-08-in-the-window-with-plans-and-reviews-i.md)

General-purpose Claude Code conversations in the same window as plans and reviews, about anything: the code, the harness, the business's data (how many users logged in today) or nothing in particular. Gannin's org data is on hand but isn't the frame. Files it writes are listed to grab, and committed only very explicitly.

# Ad hoc sessions in the Claude Code window

General-purpose Claude Code conversations in the same window as plans and reviews, about anything: the code, the harness, the business's data (how many users logged in today) or nothing in particular. Gannin's org data is on hand but isn't the frame. Files it writes are listed to grab, and committed only very explicitly.

## Context

- Also looked at: similar to claude projects, i want to have ad hoc conversations - doing things like runngin queries in the database via skills and mcp, and there may be artefacts saved. I've done this for grabbing csvs from the db etc

## Requirement

In full in [requirements/in-the-window-with-plans-and-reviews-i.md](../requirements/in-the-window-with-plans-and-reviews-i.md).

**Problem:** Every Claude Code session in Gannin starts from something: an issue (Work on This), a PR (Review with Claude) or a topic (planning). Ask is a one-shot `claude -p` over Gannin's org data. Ad hoc work that isn't tied to any of that, such as asking how many users logged in today (which may need the code to find where that's stored), or pulling a CSV from the database through a skill or MCP, happens outside Gannin in a separate Claude Code terminal, and its files are fished out of Finder.

**Goal:** Start an open-ended Claude Code conversation about anything from the Claude Code window, beside plans and reviews, with the harness's skills and MCP, the code clones and Gannin's org data within reach, and grab what it produces without leaving Gannin.

**Who it's for:** Anyone on the team using Gannin who has a one-off question or task for Claude that isn't about one issue, PR or plan: engineers, leads, and people pulling data for others (the facilitator pulling CSVs from the database today).

**Scope:**

1. Ask's place is taken by general-purpose ad hoc sessions: an interactive Claude Code session in a tab of the Claude Code window, with the harness's skills and MCP servers, not tied to an issue, PR or plan and not limited to org, code or harness questions (closes andrew-waters/gannin#6).
2. Show every file the session writes in the session's own view, each one clickable to open, reveal, drag out or save elsewhere, without going to Finder.
3. Each research session runs in its own folder under the window's project's harness (`.worktrees/ask-<slug>/`), so the harness's CLAUDE.md, skills and MCP config apply and the files it writes stay out of the team's documents.
4. Files a research session writes stay in its folder on this Mac by default, listed in the UI to open, reveal, drag out or save elsewhere.
5. Committing a research file to the harness is a very explicit act: one file at a time, from its own clearly labelled action (never the default click, a drag or Return), through a sheet that names the file, shows its contents or a preview, says where it'll go and warns that it may hold sensitive data, with a deliberate confirm. Claude in the session can never commit one, and nothing is committed automatically.
6. A committed research file goes in `research/<date>-<slug>/` in the project's harness, one folder per conversation, with a short README naming the conversation's title and question; Research is listed under Harness like Plans and Findings.
7. Research conversations are kept until deleted: listed under Agents in an Ask group with their title and files, reopened by resuming the conversation (`claude --resume`), and deleted (folder and files) only after a confirmation.
8. A session starts with Gannin's org data (Ask's OrgContext JSON: workload, issues, delivery, harness, time off) written into its folder and named in its brief as available, not as the subject; the code clones in the harness's `projects/` are reachable when a question needs them.
9. Starting one: New Ask from the Claude Code window's + menu, the Agents page and the command palette opens a box for the first message, with the harness's saved prompts and skills to pick beside it (the team's prompts gain an ad hoc use); Return starts it. Its title comes from the first message and can be renamed. Several can be open at once, each in its own tab.

**Out of scope:**

- Keeping the one-shot `claude -p` Ask beside it.
- Committing anything automatically, or recording an ad hoc session in the harness (no `sessions/` commit as Work on This does).
- Sharing a live session with others or syncing it between Macs.
- Gannin managing database credentials or MCP servers: they're the user's and the harness's Claude Code config.
- Running ad hoc sessions on a Connect with server (a later issue).

**Acceptance criteria:**

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

**Decisions:**

- Should the research screen surface files the session writes? **Yes: list them in the UI so they can be opened or grabbed with a click, no Finder needed.**
- How should this relate to Ask (andrew-waters/gannin#6)? **It replaces Ask; #6 is closed by this work.**
- Where should an ad hoc research session run? **Its own folder in the project's harness, `.worktrees/ask-<slug>/`.**
- What should happen to the files a research session writes? **Stay local by default; a file can be committed to the harness on request, but the action has to be very explicit: one file, its own action, a preview and sensitive-data warning, then a deliberate confirm. (Revisited twice; first said local only, never committed.)**
- When a research file is explicitly committed, where should it go in the harness? **`research/<date>-<slug>/`, one folder per conversation, with a short README.**
- How long should a research conversation live? **Kept until you delete it; reopening resumes it; Delete removes its folder and files, confirmed first.**
- What should a research session know when it starts? **Org data as files on hand, but it's not a direct replacement for Ask: sessions are ad hoc and often unrelated to the code or harness (for example how many users logged in today), so the data is available, not the frame.**
- How should you start an ad hoc session? **Type a first message and go, with the team's saved prompts and skills to pick beside it.**
- Are the requirements (R1-R11) right? **Yes, with ad hoc sessions on this Mac only for now; server support is later.**

## Design

Ad hoc sessions are a fourth kind of Claude Code session beside Code, Review and Plan, built the way planning sessions are.

**Name.** They're called Ask throughout: tabs read Ask, menus New Ask, the Agents group Ask. Committed files still go in `research/`.

**Model.** `CodeSession` gains an optional `adhoc: AdhocInfo` (title, slug, created from the first message), decoded leniently. `SessionStore.startAdhoc(org:message:harness:choice:)` mirrors `startPlanning`: a synthetic `IssueReference` (`ask-<uuid>`, number 0), branch `ask-<slug>`, `connect: nil` so it always runs on this Mac, `launchInstructions(use: .adhoc)` for the prompts and skills picked, and the first message as its prompt. claude runs in the harness root as planning does, so the harness's CLAUDE.md, MCP config, skills and `projects/` clones apply.

**Folder.** `.worktrees/ask-<slug>/` holds `.gannin/` (brief, settings, hooks), `context/` (Ask's `OrgContext` JSON, written at start and refreshed on resume) and `files/`, where the brief tells claude to save anything it produces. The brief says the org data is there if a question needs it, and that the session is about whatever was asked.

**Starting.** New Ask in the Claude Code window's + menu, Agents and the palette opens a draft tab (as New Plan does) with a first-message box and the team's prompts and skills (`PromptUse.adhoc`); Return starts it. The Ask sidebar row and its palette entry open the same, so `WorkloadTab.ask` keeps its raw value. `AskOrgPage` and one-shot `AskConversations` go; `OrgContext` stays.

**The tab.** A terminal beside a Files pane in place of Changes: every file under `files/` (and anything else in the folder that isn't Gannin's), plus paths outside it from the transcript's `filesEdited`, with name, size and time. Refreshed on the `changed` signal and by a light poll of the folder (MCP tools don't fire hooks). Click opens; drag is a file promise; a context menu has Open With, Reveal, Save a Copy, Copy, and, set apart, Commit to Harness.

**Commit.** One file at a time from that item only (no shortcut, not the default action). A sheet shows a preview (text or Quick Look), the destination `research/<date>-<slug>/<name>` with a README (title and first message), a warning that exports may hold customer data, and a confirm that isn't the default button. It goes through `HarnessStore.commit`, which gains binary file support and a size limit. Nothing in the session's settings lets claude commit it: the folder is kept out of git as `.worktrees/` already is.

**Lists.** Agents gets an Ask group (title, when, file count) with Open (resume), Delete (confirmed: `finish`, removing the folder and files). `HarnessKind.research` lists `research/` under Harness, the folder's README as its document.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/AskOrg.swift`: Ask today: OrgContext.files writes org JSON, AskOrgPage runs ClaudeRunner.ask (claude -p, read-only tools) with resume. OrgContext is reused; the page and AskConversations go.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L11-L90`: CodeSession: add an optional `adhoc` (title, slug) decoded with decodeIfPresent so older sessions load; `connect` set nil so it always runs here (R11). `archivedAt` and `finish` already cover delete.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/PlanningSession.swift#L88-L120`: startPlanning is the model to copy: a CodeSession with a synthetic IssueReference (`plan-<uuid>`, number 0), a role, a first prompt, launchInstructions for the prompts and skills picked, a brief, add then reveal. Ad hoc gets the same with an `adhoc` info struct in place of `planning`.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L185-L215`: TabKind names a tab by its session's kind (Plan, Review, Code, helper role); add an Ask kind. The + menu and Agents' New Plan (`showNewPlan`, `PlanningDraft`) show how a draft tab precedes a session, for the first-message box.
- `andrew-waters/gannin` `Gannin/Harness/HarnessPrompts.swift#L6-L10`: PromptUse is work, review, planning, session: add an ad hoc use so the team's prompts can be offered when starting one (SessionLaunch's PromptPickerSections).
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L224`: A PostToolUse hook writes `changed` after Edit, Write and Bash, which SessionStore polls; MCP tools don't trigger it, so the files list needs its own look at the folder (a poll or a file system watch).
- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L118`: `filesEdited` collects Write and Edit paths from the transcript: catches files claude writes outside its folder, to list as well.

**Risks:**

- `andrew-waters/gannin` `Gannin/Harness/HarnessWrites.swift#L5-L8`: HarnessChange carries text files only (`[String: String?]`, base64 of UTF-8). Committing a binary export (xlsx, png) needs a Data variant, and createCommitOnBranch has payload limits, so big exports must be refused with a clear reason.
- `andrew-waters/gannin` `Gannin/Sessions/SessionScript.swift#L403-L432`: Planning runs claude in the harness root with its folder under `.worktrees/<branch>/`, so the harness's CLAUDE.md, MCP config and projects/ apply. claude can still write anywhere (Downloads, /tmp); the brief must point it at the session's files folder, and the list shows transcript-known writes elsewhere too.
- `andrew-waters/gannin` `Gannin/Views/MainView.swift#L53`: `WorkloadTab.ask` is saved in windows' scene storage; keep the raw value and repoint the row rather than removing the case, so restored windows don't break.

**Decisions:**

- What should these sessions be called in the app? **Ask: tab kind, sidebar row, New Ask in menus and the Agents group. Committed files still go in research/.**
- Is the design right? **Yes, as on screen, binary commits included.**

## Tasks

1. [andrew-waters/gannin#56](https://github.com/andrew-waters/gannin/issues/56) Ask sessions: model, folder and start (satisfies R2, R3, R11)
2. [andrew-waters/gannin#57](https://github.com/andrew-waters/gannin/issues/57) New Ask: first-message tab and entry points, replacing one-shot Ask (satisfies R1, R10)
3. [andrew-waters/gannin#58](https://github.com/andrew-waters/gannin/issues/58) Ask tab: Files pane listing what the session wrote (satisfies R4, R5)
4. [andrew-waters/gannin#59](https://github.com/andrew-waters/gannin/issues/59) Commit to Harness: explicit one-file commit, binary files included (satisfies R6)
5. [andrew-waters/gannin#60](https://github.com/andrew-waters/gannin/issues/60) Harness › Research lists committed research (satisfies R7)
6. [andrew-waters/gannin#61](https://github.com/andrew-waters/gannin/issues/61) Agents › Ask: keep, resume and delete Ask sessions (satisfies R8, R9)

**Decisions:**

- Are the tasks right? **Yes, with binary commit support and the commit sheet merged into one task (six in all).**

## From the room

- The UI for this new screen should show me any files written - is that possible - so I can click to grab them without switching to the finder etc (context)
- We want to revisit "What should happen to the files a research session writes?". We said "Local only, never committed: they may hold database exports with sensitive data.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- We want to revisit "What should happen to the files a research session writes?". We said "Stay local by default; a file can be committed to the harness on request, picked and confirmed first, since a DB export may hold customer data. (Revisited: was local only, never committed.)". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- A, but the action has to be very very explicit to commit (requirements)
- A, but I don't want you tio think of this as a direct replacement for ask - it might not be code related, I might using it to do something unrelated to the data in harness or the code - I might be asking how many users logged intoday 0 code might be necessary to understand where thats stored. It's ad hoc, and not alway related (requirements)
- A and C (requirements)

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/58-ask-tab-files-pane-listing-what-the/`: give each repo it touches a worktree there, on the branch `58-ask-tab-files-pane-listing-what-the`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/58-ask-tab-files-pane-listing-what-the/<name>" -b 58-ask-tab-files-pane-listing-what-the origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/58-ask-tab-files-pane-listing-what-the/gannin" -b 58-ask-tab-files-pane-listing-what-the origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#58" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#58]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/58-ask-tab-files-pane-listing-what-the/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
