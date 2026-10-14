# Changelog

All notable changes to Gannin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Add your change under `## [Unreleased]` in the pull request that makes it, in an `Added`,
`Changed` or `Fixed` group. `docs/RELEASING.md` says how a release takes them.

## [Unreleased]

### Fixed
- Gannin Remote stays connected when opening a session, fits session snapshots within the frame limit, refreshes permission choices as they draw, and prevents queued actions after a phone is revoked or disconnected

### Added
- Gannin Remote, an iPhone app that pairs with your Mac over the local network to answer Claude's questions and permission prompts, send a prompt, stop a session and switch it between Attended and Unattended, with Settings › Remote to turn it on and revoke phones
- Design and Refine sessions now open the page in a web view inside Gannin: step through it with the team, note findings with the page they were on, take screenshots and mark them up, and paste the meeting's transcript; Claude reads the code to say where each finding lives and suggests ones the room missed; Agree makes the findings into issues on the workflow board and records the session, with the screenshots you tick, in the harness's `refines/`. Each project keeps its own logins for these pages, with Sign Out of Pages in the session and Settings › Storage
- Every session at once in the Claude Code window divides into Work and Reviews sections when both are open
- The Claude Code window's tab bar keeps review tabs together after your work tabs, with a divider between the groups when both are open

## [0.0.3] - 2026-10-13

### Added
- Design and Refine under Rituals: start a session on a web page with its project, repos and who's in the meeting, kept across launches, with Claude as co-reviewer (stepping through the page and capturing findings to come)
- Team › Activity's work log shows issues people opened and comments they left on issues, with a Filter menu for the kinds of activity shown and one repository
- Harness › Onboarding maps the project's decisions, requirements and plans by area, in reading order, so someone new can find the part they'll work on and read why it is the way it is; what you've opened is marked read on this Mac, and says when it's changed since
- Harness › Decisions keeps the team's decision records (ADRs) in `decisions/`, with a template, Draft with Claude, links to what superseded them, and Suggest Decisions, where Claude proposes them from the harness's plans for you to review and commit
- Create Harness adds a `decisions/` folder with a README and template
- Inbox › Needs your review now says when someone else has already reviewed a PR, such as "Review requested, approved by Sam"
- The diffs on the pull request review page now colour code by language (Swift, TypeScript, JavaScript, Go, PHP, Python, JSON, YAML, Markdown and shell), with added and removed lines marked by a tinted `+` or `-` gutter and a lighter row tint; other files show as before
- Post automatic reviews in Settings › Harness: each project can say on, off or as in Settings, instead of every project following the one Mac-wide choice
- Refines under Harness: a `refines/` folder for Design and Refine session records, in new harnesses too
- A sandbox's activity (Claude starting, prompts, the tools it uses, failures and when it's waiting on you) now shows in `container logs` and Orchard, with nothing from inside the commands or files and tokens redacted
- A scheduling board under Agents › Queue and on each queue window's page: drag open issues onto the coming week's windows to queue them, onto Pinned to pin them to a time, or back to unschedule them, and see where each queued issue should run
- Session rules in Settings › General: block force pushes, pushes to other branches, branch and tag deletes, release writes, too many PR comments an hour, or commands of your own (or ask you first), checked outside Claude in every session
- A harness commit to a repo whose rules require a pull request now goes through a new branch and a pull request, merged right away when GitHub will have it (which includes anyone who can bypass the rule); otherwise the pull request is left open and a notification says why

