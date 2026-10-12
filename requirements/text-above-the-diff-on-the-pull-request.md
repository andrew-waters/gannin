---
type: requirement
status: in-progress
summary: "The header uses the available width, looks the same before and after the diff loads, and keeps its width across re-reviews."
issues: [andrew-waters/gannin#241]
plans: [plans/2026-10-11-text-above-the-diff-on-the-pull-request.md]
---

# Text above the diff on the pull request review screen is shown in a long, thin column that gets narrower on re-review

## Problem

On the PR review tab, the header above the diff shows the repo and PR reference (e.g. andrew-waters/gannin#224) squeezed into a column a few characters wide, broken mid-word, while the row has room. It changes once the diff loads and gets narrower on re-review.

## Goal

The header uses the available width, looks the same before and after the diff loads, and keeps its width across re-reviews.

## Who it's for

Anyone reviewing a pull request in Gannin's review tab.

## Requirements

1. Review tab header only: title, repo and PR reference, author, +/- lines, files, state
2. Wrap at item boundaries when the window is narrow
3. Stable layout while the diff loads and across re-reviews

## Out of scope

- Other PR headers (drawer, window)
- The diff itself
- Redesigning what the header shows

## Acceptance criteria

- **R1** When the review tab header is shown, the system shall give the repo and PR reference its natural width before any other item in the row.
- **R2** When the window is too narrow for the row on one line, the system shall wrap at item boundaries and never break the reference mid-word or mid-number.
- **R3** When the diff finishes loading, the system shall leave the header's layout and width unchanged.
- **R4** When the review is run again, the system shall leave the header's layout and width unchanged, however many times it is re-run.
- **R5** The change shall be limited to the review tab's header, with no docs change.

Planned in [plans/2026-10-11-text-above-the-diff-on-the-pull-request.md](../plans/2026-10-11-text-above-the-diff-on-the-pull-request.md).
