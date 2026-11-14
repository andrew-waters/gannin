# GPUI pilot

A pilot for moving Gannin off SwiftUI onto [GPUI](https://www.gpui.rs), Zed's Rust UI framework,
and for consolidating its windows into one. Inside a single-window shell it rebuilds CI, Issues,
Pull Requests, Scorecards and Activity; syncs its own copy of the org's PRs and issues from
GitHub; and starts Claude Code the way Gannin does (Work on This, Review with Claude, Plan, Ask,
Quick Change, Explain) in Zed's terminal, beside the code change in Zed's diff view.

**Licence:** it builds on Zed's own crates from Zed's repository (`terminal`, `terminal_view`,
`editor`, `buffer_diff`, `multi_buffer` and what they need), which are GPL-3.0. Anything shipped on
this code would have to be GPL-3.0 too. Only `gpui` and a few utility crates are Apache-2.0.

It's a separate Cargo binary and isn't part of the Xcode build. It reads Gannin's caches and
settings and never writes them: it keeps its own copies of the PR, issue and CI caches (seeded from
Gannin's) under `Application Support/GanninGPUIPilot/`, and its own sessions there too. Its calls to
GitHub are reads (signing in, syncing, Your Work), plus posting a review, which only happens from
the Post to GitHub button after the review sheet has shown what will be sent. A session's terminal
runs claude, which acts as you, as in Gannin.

## Running it

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
the two variables. `--org` and `--days` override what was saved.

## What it reads

| Data | From |
| --- | --- |
| CI runs | The pilot's copy of `Actions/<org>.json` |
| Issues, board fields, status history, linked PRs | The pilot's copy of `StoredIssues/<org>.json`, synced |
| Descriptions and comments | `Application Support/Details.json`, else `dev.andon.gannin/IssueText.sqlite` |
| Projects and the issue workflow | `Application Support/UserData/Gannin.store` (org settings) and `Application Support/Harness/*.json` (each harness's `.gannin/project.json`) |
| Pull requests: review, checks, reviewers, commits | The pilot's copy of `PullRequests/<org>.json`, synced |
| Your Work | Live from GitHub when signed in, else the PR cache |
| Scorecards and Activity | Gannin's own `PullRequests/`, `Metrics/`, `WorkLog/` and `Snapshots/` (the metrics and work-log slots the pilot doesn't sync), and the org's goals and exclusions from its settings |
| Session state | Hook files in the pilot's `Sessions/<id>/`, and claude's transcript for a review's result |
| Avatars | Downloaded once with `curl` into `~/Library/Caches/GanninGPUIPilot/avatars` |

Where the window was left (org, project, tabs, panels, each page's controls and columns) is saved
in `Application Support/GanninGPUIPilot/state.json`, never in Gannin's own folders.

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
  asks for a folder and opens a tab with Zed's own `TerminalView` beside the folder's uncommitted
  changes in Zed's editor, as a multibuffer of hunks per file, read with git every two seconds
  while the tab shows. Zed's views run without a Zed workspace or project (empty handles), with
  Zed's default settings, theme and fonts (`src/zed.rs`). State comes from the terminal, as no
  hooks are installed: output moving is Working, a prompt on screen or the bell is Needs you,
  quiet is Your turn.
- **Your Work** (`src/shell.rs`, `src/work.rs`): the right-hand panel, after the menu bar's list.
  Sessions waiting on you, reviews asked of you, your PRs needing you, sessions working, your
  other PRs and issues assigned to you, in that order. A session or an issue switches to its tab;
  a PR opens on GitHub. Built from caches, so Conflicts and team review requests don't show.
- **Account** (`src/auth.rs`): at the right of the title bar, as Zed's: Sign In when signed out,
  else your avatar with a menu (profile, Sign Out). Signing in is GitHub's device flow on Gannin's
  OAuth app, as Gannin's sign-in. The token is the pilot's own, in its own keychain item, reached
  through the `security` tool (an unsigned binary that changes every build would be asked to
  allow keychain access after each one), so signing out here leaves Gannin signed in. Your Work
  reads as the signed-in login, else Gannin's.
- **Pull Requests** (`src/prs.rs`): built the way Issues was rather than copied from
  `PullRequestsView`: one list of every PR in the org's cache, a State menu (Open, Merged, Closed)
  in place of the Open/Merged/All picker and its two sections, filter menus with counts (Status,
  Author, Reviewer, Checks, Repository, with Me first), and columns each person picks, orders and
  sizes. PRs closed without merging show too (the work log has them; the Swift page doesn't list
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
  lines, duplicates left out after re-fetching, never the same review twice).
- **Planning, Ask, Quick Change** (`src/launch_form.rs`, `src/planning_panel.rs`): forms with
  Zed's editor; a plan's `planning.json` shown as stages, requirement, design, tasks and
  decisions, with "From the room". A quick change files no issue.
- **Scorecards** (`src/scorecard.rs`): the org's goals as tiles and a period table, with Gannin's
  metric definitions. `--scorecard <org>` prints recent weeks.
- **Activity** (`src/activity.rs`): the work log grid of dots and Threads. `--activity <org>`.

Left out: Me in Issues filters, images in Markdown, the Investment picker, harness documents,
writes to GitHub other than posting a review (board fields, assignees, reviewers, new issues and
sub-issues, filing a quick change's issue, recording sessions in the harness, a plan's Agree),
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
