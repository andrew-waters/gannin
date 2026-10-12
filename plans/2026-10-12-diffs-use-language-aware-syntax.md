---
type: plan
status: in-progress
summary: "Highlight code in the PR review screen's diffs by file language, with added and removed lines shown by the gutter, and plain diffs for unsupported files."
issues: [andrew-waters/gannin#258, andrew-waters/gannin#263, andrew-waters/gannin#264, andrew-waters/gannin#265, andrew-waters/gannin#266]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-12
requirement: requirements/diffs-use-language-aware-syntax.md
---

# Diffs use language-aware syntax highlighting

Highlight code in the PR review screen's diffs by file language, with added and removed lines shown by the gutter, and plain diffs for unsupported files.

## Requirement

In full in [requirements/diffs-use-language-aware-syntax.md](../requirements/diffs-use-language-aware-syntax.md).

**Problem:** Reviewers reading a diff on the PR review screen see code without language colouring, which makes changes harder to scan and review.

**Goal:** Diffs on the PR review screen are highlighted by the language of each file.

**Who it's for:** People reviewing pull requests in Gannin.

**Scope:**

1. PR review screen diffs only
2. Language chosen from file extension for a common set: Swift, TypeScript/JavaScript, Go, PHP, Python, JSON, YAML, Markdown, shell
3. Unsupported files show as plain diffs
4. Added/removed shown by the gutter marker and a lighter tint, syntax colours on the line text

**Out of scope:**

- Session changes and Repositories diffs
- A setting to turn highlighting off
- Theme choice
- Detecting language from file content
- Languages beyond the common set

**Acceptance criteria:**

- **R1** When a pull request's diff is shown on the PR review screen, the system shall highlight the code in each file according to the language of that file, chosen from its file extension.
- **R2** When a file's extension is not in the supported set (Swift, TypeScript/JavaScript, Go, PHP, Python, JSON, YAML, Markdown, shell), the system shall show it as a plain, readable diff, as today.
- **R3** When highlighting is on, the system shall show added and removed lines by the gutter marker and a lighter tint, with syntax colours applied to the line text.
- **R4** When highlighting is on, the system shall keep added, removed and unchanged lines clearly distinguishable in both light and dark appearance.
- **R5** While a large diff is shown, the system shall keep the PR review screen responsive, skipping highlighting for files over a size cap.
- **R6** The PR review guide page in docs-site (agents/reviews.md) shall describe highlighted diffs and the supported languages, and CHANGELOG.md shall gain an [Unreleased] line.

**Decisions:**

- Where do people hit this most? **The PR review screen.**
- What is the smallest version worth shipping first? **PR review screen only.**
- Which languages must v1 highlight, and what happens to others? **A common set chosen by file extension; other files show as plain diffs.**
- How should syntax colours sit alongside added/removed styling? **Tint only the +/- gutter; syntax colours on the line text.**
- Which user docs pages change? **The PR review guide page (agents/reviews.md).**

## Design

1. `DiffLanguage` maps a path's extension or special filename (e.g. Dockerfile) to a highlight.js language in the supported set, else nil.
2. `DiffHighlighter` wraps HighlighterSwift (SwiftPM). For each hunk it highlights the new side (context + added lines) and the old side (context + removed lines) as two blocks, strips the leading +/-/space marker from the text it hands the highlighter (so the marker isn't read as code), and returns an AttributedString per DiffLine.ID for the line without its marker; `DiffRow` still draws the marker itself, in the gutter. Light or dark theme follows the appearance. Returns nil over a size cap.
3. `ReviewDiff` (Sessions/PullRequestReview.swift) computes highlights off the main actor and passes each `DiffRow` an optional AttributedString; nil means a plain row, so unsupported or still-loading files look as today.
4. `DiffRow` draws the attributed text; its row-wide green/red tint becomes a gutter/marker tint. `DiffStyle` (Git/GitDiff.swift) is untouched, so session changes and Repositories diffs are unchanged.
5. `GitDiff.lineLimit` (4000) already bounds the work; the size cap covers very long lines.
6. Docs: agents/reviews.md and CHANGELOG.md.

Risks: HighlighterSwift may not build under Swift 6 with MainActor default isolation (checked in task 1, with its licence); theme colours must stay readable against the gutter tint in light and dark; a hunk that starts mid-comment or mid-string can mis-colour (accepted for v1).

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/PullRequestReview.swift#L1479-L1716`: ReviewDiff renders each file's lines with DiffRow, which draws line.text as plain Text and has its own private background(_:) tint. This is where highlighting lands.
- `andrew-waters/gannin` `docs-site/src/content/docs/agents/reviews.md`: The PR review guide page to update; CLAUDE.md requires docs and a CHANGELOG [Unreleased] line in the same PR.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Git/GitDiff.swift#L5-L128`: DiffLine (kind, text with leading marker, line numbers), GitDiff.lines with lineLimit 4000, and DiffStyle shared by the session pane and repo page. Leave DiffStyle alone to keep other views unchanged.

**Risks:**

- `andrew-waters/gannin` `project.yml#L7-L36`: Only SwiftTerm (pinned to 1.20 for a stated reason) and Sparkle are packages today; a new package needs to build under Swift 6 with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
- `andrew-waters/gannin` `.claude/rules/sessions-review.md`: Only PairReviewTests touches review code; add tests for the language mapping and highlighter beside it. Rule: comments are only placed on lines the diff shows, so DiffLine ids and anchors must not change.

**Decisions:**

- How should highlighting be done? **HighlighterSwift.**
- How much text does the highlighter see at once? **Per hunk, as separate old and new sides.**
- Why drop the +/- on diffs? **They aren't dropped from the screen: they are stripped only from the text given to the highlighter so they aren't read as code, and DiffRow still draws them in the gutter.**

## Tasks

1. [andrew-waters/gannin#263](https://github.com/andrew-waters/gannin/issues/263) Add HighlighterSwift and DiffLanguage (satisfies R1, R2)
2. [andrew-waters/gannin#264](https://github.com/andrew-waters/gannin/issues/264) Add DiffHighlighter (satisfies R1, R4, R5)
3. [andrew-waters/gannin#265](https://github.com/andrew-waters/gannin/issues/265) Show highlighted diffs on the PR review screen (satisfies R1, R2, R3, R4, R5)
4. [andrew-waters/gannin#266](https://github.com/andrew-waters/gannin/issues/266) Document highlighted diffs (satisfies R6)

## From the room

- Why drop the +/- on diffs? (agree)
