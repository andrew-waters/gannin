---
type: requirement
status: in-progress
summary: "One place answers 'when did this issue last have activity?' from the local issue history, using every dated source it holds, ready for the Triage queue (#160) to compare against the last pass."
issues: [andrew-waters/gannin#159]
plans: [plans/2026-10-14-keep-updatedat-on-issues.md]
---

# Keep updatedAt on issues

## Problem

Triage's re-check (R5 of the Triage plan) needs to know which bucketed issues have had activity since the last pass, or it has to re-queue every one. IssueRecord already stores GitHub's updatedAt, but nothing combines it with board moves, reopenings, sub-issues and linked PR dates into one last-activity date, and nothing tests that older caches without it load.

## Goal

One place answers 'when did this issue last have activity?' from the local issue history, using every dated source it holds, ready for the Triage queue (#160) to compare against the last pass.

## Who it's for

The product lead running the weekly Triage pass (indirectly); engineers building the Triage queue (#160).

## Requirements

1. Confirm IssueRecord.updatedAt is stored on every fetch and that older records without it still decode (already true; pin it with tests)
2. Work out an issue's last activity as the latest of updatedAt, board moves, reopenings, sub-issues added and linked PRs' dates

## Out of scope

- Showing the last-activity date anywhere in the UI (enabler only)
- The Triage queue that uses it, and how it treats an issue with no last activity (#160)
- Any change to docs-site: no user docs page changes, and no CHANGELOG line, as nothing a user sees changes

## Acceptance criteria

- **R1** When issues are fetched for the issue history, the system shall store each issue's GitHub updatedAt on its IssueRecord.
- **R2** When a cached IssueRecord saved without updatedAt is loaded, the system shall decode it without error and leave updatedAt unset until the issue is next fetched.
- **R3** When an issue's last activity is asked for, the system shall return the latest of its updatedAt, board moves, reopenings, sub-issues added and linked PRs' dates, ignoring any source with no date.
- **R4** When an issue has no dated source, the system shall report its last activity as none rather than a default date.

Planned in [plans/2026-10-14-keep-updatedat-on-issues.md](../plans/2026-10-14-keep-updatedat-on-issues.md).
