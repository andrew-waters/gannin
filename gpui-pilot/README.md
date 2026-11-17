# GPUI pilot

A pilot for moving Gannin off SwiftUI onto [GPUI](https://www.gpui.rs), Zed's Rust UI framework,
and for consolidating its windows into one. Inside a single-window shell it rebuilds CI, Issues,
Pull Requests, Scorecards and Activity; syncs its own copy of the org's PRs and issues from
GitHub; and starts Claude Code the way Gannin does (Work on This, Review with Claude, Plan, Ask,
Quick Change, Explain) in Zed's terminal, beside the code change in Zed's diff view.

**Licence:** it builds on Zed's own crates from Zed's repository (`terminal`, `terminal_view`,
`editor`, `buffer_diff`, `multi_buffer` and what they need), which are GPL-3.0. Anything shipped on
this code would have to be GPL-3.0 too. Only `gpui` and a few utility crates are Apache-2.0.

It's a separate Cargo binary and isn't part of the Xcode build, and it needs nothing of the Swift
app's: it syncs its own PR, issue and CI caches into the org's harness checkout
(`<harness>/.gannin-cache/`, ignored by git), reads the harness itself with git, and keeps
everything else in `~/.gannin/`. It builds and runs on macOS and Linux. Its calls to
GitHub are reads (signing in, syncing, Your Work, an opened drawer), plus writes only after the app
has shown what will be sent: posting a review (Post to GitHub), and creating an issue with its
images committed to the harness (Create on GitHub). A session's terminal
runs claude, which acts as you, as in Gannin.

## Running it

### macOS

Needs a Rust toolchain (`rustup`), Xcode's command line tools and `cmake` (tree-sitter's wasm
runtime, which Zed's `language` crate pulls in, builds with it). The `runtime_shaders` feature
compiles GPUI's Metal shaders at launch, so the separate Metal toolchain download isn't needed.

```bash
brew install rustup cmake && rustup default stable   # rustup is keg-only: add /opt/homebrew/opt/rustup/bin to PATH
cd gpui-pilot
export SDKROOT="$(xcrun --show-sdk-path)" BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
cargo run --release -- [--org <org>] [--days 30]
```

The first build compiles Zed's dependency tree (over a thousand crates) and takes a while; after
that a change rebuilds in seconds. Zed is pinned to one commit in `Cargo.toml`, and the lockfile
started from Zed's own so the versions match its. GPUI's build script runs bindgen over `dispatch.h`, which can't find the macOS SDK on its own, hence
the two variables. `--org` and `--days` override what was saved. `scripts/bundle.sh` builds it and
wraps it as `target/release/Gannin.app`.

### Linux

Needs a Rust toolchain, `cmake`, `clang`, `git`, `curl` and `gh` (signed in: the pilot uses gh's
token, `gh auth token`, and signing in from the app signs gh in), plus GPUI's libraries for
Wayland and X11 (on Debian or Ubuntu: `libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev
libvulkan-dev libx11-xcb-dev libxcb1-dev libfontconfig-dev libssl-dev`), as Zed's own
`script/linux` installs them.

```bash
cd gpui-pilot
cargo run --release
```

Mac only: the screenshot thumbnail's file promises (New Issue takes plain file drops on Linux)
and `scripts/bundle.sh`. Shortcuts use Command on a Mac and Control on Linux; the Linux build
hasn't been run yet.

## What it reads

| Data | From |
| --- | --- |
| CI runs | `Actions/<org>.json` in the org's cache, synced by the pilot from GitHub's REST API when the CI page opens (every 10 minutes at most) and on Refresh |
| Issues, board fields, status history, linked PRs | The pilot's copy of `StoredIssues/<org>.json`, synced |
| Descriptions and comments | Fetched from GitHub as a drawer opens, kept in the org's `Details.json` |
| An opened issue | Fetched with its drawer (core, board fields, status history, linked PRs) into the pilot's issue store, so the list shows it as it is now |
| New Issue | Live from GitHub: the org's repositories, boards and issue types; a repository's labels, assignable people and issue templates; a board's single-select fields. Skills from the harness checkout on this Mac |
| Projects and the issue workflow | The org's harnesses (those in folders opened here, kept in order in `~/.gannin/orgs/<org>.json`), each read with git from its default branch: `.gannin/project.json`, `workflow.json` and the other team files |
| Harness documents, Agents › Metrics | The same: the documents' folders, parsed as Gannin parses them (`src/harness_doc.rs`), and `.gannin/reviews/`. A harness with no checkout here is cloned into `~/.gannin/harnesses/` |
| Pull requests: review, checks, reviewers, commits | The pilot's copy of `PullRequests/<org>.json`, synced |
| Your Work | Live from GitHub when signed in, else the PR cache |
| Scorecards and Activity | The org's synced `PullRequests/`, `Metrics/`, `WorkLog/` and `Snapshots/`, and its goals and exclusions from the home harness's team files |
| Session state | Hook files in the session's folder (`<harness>/.gannin-cache/sessions/<id>/`), and claude's transcript for a review's result |
| Avatars | Downloaded once with `curl` into the system's caches folder (`~/Library/Caches/GanninGPUIPilot` or `~/.cache/gannin`) |

Where the window was left (org, project, tabs, panels, each page's controls and columns) is saved
in `~/.gannin/state.json`. Headless checks: `--harness <org>` prints what the harnesses hold.

## What's built

- **Shell** (`src/shell.rs`): one window in place of today's several. A title bar with org and
  project pickers after Zed's branch picker; the sidebar with `OrgSidebar`'s sections; pages as
  tabs; issues in stacked drawers that slide in over the page; an inspector for CI repos; a dock
  where Claude Code sessions would go; and a status bar. Panels resize by dragging. GPUI has none
  of this built in (Zed's docks, panes and tabs are in its GPL `workspace` crate), so it's our own.
- **CI** (`src/page.rs`, `src/metrics.rs`, `src/charts.rs`): stat tiles, the three trend charts
  with hover and the Repositories table, ported from `ActionsView` and `ActionsMetrics`. Charts are
  drawn by hand: bars as divs, lines on a canvas with `PathBuilder`.
- **Issues** (`src/issues.rs`): one list, virtualised with `uniform_list`. The filter bar from
  `IssueFilterBar` (search, multi-select State, Assignee, Repository, Label, Board, Field,
  Milestone), the sub-issue tree with a drill-down into a parent, and columns each person chooses,
  orders by dragging and sizes, with board fields as columns.
- **Sessions** (`src/session.rs`, `src/changes.rs`): New Claude Code (Command-T) or New Terminal
  opens a tab in the window's folder (asking for one only when the window has none, or is on a server) with Zed's own `TerminalView` beside the folder's uncommitted
  changes in Zed's editor, as a multibuffer of hunks per file, read with git every two seconds
  while the tab shows. Zed's views run without a Zed workspace or project (empty handles), with
  Zed's default settings, theme and fonts (`src/zed.rs`). State comes from the terminal, as no
  hooks are installed: output moving is Working, a prompt on screen or the bell is Needs you,
  quiet is Your turn.
- **Move to Server** (`src/session_move.rs`): a stopped session started on this Mac moves to the
  window's server and resumes there. Its worktrees are made there at the same commits (branches
  go as git bundles, nothing is pushed), with what isn't committed copied as files, and Claude's
  conversation goes to the project folder Claude Code keeps for the harness's path there. The
  copies on this Mac are left as they were.
- **Tab bar** (`src/shell.rs`): the filter menu at its left picks a kind of tab and, below, Active
  or Stopped (a session whose claude has ended); Find PR # beside it keeps the sessions that own a
  number (a review's PR, a work session's issue, or a PR it opened) or whose name matches the words
  typed. Enter opens the first found, Escape clears it. View › Toggle Tabs on Left (or its button in the status bar) moves the tabs
  to a column beside the content (filter, search and "+" at its top), kept with the window's state.
- **Your Work** (`src/shell.rs`, `src/work.rs`): the right-hand panel, after the menu bar's list.
  Sessions waiting on you, reviews asked of you, your PRs needing you, sessions working, your
  other PRs and issues assigned to you, in that order. A session or an issue switches to its tab;
  a PR opens on GitHub. Built from caches, so Conflicts and team review requests don't show.
- **Account** (`src/auth.rs`): at the right of the title bar, as Zed's: Sign In when signed out,
  else your avatar with a menu (profile, Sign Out). Signing in is GitHub's device flow on Gannin's
  OAuth app, as Gannin's sign-in. On a Mac the token is the pilot's own, in its own keychain item,
  reached through the `security` tool (an unsigned binary that changes every build would be asked
  to allow keychain access after each one), so signing out here leaves Gannin signed in. On Linux
  it's gh's. Your Work reads as the signed-in login.
- **Pull Requests** (`src/prs.rs`): built the way Issues was rather than copied from
  `PullRequestsView`: one list of every PR in the org's cache, a State menu (Open, Merged, Closed)
  in place of the Open/Merged/All picker and its two sections, filter menus with counts (Status,
  Author, Reviewer, Requested, Checks, Repository, with Me first), and columns each person picks,
  orders and sizes. Requested (a menu and a column) is whether you're asked to review: Requested,
  Reviewed or Not requested; only a request to you by name counts, as team requests aren't cached
  with their members. PRs closed without merging show too (the work log has them; the Swift page doesn't list
  them). A row opens a drawer, as an issue does: facts, activity from the work log, linked issues
  (which open as issue drawers on top), description and comments, and the people with where each
  reviewer stands. Labels, the base branch and conflicts aren't cached, so they don't show.
- **Issue drawer** (`src/shell.rs`, `src/detail.rs`, `src/markdown.rs`): what `IssueWindow` shows,
  with timing under the org's workflow and Markdown through pulldown-cmark. Its bar has Open on
  GitHub, Plan This (Open Planning) and Work on This (Open Session); the PR drawer's has Open on
  GitHub, Review with Claude (Open Review) and Explain.
- **Syncing** (`src/sync.rs`, `src/github.rs`, `src/cache.rs`): every 5 minutes while signed in,
  the current org's open and recently merged PRs and open issues, with Gannin's searches, fields
  and merge rules: in full once a day, else what changed. Rate-limited as Gannin is (a refusal
  pauses everything; a low budget holds the automatic sync off). The title bar shows when it last
  synced and syncs on a click. `--sync <org>` runs one from a shell.
- **Launching sessions** (`src/launch.rs`): as Gannin's start script: in the org's harness, in
  `.worktrees/<branch>/`, with its brief, hooks (state, started, changed, PRs opened) and prompts,
  resuming claude once started. Session state comes from the hooks' files. `--dry-launch <dir>`
  writes a launch against a scratch harness to check with a stand-in claude.
- **Reviews** (`src/review.rs`, `src/review_panel.rs`): edits disallowed, Gannin's prompt; the
  result read from claude's transcript beside the terminal, findings to dismiss or restore, Review
  Again, and Post Review with Gannin's rules (Comment only on your own PR, inline only on diff
  lines, duplicates left out after re-fetching, never the same review twice), then the threads
  claude says are dealt with resolved (only unresolved ones of yours on that PR). The plans the PR
  or its closing issues link to show under the verdict, each with its ticked tasks as a ring.
- **Marra** (`src/marra*.rs`, design in `docs/marra.md`): ⌘J (or View › Marra) opens the assistant,
  floating above other apps on every Space, or docked down the right of a Gannin window. One
  headless claude kept running (stream-json both ways, resumed after a relaunch) whose permission
  requests Gannin answers: read-only tools go through, the rest wait on a card. Gannin is its
  toolbox, an MCP server on 127.0.0.1 behind a token made at launch. Needs you, threads for Marra,
  every open session and each errand (a read-only worker in a harness for a data question or an
  investigation, replying under a contract), Remind me, Focus and notifications. Its state is in
  `~/.gannin/marra/`. `--marra-check [model]` runs the engine and the MCP server against a real
  claude without a window. `--assistant-preview` is the clickable mock-up it was designed from.
- **Plans and requirements** (`src/harness.rs`): a Work on This session's Issue pane lists the
  harness documents about or mentioning its issue or PRs, with their progress, read again every
  minute; a row opens the document in a drawer.
- **Planning, Ask, Quick Change** (`src/launch_form.rs`, `src/planning_panel.rs`): forms with
  Zed's editor; a plan's `planning.json` shown as stages, requirement, design, tasks and
  decisions, with "From the room". A quick change files no issue.
- **New Issue** (`src/new_issue.rs`): New Issue at the end of the Issues filter bar, in the + menu, or
  New Sub-issue in an issue's drawer, opens a subpage over the tab: Claude on the left, the issue
  on the right. Say what it's about and Claude scouts the code (one read-only `claude -p` turn in
  the harness covering the repository) and fills in the repository, title, description, labels,
  type and board fields; Revise as often as needed. It follows the repository's issue template
  (from `.github/ISSUE_TEMPLATE`, picked under Template) and the harness skills ticked beside it
  (read from the harness checkout, those about issues ticked to start). Images dropped on the page,
  pasted or added are committed to the harness in one commit before the issue is made
  (`src/issue_parts.rs`), and linked at that commit. Back keeps the draft and the page beneath as
  they were; New Issue resumes it. Review shows every write, and Create on GitHub sends them in
  Gannin's order (create, sub-issue, board, fields), then opens the new issue's drawer.
