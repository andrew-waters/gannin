---
type: requirement
status: in-progress
summary: "Diffs on the PR review screen are highlighted by the language of each file."
issues: [andrew-waters/gannin#258]
plans: [plans/2026-10-12-diffs-use-language-aware-syntax.md]
---

# Diffs use language-aware syntax highlighting

## Problem

Reviewers reading a diff on the PR review screen see code without language colouring, which makes changes harder to scan and review.

## Goal

Diffs on the PR review screen are highlighted by the language of each file.

## Who it's for

People reviewing pull requests in Gannin.

## Requirements

1. PR review screen diffs only
2. Language chosen from file extension for a common set: Swift, TypeScript/JavaScript, Go, PHP, Python, JSON, YAML, Markdown, shell
3. Unsupported files show as plain diffs
4. Added/removed shown by the gutter marker and a lighter tint, syntax colours on the line text

## Out of scope

- Session changes and Repositories diffs
- A setting to turn highlighting off
- Theme choice
- Detecting language from file content
- Languages beyond the common set

## Acceptance criteria

- **R1** When a pull request's diff is shown on the PR review screen, the system shall highlight the code in each file according to the language of that file, chosen from its file extension.
- **R2** When a file's extension is not in the supported set (Swift, TypeScript/JavaScript, Go, PHP, Python, JSON, YAML, Markdown, shell), the system shall show it as a plain, readable diff, as today.
- **R3** When highlighting is on, the system shall show added and removed lines by the gutter marker and a lighter tint, with syntax colours applied to the line text.
- **R4** When highlighting is on, the system shall keep added, removed and unchanged lines clearly distinguishable in both light and dark appearance.
- **R5** While a large diff is shown, the system shall keep the PR review screen responsive, skipping highlighting for files over a size cap.
- **R6** The PR review guide page in docs-site (agents/reviews.md) shall describe highlighted diffs and the supported languages, and CHANGELOG.md shall gain an [Unreleased] line.

Planned in [plans/2026-10-12-diffs-use-language-aware-syntax.md](../plans/2026-10-12-diffs-use-language-aware-syntax.md).
