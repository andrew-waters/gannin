---
type: plan
status: in-progress
summary: "Replace SessionStore.poll's per-second hook-file reads with file system events, keeping a slow safety-net poll and the ssh poll."
issues: [andrew-waters/gannin#235]
touches: [andrew-waters/gannin]
owner: dwrss
---

# SessionStore.poll: event-driven hook reads

Stage 4 of `plans/2026-10-11-sync-overlap-and-cleanup.md`. Decision on the issue: watch the hook
files (option 1), not just move the reads off the main actor.

## Tasks

- [ ] Spike: do a sandboxed session's hook files (mounted from the Mac) raise file events on the Mac? Until checked on a real sandbox, sandboxed sessions keep the two-second poll.
- [x] Spike: SwiftTerm's `LocalProcessTerminalView.rangeChanged` is `open`, so a subclass reports screen changes.
- [x] `HookFileWatcher`: a watcher on the folder and on each hook file (hooks write with `>`, in place), debounced, with the files read on a detached task and applied on the main actor.
- [x] `SessionStore`: watchers start with the terminal and stop when it ends or the session is removed.
- [x] Safety-net poll for local sessions (ten seconds); two seconds for ssh and sandboxed sessions.
- [x] Footer mode and permission-prompt scans run only after the screen changes, once a second at most, keeping the two-sightings rule.
- [x] Tests (Swift Testing): in-place rewrite, file created later, replaced by rename, burst, cancel.
- [x] Update `.claude/rules/sessions-core.md` and `sessions-store.md`. No `CHANGELOG.md` entry: nothing changes for the person using the app.
- [x] Build and run the tests.
- [ ] Try in a running session: Needs you, Your turn, exit, Dock badge and notification in the background, a server, a sandbox.
