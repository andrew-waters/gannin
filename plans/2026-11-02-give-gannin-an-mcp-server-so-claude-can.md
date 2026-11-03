---
type: plan
status: in-progress
summary: "Gannin runs an MCP server inside the app so Claude review sessions started on this Mac report their results as tool calls, instead of Gannin parsing JSON out of the transcript."
issues: [andrew-waters/gannin#520, andrew-waters/gannin#542, andrew-waters/gannin#543]
touches: [andrew-waters/gannin, modelcontextprotocol/swift-sdk]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-11-02
requirement: requirements/give-gannin-an-mcp-server-so-claude-can.md
---

# Gannin MCP server for Claude results

Gannin runs an MCP server inside the app so Claude review sessions started on this Mac report their results as tool calls, instead of Gannin parsing JSON out of the transcript.

## Requirement

In full in [requirements/give-gannin-an-mcp-server-so-claude-can.md](../requirements/give-gannin-an-mcp-server-so-claude-can.md).

**Problem:** Gannin asks Claude to end a PR review with a fenced JSON block, then SessionTranscript.lastJSON/review parse the last reply. Once Gannin has read a review it keeps it (CodeSession.reviewResult, PairReview.claudeFindings, review records), but it only ever looks at the last reply: if someone asks Claude another question before Gannin has read the JSON (a poll gap, Gannin closed, a long transcript), the earlier reply is never looked at and the review is missed. A missing or unclosed fence, or an object that fails to decode, also yields no review, and an empty findings list looks like a review that found nothing. ReviewResult's lenient decoding grows with every new field.

**Goal:** Claude reports review results to Gannin directly, and Gannin shows them without parsing returned JSON.

**Who it's for:** People using Gannin's PR reviews; developers maintaining the review and session code.

**Scope:**

1. The built-in pair review: the Claude reviewer session started when someone works on an issue (SessionStore.reviewRequested / startHelper) reports its findings to Gannin as a tool call.
2. Claude's PR review sessions (manual and auto review) report their results through the same server, so both review paths stop depending on the last reply being JSON.

**Out of scope:**

- Reviews in a sandbox container or on a server over ssh: they keep the JSON path in this version, because a server on this Mac may not be reachable from them.
- Junie. It is the only ExtraReviewer today, runs as a one-shot CLI in a throwaway copy, and stays on the JSON path.
- Other results Claude writes (refine.json, the planning state file) are not named by the room so far.

**Acceptance criteria:**

- **R1** When Gannin starts a Claude review session on this Mac outside a sandbox or server (a pair reviewer, or a manual or auto PR review), the system shall make an MCP server available that the session can call.
- **R2** When a review session reports its findings through the server, the system shall show them as that review's result without reading them from the transcript.
- **R3** When someone asks the review session another question before Gannin has read its report, the system shall still show the report, whichever reply it was in.
- **R4** When a review session reports no findings, the system shall record that as a completed review with none, distinct from a session that has not reported.
- **R5** When a report is malformed, the system shall reject the call with a message Claude can act on, and shall not show a partial review.
- **R6** When a review session finishes without having reported through the server, the system shall fall back to reading the last JSON block as it does today.
- **R7** When a review runs in a sandbox, on a server over ssh, or as a Junie one-shot, the system shall keep using the JSON path unchanged.
- **R8** While the server is running, the system shall accept calls only from sessions Gannin started, and each call shall be attributed to the session that made it.
- **R9** When this ships, the review pages under docs-site/src/content/docs/agents/ (pair-review.md, reviews.md, auto-review.md) shall say how a review's result arrives and what happens when Claude doesn't report, and CHANGELOG.md shall have an Unreleased line.

**Decisions:**

- What is the real pain with the JSON hand-back today? **Missed reviews. Gannin reads the last reply of the transcript, so when someone asks Claude another question after the review, the latest reply isn't JSON and Gannin loses the review. Parser upkeep is secondary.**
- What is in scope for the first version? **Review, covering the built-in review when you 'work on this' (the pair reviewer), plus extra reviewers but excluding Junie. Junie is the only extra reviewer in the code today, so that adds nothing to build now.**
- Do PR review sessions (manual and auto review) join the pair review in scope? **Both reviews.**
- Where must reporting by tool call work in the first version? **Local sessions first. Sandbox and ssh reviews are left for later.**
- When a local review session can't use the tool (server down, Claude doesn't call it, malformed call), what does Gannin do? **Keep the JSON reader as a fallback.**
- A read review is already saved and the earlier JSON is still in the transcript, so should the plan cover the server for the whole problem, a cheap read-earlier-replies fix first, or only that fix? **Server for the whole problem. The requirements stand, with R3 reworded: the loss is a follow-up reply landing before Gannin has read the report.**

