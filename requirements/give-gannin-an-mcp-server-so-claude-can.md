---
type: requirement
status: in-progress
summary: "Claude reports review results to Gannin directly, and Gannin shows them without parsing returned JSON."
issues: [andrew-waters/gannin#520]
plans: [plans/2026-11-02-give-gannin-an-mcp-server-so-claude-can.md]
---

# Gannin MCP server for Claude results

## Problem

Gannin asks Claude to end a PR review with a fenced JSON block, then SessionTranscript.lastJSON/review parse the last reply. Once Gannin has read a review it keeps it (CodeSession.reviewResult, PairReview.claudeFindings, review records), but it only ever looks at the last reply: if someone asks Claude another question before Gannin has read the JSON (a poll gap, Gannin closed, a long transcript), the earlier reply is never looked at and the review is missed. A missing or unclosed fence, or an object that fails to decode, also yields no review, and an empty findings list looks like a review that found nothing. ReviewResult's lenient decoding grows with every new field.

## Goal

Claude reports review results to Gannin directly, and Gannin shows them without parsing returned JSON.

## Who it's for

People using Gannin's PR reviews; developers maintaining the review and session code.

## Requirements

1. The built-in pair review: the Claude reviewer session started when someone works on an issue (SessionStore.reviewRequested / startHelper) reports its findings to Gannin as a tool call.
2. Claude's PR review sessions (manual and auto review) report their results through the same server, so both review paths stop depending on the last reply being JSON.

## Out of scope

- Reviews in a sandbox container or on a server over ssh: they keep the JSON path in this version, because a server on this Mac may not be reachable from them.
- Junie. It is the only ExtraReviewer today, runs as a one-shot CLI in a throwaway copy, and stays on the JSON path.
- Other results Claude writes (refine.json, the planning state file) are not named by the room so far.

## Acceptance criteria

- **R1** When Gannin starts a Claude review session on this Mac outside a sandbox or server (a pair reviewer, or a manual or auto PR review), the system shall make an MCP server available that the session can call.
- **R2** When a review session reports its findings through the server, the system shall show them as that review's result without reading them from the transcript.
- **R3** When someone asks the review session another question before Gannin has read its report, the system shall still show the report, whichever reply it was in.
- **R4** When a review session reports no findings, the system shall record that as a completed review with none, distinct from a session that has not reported.
- **R5** When a report is malformed, the system shall reject the call with a message Claude can act on, and shall not show a partial review.
- **R6** When a review session finishes without having reported through the server, the system shall fall back to reading the last JSON block as it does today.
- **R7** When a review runs in a sandbox, on a server over ssh, or as a Junie one-shot, the system shall keep using the JSON path unchanged.
- **R8** While the server is running, the system shall accept calls only from sessions Gannin started, and each call shall be attributed to the session that made it.
- **R9** When this ships, the review pages under docs-site/src/content/docs/agents/ (pair-review.md, reviews.md, auto-review.md) shall say how a review's result arrives and what happens when Claude doesn't report, and CHANGELOG.md shall have an Unreleased line.

## Open questions

- How often does the JSON path fail today, and what does it cost? (Not measured; no incident is linked to the issue.)
- Spike to settle before building: does a real Claude Code session connect to the SDK's stateless transport (its Accept and Origin checks, its GET and DELETE 405s), does `--mcp-config` take a file and pre-approve `mcp__gannin__report_findings` and `mcp__gannin__report_pr_review`, and does SwiftPM resolve the SDK, whose manifest depends on swift-docc-plugin at `branch: main`?

Planned in [plans/2026-11-02-give-gannin-an-mcp-server-so-claude-can.md](../plans/2026-11-02-give-gannin-an-mcp-server-so-claude-can.md).
