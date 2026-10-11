---
paths:
  - "Gannin/Palette/**"
---

# Command palette

- `PaletteSources` builds `PaletteItem`s from cache only, never fetching: per org it loads the snapshot and boards from disk (`loadCached`, `loadCachedBoards`), then issue histories one org a frame apart (large, decoded on the main actor). `IssueTextIndex` adds In Descriptions matches shortly after typing stops.
- Ranking runs when the query or items change, not on redraw. `PaletteQuery` requires every typed word; `#123`/`repo#123` finds that number first; then title prefix, word prefix, anything else; ties by the window's org, open items, shorter titles. Groups (`PaletteGroup`) show six each.
- The window's project is ignored. Recents (`PaletteRecents`) are by item ID, per Mac.
- `.commandPalette` on `MainView`; `.commandPaletteOpeningInMainWindow()` on issue, PR and Claude Code windows. In the Claude Code window a focused terminal keeps ⌘K: the command passes the key to SwiftTerm's `TerminalView`.
- Delivery: results are `PaletteDestination`s (org + `PaletteTarget`). In a main window `MainView.openFromPalette`/`deliver` sets sidebar row, Settings pane (`orgSettingsPane` scene storage read by `OrgSettingsView`) or project; PRs, issues, documents and New Issue go to `PageStack` via `paletteDelivery`. A result in another org asks (switch, new tab, new window; `NavigationRequest.palette` carries it); ⌘↩/⌥↩ skip the question. Other windows send results to the last-used main window (`PaletteRouter`, ordered by `controlActiveState`), else a new one. Refresh is `OrgRefresh`, shared with the sidebar.
- Accessibility: rows carry labels (kind and org), the highlighted one is selected, result count is announced once typing settles. Focus returns to what had it on close.
