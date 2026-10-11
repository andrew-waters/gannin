---
type: plan
status: in-progress
summary: "The review tab's header squeezes the repo and PR reference into a thin column because it shares one row with every control. Split it into a title/reference row and a wrapping controls row, with a fixed slot for the status."
issues: [andrew-waters/gannin#241]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-11
requirement: requirements/text-above-the-diff-on-the-pull-request.md
---

# Text above the diff on the pull request review screen is shown in a long, thin column that gets narrower on re-review

The review tab's header squeezes the repo and PR reference into a thin column because it shares one row with every control. Split it into a title/reference row and a wrapping controls row, with a fixed slot for the status.

## Context

- CleanShot 2026-10-11 at 14.19.36@2x.png (shared in the session, not committed)

## Requirement

In full in [requirements/text-above-the-diff-on-the-pull-request.md](../requirements/text-above-the-diff-on-the-pull-request.md).

**Problem:** On the PR review tab, the header above the diff shows the repo and PR reference (e.g. andrew-waters/gannin#224) squeezed into a column a few characters wide, broken mid-word, while the row has room. It changes once the diff loads and gets narrower on re-review.

**Goal:** The header uses the available width, looks the same before and after the diff loads, and keeps its width across re-reviews.

**Who it's for:** Anyone reviewing a pull request in Gannin's review tab.

**Scope:**

1. Review tab header only: title, repo and PR reference, author, +/- lines, files, state
2. Wrap at item boundaries when the window is narrow
3. Stable layout while the diff loads and across re-reviews

**Out of scope:**

- Other PR headers (drawer, window)
- The diff itself
- Redesigning what the header shows

**Acceptance criteria:**

- **R1** When the review tab header is shown, the system shall give the repo and PR reference its natural width before any other item in the row.
- **R2** When the window is too narrow for the row on one line, the system shall wrap at item boundaries and never break the reference mid-word or mid-number.
- **R3** When the diff finishes loading, the system shall leave the header's layout and width unchanged.
- **R4** When the review is run again, the system shall leave the header's layout and width unchanged, however many times it is re-run.
- **R5** The change shall be limited to the review tab's header, with no docs change.

**Decisions:**

- What should the repo and PR reference do when the window is too narrow for one line? **Wrap at sensible points, never mid-word or mid-number.**
- How far should the fix reach? **Review tab header only.**
- Does the change need a user docs update? **No docs change.**

## Design

**Cause.** In `Gannin/Sessions/PullRequestReview.swift`, `PullRequestReviewView.header` (around line 880) puts the title/reference column, a `Spacer` and every control (status, Conversation, Open on GitHub, Explain, Review Again, Posted link, Watch, Finish/Resume, Post Review) in one `HStack`. The title column has no layout priority, so it gets only what the controls leave. The loaded diff (`pullRequest` set) and re-review (a working status up to 260pt wide, the Posted link) change the controls' widths, which explains both symptoms.

**Approach.** Split the header into two rows. Row 1 is the title and the reference label with the meta items (author, +/-, files, state) in a wrapping layout, so the reference gets its natural width first and the rest wraps below it. Row 2 is the status and action controls in their own wrapping layout, so they drop down on a narrow window instead of squeezing the title. Put the status in a fixed-size slot so its changing text cannot shift anything. Reuse `WrappingStack` (`ReviewOverview.swift`) or `FlowRow` (`BoardLayouts.swift`); `ViewThatFits` is also used in `ActionsPages.swift` and `DetailViews.swift`.

**Checking.** Build and run with `scripts/relaunch.sh`, then look at a loading diff, a loaded diff and repeated Review Again at wide and narrow widths. No UI test exists for this header, so none is added.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Sessions/PullRequestReview.swift#L880-L990`: PullRequestReviewView.header: one HStack holds the title/reference VStack, a Spacer and all controls; the title column has no layout priority.
- `andrew-waters/gannin` `Gannin/Sessions/PullRequestReview.swift#L1000-L1025`: status(state:transcript:hasReview:) changes between Finished, Posted, Not running, a working label up to 260pt wide, Needs you and Review ready, so its width varies during a re-review.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Sessions/ReviewOverview.swift#L589`: WrappingStack is an existing wrapping Layout in the review code, a candidate to reuse.
- `andrew-waters/gannin` `Gannin/Projects/BoardLayouts.swift#L284`: FlowRow is another existing wrapping Layout; ViewThatFits is used in ActionsPages.swift and DetailViews.swift.

**Risks:**

- `andrew-waters/gannin` `Gannin/Sessions/PullRequestReview.swift`: The header is shown above an HSplitView and VSplitView; a taller wrapped header changes the space left for the diff, so check narrow widths. STANDARDS.md and plans/_template.md were not found in this checkout.

**Decisions:**

- Is the design right: two rows with a wrapping controls row and a fixed status slot? **Yes.**

## Tasks

1. Split the review header into a title/reference row and a wrapping controls row
2. Give the header's status a fixed-size slot so loading and re-review do not move anything
3. Add the changelog entry and confirm no docs page needs changing

**Decisions:**

- Are the three tasks right? **Yes, the plan is ready.**
