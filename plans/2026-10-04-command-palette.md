---
type: plan
status: Done
summary: A ⌘K command palette in every window that finds pages, people, PRs, issues, harness documents, boards and settings from what Gannin has loaded, and runs common actions, all from the keyboard.
issues: [andrew-waters/gannin#4]
domains: [navigation, accessibility]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Command palette

## Context

There's no single place to find something or run an action: you have to know which sidebar row or page an
item lives under. The issue asks for a ⌘K palette that does both global search and actions, and leaves the
scope open. This plan settles those questions for a first version.

What's there already:

- Navigation is a few entry points: `MainView.sidebarSelection` (also the `showSidebarItem` action) picks
  any sidebar row; `PageStack.navigate` pushes a page, or opens a drawer for PRs, issues and harness
  documents; `WindowRequest` opens a new tab or window on a trail.
- Window-level commands use a `FocusedValues` entry set by the window and a menu command reading it
  (`NewIssueCommand`, `RenameTabCommand`).
- Everything worth searching is already loaded on the client: the snapshot's people and PRs, the issue
  history (`IssueStore`), the harness index (`HarnessStore.combined`), boards (`ProjectStore.boardLists`),
  field views and repos. `IssueSearch` matches every word typed, and `IssueTextIndex` is a full-text index
  of issue descriptions and comments.
- ⌘K isn't used anywhere in the app. Gannin is Mac only, so Ctrl+K off macOS doesn't apply.

## Decisions

- **Every window.** ⌘K opens the palette in main windows, issue and PR windows and the Claude Code
  window. In a main window it lives in `PageStack`, so it can push pages, open drawers and start New
  Issue; elsewhere, results open in the most recent main window, brought to the front. In the Claude
  Code window the palette takes ⌘K only when the terminal isn't focused, so the terminal keeps it.
- **Search runs on the client**, over what's loaded for every org at once, with no new fetches. Each
  result is labelled with its org. Matches inside issue descriptions and comments come from
  `IssueTextIndex` a moment later, in their own "In descriptions" group.
  - Only what's cached is searched. A footer names orgs with nothing loaded yet; the palette never
    fetches.
  - The window's project is ignored: everything in every org is searched.
  - Pages, settings and actions are offered for every org too, labelled with the org ("Overview · acme").
    On a tie, the window's own org ranks first.
  - Picking a result from another org asks each time, in a small prompt inside the palette: Switch This
    Window, Open in New Tab, Open in New Window (arrow keys and ↩, Esc goes back to the results). ⌘↩ and
    ⌥↩ go straight to a new tab or window without asking.
- **Searchable, first version:**
  - Pages: every sidebar section, the issue lists, harness kinds and people views
  - People (org members)
  - Pull requests: open and merged in the lookback
  - Issues: the issue history
  - Harness documents that follow the standard
  - Boards, field views and repositories
  - Claude Code sessions
  - Settings panes
  - `#123` or `repo#123` jumps straight to that issue or PR
- **Actions, first version:** New Issue, Refresh, Full Refresh, Switch Organisation, Switch Project, New
  Window, New Tab, Open Claude Code, Next Session Waiting on You, Exclude Drafts and Show Hidden toggles.
- **Opening elsewhere:** on a result, ↩ opens it here, ⌘↩ in a new tab and ⌥↩ in a new window, as the
  right-click menus do.
- **Ranking:** an exact number first, then a title starting with the query, then a word starting with it,
  then a match anywhere. Every word typed has to match, as `IssueSearch` does. Open items rank above
  closed ones on a tie.
- **Grouping:** Actions, Pages (with Settings panes), People, Pull Requests, Issues, Harness, Boards and
  Views, Repositories, Claude Code Sessions and In Descriptions, each with a heading and up to six results, best matches first, with an icon and a type label on every row so results and actions read differently.
- **Empty query:** up to eight recently picked results (kept on this Mac, the window's org's first, then
  other orgs', each labelled), then suggested actions.
- **Presentation:** a Spotlight-style panel over the page, the field focused. ↑/↓ move, ↩ picks, Esc
  closes and focus goes back to the page. An empty state says nothing matched.
- **Accessibility:** each row's label includes its type, the selected row has the selected trait, and the
  result count is announced as you type (`AccessibilityNotification.Announcement`, debounced).

## Tasks

- [x] `Gannin/Palette/PaletteItems.swift`: the item model (search hit or action, with a destination),
      sources per entity, ranking and grouping, recent items
- [x] `Gannin/Palette/CommandPalette.swift`: the panel, keyboard handling, empty state and accessibility
- [x] Host it in `PageStack`, with closures from `MainView` for switching org and project
- [x] Host it in the issue, PR and Claude Code windows, opening results in a main window
- [x] `FocusedValues` entry and View › Command Palette (⌘K) in `GanninApp`
- [x] Results across every cached org, labelled, with the footer for orgs with nothing loaded
- [x] The prompt for a result from another org (switch, new tab, new window)
- [x] Issue description and comment matches from `IssueTextIndex`
- [x] CLAUDE.md
- [x] Try it in the app: every kind of result and action, keyboard only, and with VoiceOver

## Follow-ups

- More entities: workflows and runs, scorecard measurables
- Commands registered by each page (its own toolbar actions) rather than one fixed list