- **Scorecards** (`src/scorecard.rs`): the org's goals as tiles and a period table, with Gannin's
  metric definitions. `--scorecard <org>` prints recent weeks.
- **Activity** (`src/activity.rs`): the work log grid of dots and Threads. `--activity <org>`.

Left out: Me in Issues filters, images in Markdown, the Investment picker, harness documents,
writes to GitHub other than posting a review and New Issue (editing board fields, assignees, reviewers, filing a quick change's issue, recording sessions in the harness, a plan's Agree),
Gannin's own sessions, staging or committing from the diff, syntax colours in it, Schedule for
Agent, Hide, Scorecards' editing, breakdowns and issue and CI metrics, Activity's Punchcards, the
Actions sync, and the other pages (commented out in `sections()`).

## What it has shown

- **Missing from GPUI:** charts, a text field (the search fields take keys by hand: no cursor,
  selection or paste beyond Command-V), a Markdown renderer, tooltips as plain strings, loading
  images from a URL without wiring in an HTTP client, SF Symbols, and accessibility.
- **Zed's GPL crates fill most of it:** its terminal and diff editor run outside Zed with empty
  workspace and project handles and its default settings. The cost is the licence, a much bigger
  first build, and tracking Zed's main branch, whose gpui API moves (focus now takes the app,
  menus have `disabled`, text needs `gpui_platform`'s `font-kit` feature).
- **Possible regardless:** custom chrome, drawers with animation, drag and drop, virtualised
  lists, popovers and keyboard handling all came together quickly from GPUI's primitives.
