# User-visible material from CLAUDE.md: shell, git, palette, fetching, drawers, Inbox

Plain-language notes cut from CLAUDE.md. Check each against docs-site before adding.

## App shell and sidebar
- Settings panes: General (Appearance: System, Light, Dark; Agent), Sync, Sandbox, Storage. Storage shows each cache's size with Clear, Delete Your Data, Erase Everything and Sign Out. Already in settings/app/general.md, sync.md, sandbox.md, storage.md.
- Sidebar groups: Dashboard, Inbox (with New Ask and Quick Change buttons); Work (Pull Requests, Issues with All and Not on a board, Epics, Repositories, Projects, Views); Delivery (Scorecards, PR flow, Issue flow, Releases, Investments, CI); Team (Everyone, teams, Activity, Time off); Rituals (Standup, Prioritisation, Planning, Board Hygiene); Harness (Plans, Requirements, Findings, Skills, Prompts, Learnings, Research, Refines); Agents (Metrics, Waiting on You, Routines, Queue, sessions). Not in docs (only index pages exist); candidate for a "Tour of the sidebar" page.
- Org Settings is opened by the cog beside the account menu; panes are picked from a segmented control: Repositories, Projects, People, Working Time, Issues, Investments, Goals, Harness, Hidden. Already in settings/org/*.md.
- Windows: File > New Window and New Tab; each window or tab remembers its own org, project, section and metrics window; a new window opens on the last org picked. Back is ⌘[ or Esc. Partly in keyboard-shortcuts.md.
- Right-click menus offer Open in New Tab and Open in New Window.
- Personal GitHub account is listed first under Personal in the account menu and works as an org (no teams; members are just you).
- Stars are local to the app. Hiding PRs/issues is local; Hide/Unhide in the context menu; Exclude drafts removes draft PRs from counts.
- A person's load is their open PRs, review requests and assigned issues with an open PR; unstarted assigned issues are backlog.
- Refresh: incremental; full search daily or via Full Refresh (Option-click or right-click the Refresh link; ⌘R). Members and teams refetched hourly or on manual Refresh. Partly in github-budget.md.
- Sidebar footer sync row: Refresh link, API budget and reset (or Paused to, in orange), chevron opening step detail that slides up during a sync. Budget part already in concepts/github-budget.md.
- Sync pane layout: Workload, Issues, Pages, In the background; each row a menu of Off (where allowed) then intervals. Already in settings/app/sync.md and concepts/github-budget.md.
- Pages whose source is off say so at the top.

## Drawers and Inbox
- PRs, issues and harness documents open in a drawer over the page; links inside stack more drawers (dimmed edges, up to three, click to go back); Done or Esc closes the top one; click outside closes all; Open as Page / Open in Window available. Issue drawers show facts, timeline, plans, linked PRs, description, board fields. Arrow keys step through the view's issues.
- Issue timeline: opened, assigned, board moves, sub-issues, reopened, closed, comments, each linked PR's commits, reviews and merge.
- Inbox: sections for Claude Code sessions waiting on you, While you were away (reviews on PRs Claude reviewed), reviews requested of you (longest waiting first), Changed since your review, your open PRs, your assigned issues (in progress first); off by default: issues you opened, your harness plans, uncategorised investments. A Sections popover ticks and reorders them. Count is reviews waiting plus your PRs with changes requested. Columns sort within sections.

## Repositories (local git)
- Work > Repositories covers everyday git: repo switcher at the top left of the bar, branch and worktree popovers, History and Changes parts, sync button (Publish Branch, Pull with arrows, Push, else Fetch) with menu for Fetch, Pull, Push, Force Push; Open menu (editor, Terminal, Finder, GitHub). Add a Repo to the project. A project naming no repos lists those with work in flight and clones saved here.
- Changes: Conflicted, Staged, Changes, Stage All and Unstage All, per-file menu (stage, unstage, discard with confirmation, take ours/theirs, mark resolved, open, reveal); hunk buttons; binary files as sizes, images as pictures; banners for merge/rebase under way (Continue, Abort), changes left on a branch (Restore, Drop), detached HEAD. Commit composer with summary hint (orange past 50, red past 72), description, Amend, Undo (only unpushed commits). Discarding a staged file with unstaged edits says both go.
- Branches popover: search (arrows move, Return switches), local branches with ahead/behind, Not published, Gone from origin, worktree holding it; remote-only branches; New Branch; context menu Switch, New Worktree for, New Branch from, Publish, Rename, Delete (Delete Anyway when unmerged). Switching with changes asks: leave (stashed as "Gannin: left on <branch>") or bring them. Worktrees: Work Here, open, Remove, New Worktree, Prune.
- History: current branch's commits, 200 at a time, search field, SHA/author/when, Not pushed, other branches and tags at the commit; picking shows message, files, diff. Tag This Commit opens a sheet (annotated, pushed by default, next patch version suggested, warning if already tagged). Tag context menu pushes, branches from, deletes. Push N Tags.
- Pull follows pull.rebase; divergent branches ask Merge or Rebase. Background fetch every five minutes while the page is open (mentioned only in the sync button's help). Failures show git's full output.
- Clone uses gh when installed, else git over https, into the harness's projects/<name> or <workspace>/<owner>/<name>.
Docs: only settings/org/repositories.md exists; no page for the Repositories page itself. Candidate "Repositories" page.

## Command palette
- View > Command Palette (⌘K) opens over any window. Searches what's cached for every org: actions (New Issue, Refresh, Full Refresh, switch org or project, New Window and Tab, Open Claude Code, Next Session Waiting on You, Exclude drafts and Show hidden toggles), pages and Settings panes, people, open and recently merged PRs, issue history, harness documents, boards and views, repos and sessions, each labelled with its org; footer names orgs with nothing cached. Every word typed is needed; #123 or repo#123 finds that number; six results per group; "In Descriptions" matches appear shortly after typing stops. With nothing typed: recents and suggested actions. Arrows move, Return picks, Esc closes. A result in another org asks (switch this window, new tab, new window); ⌘↩ and ⌥↩ skip the question. In the Claude Code window a focused terminal keeps ⌘K. Mentioned in keyboard-shortcuts.md; full behaviour not documented.

## Fetching and the rate limit
- Already in concepts/github-budget.md and settings/app/sync.md: 5,000-point hourly budget, reserve default 500, Spent breakdown, warning past half, Paused to, off meaning not fetched, rows that can't be turned off.
- Not in docs: Settings > Sync's lookback and Actions jobs per workflow are under How much (check sync.md).
- Mutations count as Changes you make (a point each) in Spent.
- Sign-in: GitHub device flow; token in the keychain. Already in get-started/sign-in.md and concepts/privacy.md.
- Where data is kept: entered data on this device only (no iCloud), team data in the project's harness, GitHub caches local. Already in concepts/where-things-are-kept.md.
- Page titles are the window title; top-level controls are in the toolbar.

## Dropped
- Auth/GitHub/Workload/Views directory listings and "Layout" file-to-purpose bullets: greppable.
- `getgannin` bundle migration (`BundleMove`) sentence, and "copied from UserDefaults once (`userDataMigrated`)": history.
- Issue and plan references (#NN, plans/...): history.
- Local-git sentences narrating History/Changes/Branches layout where the code is the truth (duplicated in backlog above).
- Fetching intro list of Sync source sections: duplicate of SyncSource titles and sync.md.
- `Gannin/Workload/DetailStore.swift` and `SyncActivity.swift` layout bullets (cache size 500, one-day rule; footer description): derivable from code; footer behaviour kept in backlog.
- "Mutations skip the rateLimit field" kept; "Stars ... stored in UserDefaults" kept short.
- Sidebar inner-workings of `OverviewView` parts: belongs to metrics/dashboard rules, not these paths.
