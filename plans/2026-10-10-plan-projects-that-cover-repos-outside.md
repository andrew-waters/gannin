---
type: plan
status: in-progress
summary: "Let a project name repos its account doesn't own (open source you contribute to, a client's repo you're an outside collaborator on) and show their work as Gannin does for the account's own."
issues: [andrew-waters/gannin#170, andrew-waters/gannin#171, andrew-waters/gannin#172, andrew-waters/gannin#173, andrew-waters/gannin#174, andrew-waters/gannin#175, andrew-waters/gannin#176, andrew-waters/gannin#177]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-10
requirement: requirements/plan-projects-that-cover-repos-outside.md
---

# Projects that cover repos outside the account

Let a project name repos its account doesn't own (open source you contribute to, a client's repo you're an outside collaborator on) and show their work as Gannin does for the account's own.

## Requirement

In full in [requirements/plan-projects-that-cover-repos-outside.md](../requirements/plan-projects-that-cover-repos-outside.md).

**Problem:** A project can only name repos its account owns (or the org's). An outside collaborator never sees the client's org in Gannin's account list, and a personal account lists only repos it owns, so a client's repos, and open-source repos you contribute to, can't be in any project: their PRs, reviews owed and issues don't show anywhere in Gannin.

**Goal:** A project can name repos its account doesn't own, and their open and recently merged PRs, open issues and review requests show on the workload pages as the account's own repos' do, with nothing changing for projects that name none.

**Who it's for:** Anyone whose work spans repos their accounts don't own: first an outside collaborator on a client's private repos, then an open-source contributor to someone else's public repo.

**Scope:**

1. Name outside repos (owner/name) in a project's repos, saved in its project.json
2. Check an outside repo exists and is readable when it's added
3. Fetch outside repos' PRs and issues into the workload snapshot
4. Show them on Pull Requests, Issues › All, Inbox, the Dashboard's Needs attention and people's load
5. Pages not covered say so for outside repos
6. Writes on outside repos' items behave as today, showing GitHub's reason when refused
7. Sessions on outside repos' issues find their PRs

**Out of scope:**

- Metrics history, issue history (Issue flow, Investments, Recap, Scorecards from them), work log and Standup for outside repos
- CI (Actions) and Releases for outside repos
- Boards owned by the outside repo's owner
- An account of its own for an outside owner
- People from outside repos on the Team, time off or people's load
- A harness outside the account
- Checking write permission on outside repos up front

**Acceptance criteria:**

- **R1** When adding a repo to a project, the system shall let you type owner/name for a repo the account doesn't own, beside the account's repos in the picker.
- **R2** When an outside repo is typed, the system shall check with GitHub that it exists and the token can read it before adding it, and when it can't, shall say why and not add it.
- **R3** When a project names an outside repo, the system shall save it in the project's .gannin/project.json with its other repos, and Settings › Projects shall mark it as outside the account.
- **R4** When the workload snapshot is fetched for an account whose projects name outside repos, the system shall include those repos' open PRs, PRs merged in the lookback and open issues, in the full search and the incremental changes search alike.
- **R5** When a window's project names an outside repo, its PRs and issues shall show on Pull Requests, Issues › All, the Inbox, the Dashboard's Needs attention and people's load as the account's own repos' do.
- **R6** When an outside repo's PR or issue involves people who aren't the account's members, the system shall show them as authors, reviewers and assignees in the lists, and give a load only to the account's members.
- **R7** When no project of an account names an outside repo, the system shall send exactly the queries it sends today.
- **R8** When an outside repo stops being readable, the system shall leave it out of searches so the rest still fetch, keep its last items marked stale, mark it Can't be read in Settings › Projects with GitHub's reason, and keep it in project.json.
- **R9** When a window's project names outside repos, pages not covered (metrics, Issue flow, Investments, Recap, Scorecards, work log, Standup, CI, Releases and boards) shall say outside repos aren't covered there.
- **R10** When GitHub refuses a write on an outside repo's item, the system shall show GitHub's reason, writes being confirmed first as today.
- **R11** When outside repos are fetched, their cost shall be charged to the workload in the usage ledger, so Settings › Sync shows it with the rest.
- **R12** When a window's project doesn't name an outside repo, that repo's items shall not show in it.
- **R13** When a Claude Code session works on an outside repo's issue, the system shall find the PRs it opens on that repo for its PRs pane, as it does for the account's own repos.

**Decisions:**

- Who has the problem, and which case comes first? **Both outside collaborators on a client's repos and open-source contributors; the client case first, open source on the same mechanism.**
- Where is an outside repo named? **In a project's repos, in its .gannin/project.json beside its own, under the account its harness belongs to. Shared with whoever adds the project; projects without outside repos are untouched.**
- Which pages cover outside repos in the first version? **Only what the workload snapshot feeds: Pull Requests, Issues › All, Inbox, the Dashboard's Needs attention and people's load. Metrics, issue history, work log, CI, Releases and boards say they don't cover outside repos rather than fetching.**
- Who counts as a person for an outside repo? **Only the account's members (for a personal account, you). The outside repo's people show as authors and reviewers in the lists, as non-members do today; no new member fetching.**
- What happens when an outside repo can't be read any more? **It stays in the project. Settings marks it Can't be read with GitHub's reason, searches leave it out, and its last items stay, marked stale, until it's removed or readable again. Nothing is taken out of project.json by itself.**
- Where's the harness, and what about writes on outside repos? **The harness stays in the account. Writes on outside repos' items go through as for any repo, confirmed first as today; when GitHub refuses, its reason is shown. No permission check up front.**
- Is R13 right? **Approved; requirements agreed again with it.**

## Design

**Outside repos are a project's repos whose owner isn't the account.** `RepoProject.repos` already holds `owner/name`, so nothing new is saved: `OrgConfig.outsideRepos` is every project's repos whose owner differs from the account's login (case aside). An account with none takes every existing path unchanged (R7).

**Adding one (R1, R2, R3).** The project's add-a-repo popover gets a row, *Add owner/name*, when the search text looks like `owner/name` and isn't one of the account's. Picking it looks the repo up (`repository(owner:name:) { nameWithOwner isArchived viewerPermission }`); a miss shows GitHub's reason in the popover and adds nothing, a hit adds the canonical `nameWithOwner` through `updateProject`, staged in the harness as today. Settings shows outside repos' chips with the owner and an Outside mark.

**Fetching (R4, R11).** `OrgStore` is given the account's outside repos by a provider the app sets from `OrgConfigStore`'s root store (every project's, so the cache is the same whichever project a window has). `GitHubAPI.snapshot` keeps the account's searches exactly as they are and adds its own named searches for outside repos, batched (a few `repo:` qualifiers each, well under the query length limit, each with its own 1000 cap): `outside-open-prs-1`, `outside-merged-prs-1`, `outside-issues-1` for a full fetch, `outside-changed-prs-1` and `outside-changed-issues-1` for changes, with `archived:false` and the same lookback. They're steps of the same `SyncRun`, join `counts()` for progress, are charged to the workload like the rest, and their results are appended to the same lists (deduplicated by node ID). A truncated outside changes search makes the fetch full, as today.

**Lost access (R8).** Search silently drops a repo it can't read, so with members and teams (hourly and on Refresh) and on adding, one aliased query reads every outside repo by owner and name. The snapshot keeps `unreadableRepos` (repo to GitHub's reason, or renamed to). Unreadable repos are left out of the searches, their last items are carried over from the previous snapshot on a full fetch and marked stale in the lists, and Settings › Projects marks the chip Can't be read with the reason. Nothing's removed from `project.json`.

**Who sees them (R5, R6, R12).** `RepoExclusion` gains `outside`: an outside repo is excluded unless the window's project names it, so a project naming no repos (every repo) doesn't pick up another project's outside repos. Within the project, Workload, Pull Requests, Issues › All, Inbox and Needs attention already work off the snapshot and `repoExclusion`, so they show them. People stay the account's members: outside repos' authors and reviewers show in lists as non-members do and get no load.

**Not covered (R9).** A `.outsideReposNotice` like `.syncOffNotice`, shown when the window's project names outside repos, on metrics pages (PR flow, Scorecards, Issue flow, Investments, Recap), Activity and Standup, CI, Releases and Boards. Their fetchers are untouched.

**Writes (R10).** Unchanged: writes are confirmed first and GitHub's refusal already surfaces as an error; checked that each write path on an outside repo's item shows it rather than failing silently.

**Sessions (R13).** `SessionPullRequests`' `head:<branch>` search adds `repo:` for the session's repos outside the account, ORed with the account's scope as GitHub does.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/GitHub/GitHubAccounts.swift`: scope() gives org:<login> or user:<login> for every search; repositoryArguments limits a personal account's repo lists to ownerAffiliations: [OWNER], so collaborator repos never appear.
- `andrew-waters/gannin` `Gannin/Workload/RepoProjects.swift`: RepoProject.repos are owner/name strings in .gannin/project.json, so the file can already hold any owner's repo; Add Project and the add-a-repo picker only offer harness.repositories[org]. RepoExclusion.focus is the project's repos.
- `andrew-waters/gannin` `Gannin/Metrics/OrgConfigStore.swift#L147-L150`: OrgConfig.apply sets focusRepos to the project's repos; views drop anything outside them, so outside repos already pass the filter, but nothing fetches them. unfetchedRepos is excluded repos no project names.
- `andrew-waters/gannin` `Gannin/GitHub/Queries.swift#L60`: Snapshot searches are '<scope> archived:false is:pr ...'; changes searches by updated:>=. Searches cap at 1000 results.
- `andrew-waters/gannin` `Gannin/Issues/IssueStore.swift#L53`: Issue history searches use the same scope; also IssueQueries.swift#L257 (earliest issue), MetricQueries.swift#L53,L71, WorkLogQueries.swift#L11, SessionPullRequests.swift#L412.
- `andrew-waters/gannin` `Gannin/Actions/ActionsQueries.swift#L30`: CI, Releases (ReleaseQueries.swift#L44) and the harness repo list (HarnessStore.swift#L269) list the owner's repositories(...) then go repo by repo.
- `andrew-waters/gannin` `Gannin/Workload/OrgStore.swift#L128-L160`: refresh(login:mode:) builds the SnapshotPlan with the lookback but has no OrgConfig, so it needs to be told the account's outside repos (a provider set by the app, as SessionStore.orgContext is).
- `andrew-waters/gannin` `Gannin/Workload/Workload.swift#L79-L91`: Workload drops PRs and issues whose repo repoExclusion contains; with a project naming no repos, focus is nil, so outside repos' items would show in every window unless RepoExclusion learns about them (R12).
- `andrew-waters/gannin` `Gannin/Views/SearchablePicker.swift#L54`: SearchableList only picks from its choices; typing owner/name needs an extra row (Add owner/name) when the query looks like one and isn't listed (R1).

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/GitHub/Queries.swift#L160-L192`: fetchAll and fetchChanges run named searches as SyncRun steps (open-prs, merged-prs, issues; changed-prs, changed-issues); a truncated changes search falls back to a full one. Outside searches can be more named steps alongside, merged into the same lists.
- `andrew-waters/gannin` `Gannin/GitHub/Queries.swift#L278-L309`: counts() aliases every search's issueCount (and the org's member and team totals) into one query for progress. Outside searches join it; the same aliasing suits one query reading every outside repo by owner and name.
- `andrew-waters/gannin` `Gannin/Views/SyncSettingsView.swift#L265`: syncOffNotice is how a page says at its top that it isn't showing something; an outside-repos notice follows it (R9).

**Risks:**

- `andrew-waters/gannin` `Gannin/Workload/OrgStore.swift#L86-L101`: The account list is your personal account plus orgs you're a member of. An outside collaborator never sees the client's org there, so a client's repos can only be reached as outside repos of an account you do have.
- `andrew-waters/gannin` `Gannin/GitHub/Queries.swift#L60`: Checked against GitHub: user:/org: and repo: qualifiers are ORed (7 + 73 = 80 results), and a repo: that doesn't exist or can't be read is silently dropped from a GraphQL search, not an error. So search can't tell us access was lost; a separate repository lookup has to, and a full search would quietly drop that repo's items.
- `andrew-waters/gannin` `Gannin/GitHub/Queries.swift#L311`: GitHub caps a search at 1000 results and limits the query's length (256 characters), so outside repos can't all go into one query, and ORing them into the account's would change its queries (R7) and share its 1000 cap.
- `andrew-waters/gannin` `Gannin/Sessions/SessionPullRequests.swift#L412`: A session's PRs are found by '<scope> is:pr head:<branch>', so a session on an outside repo's issue wouldn't find its PR except by the URL its hook caught.

**Decisions:**

- Should sessions on an outside repo's issue find their PRs? **Yes: the session's PR search adds its outside repos as repo: qualifiers. Found while designing, so added to the requirements as R13.**
- Is the design right? **Approved as proposed.**

## Tasks

1. [andrew-waters/gannin#171](https://github.com/andrew-waters/gannin/issues/171) Outside repos in the config and RepoExclusion (satisfies R3, R7, R12)
2. [andrew-waters/gannin#172](https://github.com/andrew-waters/gannin/issues/172) Add an outside repo by typing owner/name (satisfies R1, R2, R3)
3. [andrew-waters/gannin#173](https://github.com/andrew-waters/gannin/issues/173) Fetch outside repos into the workload snapshot (satisfies R4, R5, R6, R7, R11)
4. [andrew-waters/gannin#174](https://github.com/andrew-waters/gannin/issues/174) Mark outside repos that can't be read (satisfies R8)
5. [andrew-waters/gannin#175](https://github.com/andrew-waters/gannin/issues/175) Say which pages don't cover outside repos (satisfies R9)
6. [andrew-waters/gannin#176](https://github.com/andrew-waters/gannin/issues/176) Find a session's PRs on outside repos (satisfies R13)
7. [andrew-waters/gannin#177](https://github.com/andrew-waters/gannin/issues/177) Check writes on outside repos' items show GitHub's refusal (satisfies R10)

**Decisions:**

- Are the tasks right? **Approved: seven tasks in order, covering R1-R13.**
