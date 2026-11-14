# GPUI pilot

A pilot for moving Gannin off SwiftUI onto [GPUI](https://www.gpui.rs), Zed's Rust UI framework,
and for consolidating its windows into one. It rebuilds the CI page (the part of the app that
leans hardest on Swift Charts) and the Issues page with its drawer, inside a single-window shell.

It's a separate Cargo binary and isn't part of the Xcode build. It only reads: it opens Gannin's
caches and settings and never calls GitHub. Open CI and Issues in Gannin at least once so there's
something to read.

## Running it

Needs a Rust toolchain (`rustup`) and Xcode's command line tools. The `runtime_shaders` feature
compiles GPUI's Metal shaders at launch, so the separate Metal toolchain download isn't needed.

```bash
brew install rustup && rustup default stable   # rustup is keg-only: add /opt/homebrew/opt/rustup/bin to PATH
cd gpui-pilot
export SDKROOT="$(xcrun --show-sdk-path)" BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
cargo run --release -- [--org <org>] [--days 30]
```

GPUI's build script runs bindgen over `dispatch.h`, which can't find the macOS SDK on its own, hence
the two variables. `--org` and `--days` override what was saved.

## What it reads

| Data | From |
| --- | --- |
| CI runs | `Application Support/Actions/<org>.json` |
| Issues, board fields, status history, linked PRs | `Application Support/StoredIssues/<org>.json` |
| Descriptions and comments | `Application Support/Details.json`, else `dev.andon.gannin/IssueText.sqlite` |
| Projects and the issue workflow | `Application Support/UserData/Gannin.store` (org settings) and `Application Support/Harness/*.json` (each harness's `.gannin/project.json`) |
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
- **Issue drawer** (`src/shell.rs`, `src/detail.rs`, `src/markdown.rs`): what `IssueWindow` shows,
  with timing under the org's workflow and Markdown through pulldown-cmark.

Left out: Me in filters (no signed-in viewer), images in Markdown, commits in the timeline (they
need the work log), session and agent actions, the Investment picker, harness documents, every
write to GitHub and every other page.

## What it has shown

- **Missing from GPUI:** charts, a text field (the search fields take keys by hand: no cursor,
  selection or paste beyond Command-V), a Markdown renderer, tooltips as plain strings, loading
  images from a URL without wiring in an HTTP client, SF Symbols, and accessibility.
- **Possible regardless:** custom chrome, drawers with animation, drag and drop, virtualised
  lists, popovers and keyboard handling all came together quickly from GPUI's primitives.
