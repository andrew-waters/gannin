---
type: plan
status: in-progress
summary: "Let a pair review also run Junie, as a built-in extra-reviewer preset, alongside the claude reviewer. Turned on per project on this Mac, off by default, local sessions only."
issues: [andrew-waters/gannin#420, andrew-waters/gannin#422, andrew-waters/gannin#423, andrew-waters/gannin#424, andrew-waters/gannin#425]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-20
requirement: requirements/add-jetbrains-junie-as-an-additional.md
---

# Junie as an additional pair reviewer

Let a pair review also run Junie, as a built-in extra-reviewer preset, alongside the claude reviewer. Turned on per project on this Mac, off by default, local sessions only.

## Requirement

In full in [requirements/add-jetbrains-junie-as-an-additional.md](../requirements/add-jetbrains-junie-as-an-additional.md).

**Problem:** A pair review has one reviewer, a second claude session. Two claude sessions share blind spots, and a team can't get a second opinion from a different model family (or from JetBrains Junie, which some use already).

**Goal:** A pair review can also use Junie as an extra reviewer, with both reviewers' findings sent back to the working agent together.

**Who it's for:** People running pair reviews who want a second opinion from a different model family than claude.

**Scope:**

1. A per-project setting (a project is a harness plus its code repos), kept on this Mac, turns on extra reviewers from built-in presets; none on by default; Junie is the only preset
2. Each round runs the claude reviewer and every enabled extra reviewer and merges their findings
3. An extra reviewer runs as a one-shot process in a throwaway copy of the worktree
4. Local sessions only
5. Each finding shows which reviewer raised it

**Out of scope:**

- Replacing the claude reviewer
- User-defined reviewer commands: adding an agent is a code change
- Presets other than Junie in this version
- Other agents as the working agent, or for auto review, planning, Ask or Quick Change
- Installing or signing in to Junie for the user
- Sharing the setting with the team through the harness
- A per-repository or app-wide setting

**Acceptance criteria:**

- **R1** When a user opens a project in Org settings › Projects, the system shall offer a Junie reviewer toggle for pair reviews, off by default, kept on this Mac.
- **R2** When a pair review round runs in a session of a project with the Junie reviewer on, the system shall run the claude and Junie reviewers and send their findings to the working agent together, within the existing three-round limit.
- **R3** When Junie runs a review, the system shall run it in a throwaway copy of the session's worktree and discard any change it makes, so the session's worktree is never edited by it.
- **R4** When a session is sandboxed or remote, the system shall show the Junie reviewer as unavailable for it and say why.
- **R5** When Junie is missing, signed out or fails, the system shall report that on the session's panel and still complete the claude reviewer's round.
- **R6** When findings are shown or sent back, the system shall show which reviewer raised each one.
- **R7** When the Junie reviewer is off, the system shall run pair review exactly as it does today.
- **R8** The system shall have tests that cover reading Junie's findings and merging two reviewers' findings.
- **R9** The docs shall change: agents/pair-review.md (the extra reviewer, how to turn it on, what Junie needs, local only) and settings/org/projects.md (the toggle, its default and that it's kept on this Mac), with an Added line under Unreleased in CHANGELOG.md.
- **R10** .claude/rules/sessions-pair-review.md shall record how more than one reviewer is tracked and what a reviewer agent must provide.

**Decisions:**

- Who is asking for a Junie reviewer, and what does a single claude reviewer cost them? **The aim is a second opinion from a different model family; two claude sessions share blind spots.**
- What's the smallest version worth shipping? **Any CLI reviewer was picked, then narrowed by the next two answers to built-in presets with Junie only.**
- How should a generic CLI reviewer be defined? **Built-in presets only: Gannin has code for each CLI's flags and output, so adding an agent is a code change. No user-defined commands.**
- Which presets ship in the first version? **Junie only, the one that's been spiked. The preset mechanism is built so a second CLI is a later, separately spiked change.**
- Where should the extra-reviewer setting live? **Per project (a harness plus its code repos), in Org settings › Projects. Revisited: it was per repository, and before that the issue implied one app-wide setting in settings/app/general.md. A session belongs to one project's harness, so which repo decides is no longer a question.**
- Where is a project's extra-reviewer setting kept? **On this Mac, with which harnesses are your projects (on `HarnessConfig`), not in the harness. Confirmed again for the per-project setting.**
- Which user-docs pages change? **agents/pair-review.md and settings/org/projects.md. Revisited: it was settings/org/repositories.md while the setting was per repository; it changed when the setting moved to projects.**

## Design

**Setting.** A project is a `HarnessConfig` (the user's own list in `OrgConfig`: `harness` and `otherHarnesses`, kept on this Mac). Add an optional `junieReviewer: Bool?` to `HarnessConfig` (nil means off, so saved configs still decode), set through the existing `OrgConfigStore.updateHarness(_:_:)`, with a `Junie reviewer` toggle in Org settings › Projects (`ProjectsSettingsSection` in `Workload/RepoProjects.swift`), in the project's Harness section beside Branch. Not written to the harness, so it's not shared (the earlier decision). A session's project is the harness it runs in, `CodeSession.harnessRepo`, so there's no 'which repo decides' question; a session with no `harnessRepo` (made before harnesses) gets no Junie.

**Tracking more than one reviewer.** `PairReview` keeps `reviewerID` for the claude reviewer as it is, and gains `extras: [String: ExtraReview]` keyed by preset id (`junie`). `ExtraReview` holds its state for the current round (`running`, `answered(findings)`, `failed(message)`), and is reset when a round starts. `pairRoundRead` (claude's reply read from its transcript) no longer calls `finishRound` straight away: it records claude's findings, and the round finishes only once every extra that started this round is answered or failed. Both claude's reply and each extra completing call one shared `finishRoundIfReady(parent)`, so the order they arrive in doesn't matter and the round finishes exactly once. A failed extra counts as having answered with nothing and records its message in `PairReview` for the panel (R5), so claude's round still goes ahead. Optional fields only, so `PairReview` already saved decodes.

**Running Junie.** A new `ExtraReviewer` type (an enum with the one case `junie`) owns the preset: its command line, how it reads the result and how it's named. `SessionStore.reviewRequested` starts it alongside the claude reviewer's prompt when the session's project has it on and the session is local (no `sandbox`, no `connect`). It copies the session's worktree folder to a temp directory (everything under `SessionStore.worktree(for:)`, the harness `.worktrees/<branch>` included), runs `junie --project <copy> --output-format json --json-output-file <file> --timeout 600000 --skip-update-check "<prompt>"` (ten minutes) through `ClaudeRunner.run(_:place: .local)` (which runs in the user's login shell, so `~/.local/bin` is on `PATH`), reads the file's `result`, takes the findings list from it with `ClaudeRunner.json`, and deletes the copy whatever happens. Gannin also stops waiting at ten minutes plus a short grace, ends the process and counts Junie as failed ('timed out'), so a hung Junie can't hold the round; claude's findings then go on alone. The prompt is `reviewPrompt` plus the same ending rule (fenced JSON list, `[]` when nothing's left). Junie's own flags are not relied on for no-edit (spike: `--plan` still edited); the throwaway copy is the control (R3).

**Merging and attribution.** `SessionTranscript.Finding` gains an optional `reviewer: String?` (nil for claude's, so existing records are unchanged). `findingsPrompt` merges both lists, drops exact `path`/`line`/`comment` duplicates, and labels each line with its reviewer only when an extra took part, so the prompt with Junie off is byte-for-byte what it is today (R7). `PairReviewSection` gets a Junie row showing whether it's running, answered, failed (with why) or unavailable for a sandboxed or remote session (R4).

**Tests.** `PairReviewTests` gets cases for: parsing Junie's JSON output file (result with a fenced list, empty list, no list, malformed), merging two lists with duplicates and attribution, a round waiting for Junie before finishing, and a failed Junie letting claude's round finish. The runner takes the process call as a closure so none of it needs Junie installed.

**Docs and rules.** `agents/pair-review.md`, `settings/org/projects.md` (the label must match the pane, for `check-settings.mjs`), a CHANGELOG line, and `.claude/rules/sessions-pair-review.md` (how extras are tracked, that a round waits on every extra that started and a failed one doesn't block, and what a reviewer must return: the fenced JSON findings list).

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L10-L84`: `PairReview` has a single `reviewerID`, one `Phase`, and `finishRound(findings:reply:)`, which takes a count. It needs to hold per-reviewer state and finish only when all have answered.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L134-L199`: `reviewRequested` starts or messages the claude reviewer helper; the place to also start extra reviewers.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L251-L287`: `pairRoundRead` finishes the round from the claude transcript and `findingsPrompt` formats the findings; both change to use merged, attributed findings.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L311-L341`: `PairReviewSection` is the session panel: where Junie's status, failure and the unavailable-in-sandbox message go.
- `andrew-waters/gannin` `Gannin/Workload/RepoProjects.swift`: `ProjectsSettingsSection` is where Org settings › Projects is drawn (name, repos, boards, harness, branch); the toggle goes in its Harness section.
- `andrew-waters/gannin` `Gannin/Sync/UserDatabase.swift#L127`: `OrgConfig` (and so `HarnessConfig`) is saved in SwiftData on this device only: `cloudKitDatabase: .none`, as `fetching.md` says. Comments elsewhere still say 'synced', which is stale. So the toggle never leaves this Mac, and a Mac without Junie never has it switched on by another.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Metrics/OrgConfigStore.swift#L142-L175`: A project's own, this-Mac settings live on `HarnessConfig` (`harness`, `otherHarnesses`) and are changed with `updateHarness(_:_:)`; the Junie flag follows that.
- `andrew-waters/gannin` `Gannin/Sessions/ClaudeRunner.swift#L131-L209`: `ClaudeRunner.run` runs a script in the user's login shell (so `~/.local/bin` is on PATH, as the spike needed) and `ClaudeRunner.json` extracts a fenced JSON list from a reply; both reused for Junie.
- `andrew-waters/gannin` `GanninTests/PairReviewTests.swift`: Existing loop tests (`roundWithFindingsGoesBackToBeFixed`, `roundWithNothingSettles`, `findingsPromptSaysWhatsNext`) are the template for new merge and gating tests.
- `andrew-waters/gannin` `Gannin/Sessions/SessionTranscript.swift#L63-L74`: `Finding` is shared with PR reviews and is Codable and persisted in `reviewResult`; a new field must be optional so saved sessions decode.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L134-L170`: A round must not hang: if the claude reply arrives but Junie never finishes, or Junie finishes first, the round has to finish exactly once. Needs a timeout and a single 'ready' check.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1646-L1655`: The worktree folder may be large (harness `.worktrees/<branch>` holds a worktree per repo) and a worktree's `.git` is a file pointing at the main clone; the copy's behaviour without a usable `.git` wasn't checked in the spike.
- `andrew-waters/gannin` `Gannin/Sessions/PairReview.swift#L134-L199`: Junie loads the user's own MCP servers and agent files, some of which can write outside the copy. The throwaway copy only protects the session's worktree, not other state; the docs should say so.
- `andrew-waters/gannin` `docs-site/src/content/docs/settings/org/projects.md`: `docs-site/scripts/check-settings.mjs` fails CI when a pane control label isn't on its page, so the new toggle's label and the page must change in the same PR.

**Decisions:**

- How long does a round wait for Junie? **Ten minutes, then it's reported on the panel as failed and claude's findings go back alone.**

## Tasks

1. [andrew-waters/gannin#422](https://github.com/andrew-waters/gannin/issues/422) Add a per-project Junie reviewer toggle in Org settings › Projects (satisfies R1, R9)
2. [andrew-waters/gannin#423](https://github.com/andrew-waters/gannin/issues/423) Tag each finding with its reviewer and merge two reviewers' findings (satisfies R6, R7, R8)
3. [andrew-waters/gannin#424](https://github.com/andrew-waters/gannin/issues/424) Run Junie once in a throwaway copy of the worktree and read its findings (satisfies R3, R5, R8)
4. [andrew-waters/gannin#425](https://github.com/andrew-waters/gannin/issues/425) Wait for Junie in the pair review round and show its status on the panel (satisfies R2, R4, R5, R6, R7, R8, R9, R10)

## From the room

- We want to revisit "Which user-docs pages change?". We said "agents/pair-review.md and settings/org/repositories.md, not settings/app/general.md.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (design)
- We want to revisit "Which user-docs pages change?". We said "agents/pair-review.md and settings/org/repositories.md, not settings/app/general.md.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- We want to revisit "Which user-docs pages change?". We said "agents/pair-review.md and settings/org/repositories.md, not settings/app/general.md.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- We want to revisit "Which user-docs pages change?". We said "agents/pair-review.md and settings/org/repositories.md, not settings/app/general.md.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- per "project" (requirements)

## Open questions

- Issue #420's decisions and acceptance criteria say Junie-only, one setting and settings/app/general.md; they need updating to match these requirements.
