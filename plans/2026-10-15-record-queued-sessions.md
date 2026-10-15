---
type: plan
status: In Review
summary: A per-harness setting, on by default, decides whether sessions started from the agent queue or a pin commit their brief and session.json to the harness.
issues: [andrew-waters/gannin#376]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Record queued sessions

## Approach

A separate setting rather than the existing "Ask before recording a session": that one means "skip the confirmation", and a queued run has no confirmation, so reusing it would tie recording to a prompt that never appears. It is stored per harness and applies to both queue windows and pins, which share `startIssueRun`.

- [x] `SessionStore.recordsQueuedSessions(repo:)` (default on) and its setter.
- [x] `startIssueRun` records only when it is on; an unrecorded session already carries its brief in the start script.
- [x] Record queued sessions toggle in Settings › Harness, under Ask before recording a session.
- [x] Test for the default and per-harness value.
- [x] Docs (Settings reference, routines page), CHANGELOG and the routines rule.
