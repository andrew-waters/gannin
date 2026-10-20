---
type: plan
status: in-progress
summary: "On a parent issue's page, the activity entry for a sub-issue being added shows the parent's title instead of the sub-issue's, and clicking the title does nothing."
issues: [andrew-waters/gannin#431, andrew-waters/gannin#434, andrew-waters/gannin#435]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-20
requirement: requirements/sub-issue-added-activity-on-an-issue.md
---

# Sub-issue added activity shows the wrong title

On a parent issue's page, the activity entry for a sub-issue being added shows the parent's title instead of the sub-issue's, and clicking the title does nothing.

## Requirement

In full in [requirements/sub-issue-added-activity-on-an-issue.md](../requirements/sub-issue-added-activity-on-an-issue.md).

**Problem:** On the parent issue's page, the 'sub-issue added' activity entry shows the parent issue's title, so a reader can't tell which issue was added. Clicking the title does nothing, so there is no route to the sub-issue from the activity.

**Goal:** The entry names the sub-issue that was added and lets the reader open it in Gannin.

**Who it's for:** Anyone reading an issue's activity in Gannin.

**Scope:**

1. Sub-issue added entry on the parent issue's page shows the sub-issue's title
2. Clicking that title opens the sub-issue's page in Gannin

**Out of scope:**

- The child issue's own page (followed up separately)
- Making titles clickable on other activity entries (follow-up if they share the cause)
- Sub-issue removed entries: the issue timeline doesn't fetch or show them today; showing them is a new feature for a follow-up issue

**Acceptance criteria:**

- **R1** When a sub-issue added entry is shown on the parent issue's page, the system shall show the sub-issue's title, not the parent's.
- **R2** When the user clicks the title in that entry, the system shall open the sub-issue's page in Gannin.
- **R3** When this change ships, no page under docs-site/src/content/docs/ changes, and CHANGELOG.md gains a line under [Unreleased].

**Decisions:**

- Which activity entries are in scope for the smallest version? **Sub-issue added on the parent issue's page. The child's page is left out.**
- Should sub-issue removed entries be fixed too? **No. Scouting showed the timeline has no removed entry (not fetched or drawn); dropped from scope, a follow-up feature.**
- Where should clicking the sub-issue's title go? **The sub-issue's page in Gannin.**
- Should other activity entries that ignore title clicks be fixed too? **No, sub-issue entries only.**
- Which user docs pages change? **None.**

## Design

**Cause.** `IssueTimelineSection.items` builds the sub-issue added entry with the parent's own `IssueRecord` as its subject, and `StandupTimelineList` uses the subject for both the title and the click target. The click therefore navigates to the page already open. The history query reads `SUB_ISSUE_ADDED_EVENT` for `createdAt` only, and `IssueRecord.subIssuesAddedAt` is `[Date]`, so the child is never fetched or stored.

**Approach.**
1. Query: add `subIssue { id number title url repository { nameWithOwner } }` to the `SubIssueAddedEvent` fragment in `RawIssueRecord.fields` (GitHub's GraphQL reference lists `subIssue` (Issue) on `SubIssueAddedEvent`).
2. Model: a new `IssueSubIssueAdded` (at, id, number, title, url, repo) and an optional `IssueRecord.subIssuesAdded: [IssueSubIssueAdded]?`, mirrored in `HistoryIssueExtras` and the `SharedIssueStore` mapping to and from `IssueRecord`. Optional so older caches still load. `subIssuesAddedAt` stays as it is, since scope-creep metrics read it.
3. Timeline: `StandupItem.Kind.subIssueAdded` carries an optional `IssueReference` for the child. `IssueTimelineSection.items` builds one entry per stored child; `StandupTimelineList.title` returns the child's title and `page` returns `.issueReference(child)`, so the existing `navigate` and `opensElsewhere` behaviour opens it. The title is looked up live in the issue history by child ID when held (so a rename shows), else the stored one.
4. Migration: bump `IssueHistory.currentVersion` to 2. `IssueStore.loadCached` ignores a history whose version differs, so the next sync fetches every issue again and each one's history slot gets its children (`SharedIssueStore` replaces a slot with one fetched at least as recently, and a refetch is at the same `updatedAt`). A record that still has dates but no child (an issue whose refetch failed) reads 'Sub-issue added' with no link, never the parent's title.
5. Tests (Swift Testing): the query's decoding into `subIssuesAdded`, the `HistoryIssueExtras` round trip with and without the field, that a history saved at version 1 isn't loaded, and that the timeline entries carry the child's title and reference (and the no-link fallback when there's no child). CHANGELOG line; no docs-site page.

**Risks.** The version bump makes every user's first sync after upgrading refetch the whole issue history for each org: heavy nodes (15 per page), so a one-off GraphQL cost against the hourly budget; it should run through the normal sync run so progress shows and `RateLimit.isLow` holds it off. One more field on the heavy history query, within `first: 100` events.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Issues/IssueTimeline.swift#L48`: The parent page's timeline builds each sub-issue added entry with subject = the parent's own IssueRecord, so the row's title is the parent's. This is the cause of the wrong title.
- `andrew-waters/gannin` `Gannin/WorkLog/StandupView.swift#L925-L939`: StandupTimelineList.content makes the title a button that navigates to page(item.subject), which here is the parent being viewed, so the click lands on the page already open and appears to do nothing. Same cause as the title.
- `andrew-waters/gannin` `Gannin/Issues/IssueQueries.swift#L141-L147`: The history query fetches SUB_ISSUE_ADDED_EVENT with only createdAt, and IssueRecord.subIssuesAddedAt is [Date]. The child's identity is never fetched or stored, so it must be added.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Issues/IssueWindow.swift#L5-L30`: IssueReference can be built from id, number, title, repo and url alone, so the child needs no IssueRecord to be opened as .issueReference.
- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L116-L121`: IssueHistory.currentVersion is bumped when the stored shape gains fields old caches can't fill in, so they're fetched again; loadCached drops a history of another version. Work-log rules say not to bump where absence just means fetch again, but here closed issues would otherwise never gain the child.

**Risks:**

- `andrew-waters/gannin` `Gannin/Issues/IssueModels.swift#L5-L43`: IssueRecord is cached and shared (SharedIssueStore, HistoryIssueExtras). A new field must be optional so old caches load, and existing records won't have the child until refetched; .claude/rules/fetching.md says not to invent values for old records.
- `andrew-waters/gannin` `Gannin/Sync/SharedIssueStore.swift#L238-L246`: StoredIssue.merged(with:) replaces the history slot only with one fetched at least as recently by updatedAt, so the refetch after a version bump (same updatedAt) overwrites the old slot and adds the child.

**Decisions:**

- What should an entry show for a record cached before the child was stored? **Bump IssueHistory.currentVersion so every issue is refetched once and gets its child. Revisited at the room's request: it first said 'Sub-issue added' with no link until the next fetch and no bump, and the room changed it. A record with no child (failed refetch) still reads 'Sub-issue added' with no link.**
- Is the design right? **Yes, including the IssueHistory.currentVersion bump.**

## Tasks

1. [andrew-waters/gannin#434](https://github.com/andrew-waters/gannin/issues/434) Fetch and keep the sub-issue each 'sub-issue added' event added (satisfies R1, R2)
2. [andrew-waters/gannin#435](https://github.com/andrew-waters/gannin/issues/435) Show and open the sub-issue on the parent issue's 'sub-issue added' entry (satisfies R1, R2)

**Decisions:**

- Are the three tasks right? **Yes; the plan is ready.**

## From the room

- We want to revisit "What should an entry show for a record cached before the child was stored?". We said "'Sub-issue added' with no link until the issue is next fetched; no cache version bump.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (design)
- We want to revisit "What should an entry show for a record cached before the child was stored?". We said "'Sub-issue added' with no link until the issue is next fetched; no cache version bump. Asked again at the room's request and reaffirmed, so the design is unchanged.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (design)
