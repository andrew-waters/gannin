---
paths:
  - "Gannin/App/**"
  - "Gannin/Views/**"
  - "Gannin/Workload/**"
---

# App shell, navigation and workload

## Window and navigation wiring
- Windows are independent: org, project (`workspace`), section and metrics window are `@SceneStorage`. Preferences such as chart granularity stay `@AppStorage` (shared). A window opening with no org takes `lastOrg`; picking an org takes `lastWorkspace.<org>`. `WindowTabs.swift` joins New Tab to the current window.
- `Platform.swift` names the few styles used everywhere (`checkboxToggle`, `linkButton`, `onEscape`, `windowSubtitle`, `Color.separatorLine`). AppKit is used directly, no `#if os`.
- A page's title is the window's (`MainView.automaticTitle`, `PageTitles`); top-level controls are toolbar items. `PinnedHeader` is only for section headers further down a page and for the calendar/report inside a person's view.
- `MainView` is a sidebar (`OrgSidebar`) plus `PageStack`. `path: [DetailSelection]` is the trail pushed over the section's first page; only the last shows. Pages push through their `selection` binding or the `navigate` environment action (`Navigation.swift`); a page already in the trail is gone back to; picking a sidebar row clears the trail.
- `WorkloadTab.title` is the displayed name; raw values stay as older windows saved them (never rename a raw value).
- Open in New Tab/Window (`OpenElsewhereItems`, `openElsewhere`): PRs and issues get their own windows (`PullRequestWindow`, `IssueWindow`); anything else opens a main window with the same org, item and trail, handed over via `WindowRequest.pending` and claimed by the new window's `MainView`. `pullRequestReference`/`issueReference` show those windows' views embedded (`isEmbedded`).

## Personal accounts
- Your personal account is first in `OrgStore.loadOrgs` (`Organisation.isUser`) and works as an org. `GitHubAccounts` knows which logins are personal: searches use `scope` (`user:` not `org:`), owner lookups `ownerField` (`user(login:)` aliased as `organization`), own repos only via `repositoryArguments`; members are just you, no teams; Create Harness posts to `user/repos`.

## Workload semantics
- A snapshot is five parallel queries (members, teams, open PRs, merged-in-lookback PRs, open issues); search is capped at 1000 results by GitHub.
- Refreshes are incremental (`GitHubAPI.SnapshotPlan`): items updated since the last fetch (5 min overlap), any state, merged by `OrgSnapshot.merging`. A full search runs daily, when the lookback changes, when the changes search passes 1000, or on Full Refresh. Members/teams refetch hourly or on manual Refresh. Intervals are settings.
- `inFlight` per person = open PRs + review requests + assigned issues with an open PR. Unstarted assigned issues are backlog (not counted); an issue closed by their own PR counts once.
- Hiding is local (`HiddenStore`, keys are PR/issue node IDs). `Workload` drops hidden items and, with Exclude drafts, draft PRs before deriving anything. Rows use `.hideable(_:url:)`. Old `person:<login>` keys are org exclusions (`MainView.config(for:)`).
- Stars are local (`UserDefaults`; GitHub has no org stars). People are org members; non-members' activity still shows in PR/issue lists.

## Drawers
- `PageStack.navigate` sends `.issue`, `.issueReference`, `.pullRequest`, `.pullRequestReference`, `.harnessDocument` to `drawers` instead of pushing (`openAsPage` still pushes). A link inside a drawer stacks another (`navigateInDrawer`); drawers beneath are disabled so their shortcuts don't fire. A view keeps its own drawer that steps through its issues with arrow keys. Separate issue/PR windows are unchanged.
- `IssueTimelineSection` (`Issues/IssueTimeline.swift`) reuses `StandupTimelineList`. PRs the work log lacks are fetched by URL (`WorkLogStore.loadLinked`, memory only).
- Inbox section visibility and order are per org on this Mac (`inboxSections.<org>`, `inboxSectionOrder.<org>`, `InboxSection`).
