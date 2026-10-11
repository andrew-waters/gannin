---
paths:
  - "Gannin/Palette/**"
---

# Command palette

- Build items from cache only; never fetch from the palette (`PaletteSources`, `loadCached`). Decode large issue histories one org per frame, off the critical path, since they decode on the main actor.
- Rank when the query or items change, not on redraw.
- The window's project is ignored; results are org-wide.
- In the Claude Code window a focused terminal keeps ⌘K; the command must pass the key on to SwiftTerm's `TerminalView`.
- Route results through `PaletteDestination`; a result in another org must ask (switch, tab, window) unless ⌘↩ or ⌥↩ was used.
- Every row needs a VoiceOver label (kind and org); keep announcing the result count once typing settles, and return focus to what had it on close.
- Palette behaviour is documented for users; update docs-site when commands or groups change.

## Testing
- No tests cover the palette; check by hand with `scripts/relaunch.sh`, then ⌘K with and without a query, and a result in another org.
