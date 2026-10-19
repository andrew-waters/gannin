---
type: plan
status: in-progress
summary: "A review whose PR has merged can be finished from its row in the Inbox's While you were away section, without opening it."
issues: [andrew-waters/gannin#411]
touches: [andrew-waters/gannin]
owner: dwrss
---

# Finish a merged Inbox item without opening it

Today a review whose PR has merged stays in the Inbox's While you were away section until its tab is opened and Finish is chosen. Opening it only to finish it is a wasted step.

## Decisions

Made without asking, as this was a scheduled run:

- **Where:** the row's right-click menu, as **Finish Review**. A row button would sit on every row and the Table has no swipe. Row context menus already hold the other row actions.
- **Which rows:** rows whose review's events include the `.stopped` event with text "Merged", which `SessionStore` records when the watch sees the PR merged (`AutoReview.swift`). Only those rows have a review session and a merged PR: Needs your review, Changed since your review and Your pull requests list open PRs only.
- **Same result as opening it:** opening a review calls `activity.markSeen(session:)`, and Finish calls `archiveReview`. The menu item does both, so the row leaves the Inbox and the review goes to the history the same way.
- **Confirmation:** the same "Finish this review?" confirmation as the review page, since Finish ends the reviewer and removes its worktree.
- **Closed but unmerged:** not offered. The issue asks for merged PRs, and a closed PR may be reopened.

## Tasks

- [x] `InboxRow` carries whether its review's PR merged; the While you were away rows set it
- [x] Context menu item Finish Review with a confirmation dialog, calling `markSeen` then `archiveReview`
- [x] `docs-site` Inbox / auto-review page and CHANGELOG line