### Changed
- Ask before recording a session is now set per project in Settings › Harness rather than once per org, so a choice made for one project no longer applies to the others; an org-wide choice made before still applies until a project is set
- The workload, issue history and work log now share one search per org for what changed, which Settings › Sync › Spent lists as Change feed, instead of each searching for it, so a PR or issue that hasn't changed isn't downloaded again; each still searches for itself when that search fails or finds more than GitHub returns
- Watching a session's pull requests asks GitHub one cheap question for all sessions and reads one in full only when something changed, while its checks are running, or every 10 minutes, which saves API budget
- GitHub requests are now limited to 8 in flight across the app, so a Refresh can't trip GitHub's secondary rate limit; opening a PR, issue or review keeps two of those slots free so it doesn't wait behind a sync
- Refresh no longer fetches every open issue again each time; that happens on its own interval (Settings › Sync › Every open issue) or with Full Refresh, which saves API budget
- A PR is now kept once in a shared store (Settings › Storage › Pull requests) that the workload snapshots, the merged PR history and the work log read from, instead of each keeping its own copy; your existing snapshots, merged PR history and work logs move into it on upgrade without being fetched again, and clearing one of them in Settings › Storage removes only what that page reads
- Each metrics sync fetches merged PRs from a day before the last sync to the second, rather than from the start of that day, so it downloads up to a day less
- A scheduled run for an issue that already has a session carries on in that session instead of failing

### Fixed
- A review asked to look again no longer tells you "nothing has changed since my last review" when that review was never posted to GitHub; it reviews the pull request afresh, with a summary that stands alone
- The pull request review tab's header gives the repo and PR reference its natural width, with the status and buttons on their own wrapping row below, instead of squeezing the reference into a thin column that broke mid-word; the status takes a fixed width, so the buttons stay put while the review loads or runs again
- Expanding a parent issue in Issues › All no longer crashes when it's showing sub-issues; the agent queue pill and Schedule for Agent menu, on each row, didn't reliably get their environment when a row was revealed by expanding its parent, which only `NSOutlineView` builds, outside the view's normal update cycle
- An org with more than 1000 open issues no longer loses its older open issues from Gannin when every open issue is fetched again; GitHub returns only 1000 of them, so ones it doesn't return are kept until they change
- A harness repo with too many files for GitHub to list at once now says so, instead of indexing only some of its documents without a word
- Issues › All, Not on a board and Views now show an outside repo's issues when the window's project names it, as Pull Requests already did; the issue history wasn't fetching them at all
- Agree and Write's error when a plan can't be committed is now shown clearly (it was easy to miss, styled as an ordinary caption at the bottom of a scrolled form) and names GitHub's real reason instead of a generic "GitHub didn't make the commit."; a sub-issue made but not added to the workflow board, or an expired GitHub session, now says so instead of failing silently
- Agree and Write no longer makes duplicate GitHub issues if its sheet is dismissed and reopened after a partial failure
- A harness commit refused by a repository ruleset now opens a pull request as a classic branch protection refusal already did; GitHub's ruleset refusal just says "repository rule violations" rather than naming the rule, so it wasn't recognised as needing one
- The Docs links in gannin.ai's header and footer now open the documentation at gannin.ai/docs; they went nowhere before
- Issues › All no longer crashes when you expand an issue with sub-issues after scheduling one for an agent
- An issue's Queued for Agent mark no longer vanishes when its queue window starts it: it shows Agent Working (or Agent Needs You) while the session runs

## [0.0.2] - 2026-10-05

### Added
- Projects as workspaces: each window picks Org › Project, with its own repos, harness, boards and settings
- A command palette (⌘K) for search and actions across every org
- New Issue (⌘N), with templates, a board, fields and a parent, and drafting with Claude
- Milestones and GitHub Releases under Delivery, with progress and the release each shipped
- Auto review when your review is requested, watching reviewed PRs for changes and resolving threads a later review says are dealt with
- Sessions watch their PRs across launches and can send new review feedback to Claude
- Choose a PR's reviewers from its drawer, and a tidier PR drawer
- Boards linked to a repo, a Boards page in place of a repo's Projects tab, and faster, more reliable board loading
- Harness document details with editable status, owner and domains, and single-repo harnesses
- Blockquotes, GitHub's alerts and more of its HTML rendered in descriptions

## [0.0.1] - 2026-10-02

### Added
- The first build of Gannin for Mac, signed, notarised and updating itself from gannin.ai