## Design

**Proposal (draft: the room chose an HTTP server inside Gannin; the rest is for the room to confirm).**

- **Server:** an MCP server inside Gannin built on the official Swift SDK (`modelcontextprotocol/swift-sdk`, product `MCP`, release 0.12.1, pinned with `minorVersion` like SwiftTerm in `project.yml` because pre-1.0 minors may break). The SDK supplies `Server`, the JSON-RPC and tool types and `StatelessHTTPServerTransport`, which is exactly the simplest Streamable HTTP form: `POST` carrying JSON-RPC, one JSON reply, `GET` and `DELETE` answered 405, no `Mcp-Session-Id`. The SDK does not listen on a port: its transport's `handleRequest(HTTPRequest) -> HTTPResponse` is for the app's own HTTP layer, and its NIO dependency is only used by its conformance executable. So Gannin adds a thin loopback listener (`NWListener` on `127.0.0.1`, a port the system picks at launch) that reads one HTTP/1.1 request per connection, hands it to the transport and writes the reply. Nothing in Gannin listens today, so that listener (framing, a body-size limit, timeouts, shutdown) is the one piece of new code with no pattern to copy. Keep it in its own files, apart from `SessionStore`.
- **Two tools, because the two reviews report in different formats today.** The pair reviewer ends with a bare list of findings (`[{path, line, comment}]`, where `[]` means nothing found; `SessionTranscript.listedFindings`), and has no summary or verdict. A PR review returns a `ReviewResult` object (`summary` required, `verdict`, `findings[]`, and the optional `resolved`, `learnings`, `applied`, `headline`, `effort`, `walkthrough`, `flow`, `checks`). So `report_findings` takes `{findings: [...]}` (an object, as MCP tool input must be, with `findings` required and allowed to be empty) and `report_pr_review` takes the `ReviewResult` shape. `tools/list` offers a session only the tool for its kind, found from its token (a pair reviewer sees `report_findings`; a PR review or workflow step sees `report_pr_review`), each with a JSON schema so Claude fills it correctly, and a call to the other is rejected. Each tool is the one place that decides whether its report is well formed.
- **Connecting a session (R1, R7):** when `SessionStore.launch` starts a session that is a reviewer or a PR review, local, not sandboxed and not remote, it writes an MCP config beside the session's `settings.json` (named per session like `SessionScript.settingsName`) and `ClaudeCodeProvider.options` adds `--mcp-config <file>`. The config declares one server, `gannin`, with `"type": "http"`, the loopback URL and an `Authorization: Bearer <token>` header. The docs confirm the `http` type and static `headers`; whether `--mcp-config` takes a file path and whether it skips the project-server approval prompt weren't confirmed from the docs, and `claude --help` couldn't be run here, so the first step of the task is a spike that proves a real session connects.
- **Who can call (R8):** Gannin makes a random token per session at launch, keeps token to session id in memory, and returns 401 for any other, checked in the listener before a request reaches the SDK. The tool handler also reads the header from `Server.currentHandlerContext?.httpContext` (the SDK sets it for each handler call) to learn which session is calling. The server only takes loopback connections. A call's session is the token's session, never something Claude names. Anyone who can read the session's config file (the same user) can call as that session; that is the same trust the hook files already have.
- **Reading a report (R2, R3, R4):** a valid call decodes into `SessionTranscript.ReviewResult` and goes to one main-actor entry point on `SessionStore`, which routes it the way the transcript's result is routed today in `store(_:for:moreToRead:)`: a workflow step goes to `stepResult`; a PR review sets `reviewResult` and calls `reviewFinished`; a pair reviewer's `report_findings` goes to `PairReview.claudeAnswered` (the extras' merge is unchanged), then `finishRoundIfReady`. These are saved with the session already, so the report is on disk as soon as it's accepted and does not depend on which reply it was in. A report with an empty `findings` is a finished review with none. A pair round is counted once per accepted call (a call ID kept in `PairReview.lastReply`, so a repeated call after the round ended is ignored).
- **Tool over transcript:** once a session has reported through the tool, its transcript's JSON is ignored for that session (a persisted flag on `CodeSession`), or a reviewer that also prints the JSON would count twice. A session that never reported keeps the existing path (R6): `SessionTranscript.review` and `listedFindings` stay as they are.
- **Malformed calls (R5):** a `report_pr_review` call missing `summary` or `findings`, a `report_findings` call missing `findings`, or either with a finding lacking `path` or `comment`, returns a tool result with `isError: true` and a message naming the field, so Claude can call again. Nothing is stored. Optional fields keep their lenient decoding, as `.claude/rules/sessions-review.md` requires, so one bad learning never loses the review.
- **Prompts and permissions:** the pair reviewer's prompts (`reviewPrompt` and the look-again prompt in `reviewRequested`) tell Claude to call `report_findings`, and the PR review's prompt and the workflow `roundPrompt` tell it to call `report_pr_review`, and to end with the fenced JSON as before only if the tool isn't there. The harness's review instructions (`HarnessLearnings.reviewJSONInstructions`) describe fields to put in the JSON; they need the same wording so learnings and `applied` reach the tool. Reviewer sessions add `--allowedTools` for the one tool their kind gets (`mcp__gannin__report_findings` or `mcp__gannin__report_pr_review`) so an automatic or unattended review doesn't stall on a permission prompt (to be proven in the spike); edits stay disallowed with `--disallowedTools`.
- **Server not up (R6):** if the server can't start (port or `NetworkGate` sealed in the demo build), no config is written and the session starts as today. If a session is configured but can't reach it, the docs say Claude retries a failed HTTP server up to three times at start and then marks it failed, so Claude can't call it and the prompt's JSON fallback applies. A server that goes away mid-session surfaces as a failed tool call, with the same fallback.
- **Restarts:** the port is new each launch, so the MCP config is rewritten on every start and resume (as settings are today). A running terminal is a child of Gannin and ends when Gannin quits, so a report in flight at quit is lost either way; the JSON fallback covers the resumed session.
- **Confirmed writes:** the tool changes only Gannin's own state in memory and on this Mac. Nothing goes to GitHub from it. Posting a review stays behind the user's confirmation or the automatic-comment rules, so the confirmed-writes list in `.claude/rules/fetching.md` isn't touched; the new rule to record is that nothing may be posted from inside the server.
- **Alternatives considered:** a bundled stdio helper that validates and writes a result file Gannin reads (follows the hook-file pattern and could later be read from a sandbox or over ssh, but needs a second signed executable); and reading the last JSON from any earlier reply (fixes only the follow-up miss).

**Tests:** the MCP messages and validation as plain functions with unit tests (valid, missing field, empty findings, unknown tool, wrong token, a second call after the round); a loopback test that starts the listener on an ephemeral port and calls it with `URLSession`; routing tests beside `PairReviewTests` and `AgentWorkflowsTests` (tool beats transcript, fallback still works, pair round counted once); regenerated `ProviderSnapshotTests` snapshots for review sessions' launch lines.

**Docs and rules:** `agents/pair-review.md`, `agents/reviews.md`, `agents/auto-review.md`; a `CHANGELOG.md` Unreleased line; `.claude/rules/sessions-review.md` (reading claude's output), `sessions-store.md` ("A review keeps its JSON ending"), and `sessions-pair-review.md`. If the server is on by default there is no new Settings control.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L217-L223`: `review` decodes `lastJSON`, the last fenced block of the last reply: why a review is missed when another reply lands before Gannin reads it. Stays as the fallback.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1538-L1558`: `store(_:for:moreToRead:)` is where a transcript's review becomes `reviewResult` (PR review), goes to `stepResult` (workflow step) or `pairRoundRead` (pair). The server's report must enter at the same three places.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L452-L484`: `pairRoundRead` takes the last reply once (`lastReplyID`) and calls `claudeAnswered` then `finishRoundIfReady`; extras (Junie) merge beside it and must still be waited for.
- `andrew-waters/gannin` `Gannin/Agents/ReviewRuns.swift#L382-L401`: `stepResult` ignores a result equal to the last and advances the run: a tool report must go through it for workflow steps.
- `andrew-waters/gannin` `Gannin/Agents/ClaudeCodeProvider.swift#L85-L110`: `options(session)` builds claude's flags (`--disallowedTools`, `--settings`); `--mcp-config` and `--allowedTools` for reviewers go here.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1013-L1077`: `launch` writes `settings.json` and `start.sh` for a local session on every start and resume: the MCP config is written beside them, for local non-sandboxed reviewers only.
- `andrew-waters/gannin` `Gannin/Sessions/SessionActions.swift#L583-L596`: `reviewPrompt` asks for the fenced JSON; the PR review, workflow round and pair look-again prompts say the same and all change together.
- `andrew-waters/gannin` `Gannin/Harness/HarnessLearnings.swift#L158-L160`: `reviewJSONField` / `reviewJSONInstructions` tell the reviewer which JSON fields to add for learnings; they must point at the tool's fields too.
- `modelcontextprotocol/swift-sdk` `Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift`: POST-only JSON replies, GET/DELETE 405, default validation of localhost Origin, Accept (JSON only), Content-Type and protocol version; `handleRequest` takes the app's parsed HTTP request. Handlers see the request's headers through `Server.currentHandlerContext`.
- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L197-L215`: The pair reviewer's format: `listedFindings` reads a bare list of `{path, line, comment}` from the last reply, nil meaning no answer yet and `[]` meaning nothing found. A PR review's format is `ReviewResult` (L88-L110). The tools mirror these two.

**Patterns to follow:**

- `andrew-waters/gannin` `.claude/rules/sessions-core.md`: Session state comes from hook files, never from terminal escape codes. An in-app listener is a new channel beside that; keep it for review reports only.
- `andrew-waters/gannin` `project.yml#L7-L21`: Packages are declared here and pinned (SwiftTerm by minorVersion, Sparkle and HighlighterSwift by from). The MCP SDK joins them, pinned by minorVersion.

**Risks:**

- `andrew-waters/gannin` `Gannin/App/NetworkGate.swift`: The demo build seals network use; the server must not start there.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift`: No listener exists in Gannin today (nothing uses Network.framework's NWListener), so the server's HTTP framing, limits (body size, timeouts, one connection per call) and shutdown are new and need their own tests. The app isn't sandboxed, so no entitlement is needed for loopback.
- `andrew-waters/gannin` `GanninTests/ProviderSnapshotTests.swift`: Claude's start scripts and settings are pinned byte for byte (sessions-core.md): the launch change must regenerate snapshots on purpose.
- `andrew-waters/gannin` `.claude/rules/sessions-review.md`: Reviews run with edits disallowed and the review is read leniently so one malformed entry never loses it. The tool must keep both and still reject a report missing required fields.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift`: Not verified: whether the Claude CLI's `--mcp-config` takes a file path, skips the approval prompt for its servers, and lets `--allowedTools mcp__gannin__report_findings` (or `report_pr_review`) pre-approve the tool. The MCP docs page didn't confirm these and `claude --help` was blocked by the sandbox here; the task starts with a spike.
- `modelcontextprotocol/swift-sdk` `Package.swift`: Swift tools 6.1 and macOS 13+ (Gannin targets macOS 26, CI uses latest-stable Xcode, so fine). The library pulls swift-system, swift-log and eventsource; the manifest also depends on swift-docc-plugin at `branch: main`, which SwiftPM may refuse for a versioned dependency: the spike must resolve and build it. Pre-1.0, so minor releases can break; the README's install snippet says 0.11.0 while 0.12.1 is the latest release.
- `modelcontextprotocol/swift-sdk` `Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift#L52-L72`: The default pipeline's OriginValidator.localhost and AcceptHeaderValidator(.jsonOnly) were not read: Claude Code's request must pass them, or Gannin supplies its own pipeline (with the bearer-token check as a validator).

**Decisions:**

- Which transport should the server use? **An HTTP server inside Gannin (not a bundled stdio helper writing a result file).**
- Hand-written MCP on Network.framework, or the Swift MCP SDK? **The Swift MCP SDK, once checked that it supports the use case. Checked from its repository: it has a server, a stateless HTTP transport and per-request header access, but no listener, so Gannin adds a thin loopback listener. Whether a real Claude Code session connects to it is for the spike.**
- Is one report tool right for both reviews? **No: the pair reviewer's output (a bare list of findings, `[]` for none, no summary) is a different format from a PR review's (a ReviewResult object with a required summary). Two tools, `report_findings` and `report_pr_review`, each offered only to the kind of session it is for.**

## Tasks

1. [andrew-waters/gannin#542](https://github.com/andrew-waters/gannin/issues/542) Run an MCP server in Gannin that local review sessions connect to (satisfies R1, R5, R7, R8)
2. [andrew-waters/gannin#543](https://github.com/andrew-waters/gannin/issues/543) Take review results from the MCP server, keeping the JSON reader as a fallback (satisfies R2, R3, R4, R6, R7, R9)

**Decisions:**

- How should the work be split into issues? **Two tasks in andrew-waters/gannin: the MCP server and local launch wiring (spike first), then routing reports into pair review and PR review with the JSON fallback. The docs, changelog and rules go in the second task's pull request, as the project's working rules require.**

## From the room

- Review + extra reviewers, but excluding Junie (requirements)
- There's the built-in review when you "work on this" (requirements)

## Open questions

- How often does the JSON path fail today, and what does it cost? (Not measured; no incident is linked to the issue.)
- Spike to settle before building: does a real Claude Code session connect to the SDK's stateless transport (its Accept and Origin checks, its GET and DELETE 405s), does `--mcp-config` take a file and pre-approve `mcp__gannin__report_findings` and `mcp__gannin__report_pr_review`, and does SwiftPM resolve the SDK, whose manifest depends on swift-docc-plugin at `branch: main`?
