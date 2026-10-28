# Changelog

All notable changes to Gannin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Add your change under `## [Unreleased]` in the pull request that makes it, in an `Added`,
`Changed` or `Fixed` group. `docs/RELEASING.md` says how a release takes them.

## [Unreleased]

### Added
- Gannin can be installed with Homebrew: `brew install --cask andrew-waters/tap/gannin`. It keeps updating itself as before
- Specialists: the team's own agents, each with a soul saying who it is and what it looks for, and a default provider, model and focus. Harness › Specialists lists them; New Specialist and Edit Specialist commit `specialists/<name>.md` to the project's harness
- Workflows: reviews, Work on This, Quick Change, Ask, Planning and Design and Refine each run through a workflow of specialists, kept in the project's harness (`.gannin/agent-workflows.json`). A review workflow runs specialists in stages, side by side or one after another, each for one or more rounds, and posts one review with each finding labelled by the specialist that raised it. Reviews and coding can be routed to a workflow by repo, author, labels, changed paths or issue type. With no workflows set up, everything runs as before. A Mac on an older Gannin ignores the file, and drops any workflow it can't read if it saves it
- Specialists, workflows, routing rules and defaults of your own, marked Just me: kept in Gannin on this Mac, never committed to the harness. Your rules are checked before the team's, and the default workflow is each person's, so someone new runs Gannin's until they pick one; a team workflow can't use your specialists, and a posted review calls one of yours "Reviewer" rather than by name
- Routines: New Report and New Maintenance are one New Routine, with Report only beside Local only, Draft PR and Ready PR, and Run with a specialist or a workflow (Harness › Workflows has Routines). A report can name repos to read. Repos are picked from the project's and the org's, and Draft with Claude sets a routine up from what you say it's for
- Edit Specialist on a specialist's page and in a workflow step's inspector, as well as its right-click menu
- Harness › Workflows builds each activity's workflows as nodes (stages left to right, steps side by side), with a step inspector, the most passes a workflow can make, its default and routing rules, whose repos, authors, labels and issue types can be picked from what Gannin knows or typed. Review with Claude, Work on This, Quick Change and Ask can pick another workflow for one run, and a review's Overview shows each step's rounds and findings, and which didn't run and why

### Changed
- The sidebar's Reviews group is split: reviews you've posted with comments or requested changes move to Awaiting author, so Reviews holds the ones still to post, approved ones, and the finished history. The sessions grid has the same Awaiting author section
- A review's Check for Changes result also reflects the background watch: it says what the last check found and how long ago, whether you ran it or Gannin did, and keeps counting up
- A review's summary that describes the comments it left now gives one bullet per issue, grouped under its severity (blocker, major, minor, nit) as in the findings
- Planning: when a plan has just one task, Agree adds its details (description, checklist and the criteria it satisfies) to the description of the issue being planned, or of a new issue, instead of making a sub-issue. An Epic or Initiative still gets a sub-issue
- New Issue opens on Claude: the conversation on the left and a preview of the draft on the right, with Skip to write it yourself. Next takes you to the form, filled from the draft, to check the details and create it; Back returns to Claude and keeps your edits
- The Claude Code window has New Issue too: in the tab bar's + menu, and with ⌘N
- The Issues row in the sidebar shows the open issue count, the same as All under it
- Settings › General's Provider lists Claude Code by name, as sessions now reach it through a provider that others can join later
- Model, in Settings › General, a specialist and a workflow step, is one menu: Gannin's list (now Claude Sonnet 5.5 and Claude Haiku 5.5 in place of Sonnet 5 and Haiku 4.5), the models Claude Code has run with on this Mac lately, the newest of each family (Latest Opus and so on), and Other to type any ID. A model picked before that isn't offered stays as typed, under Other

### Fixed
- A reviewer helping another session (a pair review, or a step of a review run) no longer appears as a session of its own in the sidebar or the sessions grid; it stays in the tab of the session it reviews
- A session's brief now says running ready-for-review is required for every change, and not to open the pull request as ready or report the work done without it, so Claude calls it more reliably
- The search box in a filter bar, such as on Pull Requests, shrinks from 200 to 140 points when the window is narrow instead of pushing the other filters out of view
- Finish and Clean Up no longer waits for the harness to be updated: the session goes as soon as its worktrees are removed, and its session.json is marked finished in the background
- An issue opened from a project board shows its Assignees section even when the issue isn't in the synced issue history yet
- In a planning session, the requirement on the right is no longer greyed out while Claude's question is open, so it can be read while answering
- When Claude asks questions too long to fit over the terminal, they scroll between the title and Send Answers instead of running off the top

## [0.0.5] - 2026-10-23

### Added
- Set Up Harness guides a new user through creating a harness or linking one they have, then adds any starter files it lacks and says where it's checked out. It opens by itself for an org with no project until Not Now, and is in the sidebar, on the Harness and Onboarding pages, and under Gannin › Set Up Harness
- File › New Window and New Tab ask which org and project the window opens on, starting on the window you were in. Turn it off in Settings › General › Windows to open a copy of that window's org and project instead
- Org settings › Issues › Where issues go: choose whether the org files every issue in one central repo or each in its own repo collected on a project. It's kept in the home harness (`.gannin/issue-strategy.json`) for the whole team, and planning follows it. A Mac on an older Gannin ignores it
- Pull Requests filter menus end with Hide These, which hides the values ticked (a repository, an author and so on) instead of showing only them
- Hide reviewed on the Pull Requests page's bar leaves out pull requests you've reviewed and haven't been asked to review again
- A Checks column and menu on the Pull Requests page show and narrow the list by passing, failing, running or no checks
- Hide drafts on the Pull Requests page's bar leaves draft pull requests out of that window's list, without changing counts elsewhere
- CI time per pull request on Delivery › CI: the median and p75 per PR against the period before, how much went on replaced commits and failures, the wait on a PR's final CI, small PRs that run the full suite, and bots' share
- Pull requests and People tables on the CI page, with a page per PR (its time by workflow and its runs by commit) and per person (their share of CI time against their share of PRs)
- CI and the size of change on the CI page: each merged PR's lines against its CI time, CI time by size band, and CI per 1,000 lines merged, week by week
- Needs attention on the CI page flags workflows whose runs keep going after a newer push instead of being cancelled
- CI time per PR as a Scorecard goal, expanding per author
- Dismiss Approval on a review held for your approval, in the Inbox and on the Dashboard, and a reminder every 24 hours until you approve or dismiss it
- `approval_held` in a review's record in the harness, true while the PR is open, Claude's verdict is approve and the approval hasn't been given
- An automatic review posted as a comment for a PR Claude would approve says, after its summary, that it isn't an approval and giving it is up to the reviewer

### Changed
- Planning's Agree no longer offers repos with issues turned off, and moves a task that named one to a repo that accepts issues
- Work on This tells Claude to ask its questions with the AskUserQuestion tool, so they appear as a question card instead of plain text in the terminal
- The Reviewers column on Pull Requests, and Who on Your pull requests in the Inbox, mark each reviewer as asked and waiting, approved, changes requested or commented, show teams asked to review, and say None when nobody has been asked or reviewed
- An automatic review Claude would approve is no longer posted by itself, even with findings, while the PR is ready for your approval: it waits in Ready for your approval, and your approval posts its comments once, as one review
- Planning sessions ask Claude for a few larger tasks, by default one per repository that needs changing, instead of a task per step, so Agree makes fewer sub-issues

### Fixed
- A follow-up review no longer posts findings already on the pull request: ones an earlier review put in its body, ones a few lines from a comment saying the same, and ones you raised before a push made your comment outdated
- Check for Changes on a review's tab also refreshes the PR's checks shown on its card in the sessions grid
- When Junie's reply has no list of findings, it is asked once more for the list, in the same session, instead of the review failing straight away
- A Junie review whose list of findings ends without the closing code fence is read instead of reported as having no list

## [0.0.4] - 2026-10-22

### Added
- The Junie line in a session's Activity pane expands to show Junie's findings, or what it printed when it didn't give a list
- An issue's assignees can be changed from its window or drawer: choose people under Assignees in the side panel and press Save to write the change to GitHub
- Delivery › R&D Time shows how much of each person's working time went to R&D work over an accounting period, by issue and by person, with time found from their activity, working week and time off, over the org's accounting year (any start, set in Settings › Working Time with named periods of its own); what counts is set in Settings › R&D (marked by hand, investment categories, labels or a board field), issues can be marked by hand with a share and rationale, and the report exports as CSV or Markdown. Its activity is fetched only from that page, after showing the searches and GitHub budget it will take and asking to confirm, with progress and Cancel; Refresh never fetches it. Hours only, no costs
- Review windows hold automatic PR reviews to times you choose, so their builds and tests don't slow your Mac while you work: add them under Agents › Routines (New Routine › New Review Window) with days, hours and Reviews at once. Outside every window, review requests and Look Agains wait in a review queue on Agents › Queue, where you can reorder them, remove them or Run Now, and they start in order when a window opens; one whose PR was merged, closed, made a draft or no longer asks for you is skipped. Windows are kept in your file in the org's harness so all your Macs follow them, with Override on This Mac for one that shouldn't. With no windows, nothing changes. Update Gannin on all your Macs first: an older version that changes your dates or time off drops your windows from your file
- A pair review can also use JetBrains Junie as an extra reviewer, alongside claude's: turn on Junie reviewer for a project in Org settings › Projects (off by default, local sessions only). Each round runs Junie in a throwaway copy of the worktree, sends both reviewers' findings to claude together with who raised each, and carries on without Junie, saying why on the session's panel, if it's missing or fails
- A review's tab says "Not posted" until a review is posted, Check for Changes finds a review you posted elsewhere on GitHub, and Post Review and automatic posting no longer send a review you've already posted (same kind, body and commit)
- The sessions grid has a search field (⌘F to focus it, Esc to clear it) that narrows it to sessions matching every word typed, in their kind, reference, title, repo, branch or pull requests; the + menu's Open a Session filter now matches branches and pull requests too
- GoLand is one of the editors files open in (Settings › General › Open files in), at the line for files on this Mac
- Check for Changes on a review's tab fetches the PR again now and, for a watched review, notes new commits and comments, so you can see what changed before you ask Claude to review it again
- A review whose PR has merged can be finished from its row in the Inbox's While you were away section: right-click it and choose Finish Review, without opening it first
- Attach screenshots and other files for a session's Claude, wherever it runs (this Mac, a sandbox or your server): drop them anywhere on the session's side panel, or Paste or Add Files under Attachments in its Issue pane. Each new one goes with your next prompt, shown as a thumbnail above the box under the terminal (click one in the list to add it again or leave it out), and says whether it has been sent
- Hovering Refresh at the bottom of the sidebar, or Full Refresh in its right-click menu, now says what each fetches and how they differ, and hovering a row in the sync detail says what its number counts
- The comment box on a review's diff lines now has Ask Claude, which sends your question to the reviewer with the lines around it and opens the conversation; it's available while the review's Claude is running
- Record queued sessions in Settings › Harness: switch it off for a project and sessions started from the agent queue or a pinned time no longer commit their brief and `session.json` to its harness; it's on by default, as before
- A session's PR that starts to conflict with its base branch is now flagged, and with Send new feedback to Claude on, sent to the session's Claude, asking it to bring in the base branch and push.
- Right-clicking an Ask or Planning session in the sidebar offers the same menu as its list: Open, Rename, Show in Finder and Delete for an Ask; Open and Delete for a plan, plus links to its plan and parent issue once agreed.
- Screenshots of Gannin on gannin.ai, in the docs (Dashboard and PR flow, Issues and Pull Requests, Work on This) and in the README, in light and dark, taken from a demo build on invented data
- Feedback sent to a session's Claude, automatically or from the PRs pane, now asks it to post a short reply on each review thread it fixed, saying what it changed, unless Settings › General › Agent › Ask Claude to reply to review threads is off
- Design and Refine sessions now open the page in a web view inside Gannin: step through it with the team, note findings with the page they were on, take screenshots and mark them up, and paste the meeting's transcript; Claude reads the code to say where each finding lives and suggests ones the room missed; Agree makes the findings into issues on the workflow board and records the session, with the screenshots you tick, in the harness's `refines/`. Each project keeps its own logins for these pages, with Sign Out of Pages in the session and Settings › Storage
- Every session at once in the Claude Code window divides into Work and Reviews sections when both are open
- The Claude Code window's tab bar keeps review tabs together after your work tabs, with a divider between the groups when both are open

### Fixed
- The Junie reviewer's findings are no longer lost: its pair review failed with "Junie replied with no list of findings" because Junie dropped the list from its final summary, so it is now asked to put the list in that summary
- A session's pull request lists only the latest run of each check, so a failure that was since re-run and passed no longer stays listed as failed
- Picking a file, or switching between Branch and Uncommitted, in a session's Changes pane no longer moves the divider and leaves the diff a sliver
- Finish and Clean Up now removes a symlink standing in for a worktree (only the link, never the clone it points to), and a worktree whose git folder has been deleted, instead of failing with "Couldn't remove the worktrees". The folder and its files are deleted, as with any worktree it removes, so anything not pushed in it is lost
- A long error beside Finish and Clean Up, in a session's overview or the close-tab sheet, now shows its full text in a tooltip instead of being cut off after three lines
- A space typed at the end of a multi-line text box in a form now shows as you type it, instead of appearing only once more text follows
- Claude is now reminded in the pull request step of a session's brief to ask for a second agent's review first, so the review is triggered more reliably before a pull request is opened
- A session no longer picks up an unrelated pull request just because Claude read, listed or mentioned it: only a pull request the session opened itself (with `gh pr create` or a PR-creating tool) is recorded against it
- Opening a project board with thousands of items no longer freezes the app: the Table layout now builds only the rows on screen, so the window stays usable while it opens. The Table now has one column header, pinned at the top, instead of one under each group, and sorting by a column sorts within each group
- A session and its helper starting together in one sandbox no longer race to create it, which could leave one failed or take the other's sandbox down; and asking for review again after a reviewer's sandbox failed to start now starts a new reviewer instead of talking to the one that never started
- Posting a review, by hand or automatically, no longer repeats a finding that someone has already commented on the same line: Post to GitHub checks the PR for new comments first and lists the findings it left out, and an automatic review's log entry says how many it skipped
- The sub-issue count on an agreed plan includes sub-issues added to its parent after Agree
- A session whose Claude has quit shows a Resume button over its terminal, so the Work agent can be restarted from the pane
- A session's brief names the harness's own `STANDARDS.md` by path, so Claude no longer goes looking for it in other harnesses' folders
- A PR you've just reviewed from a review tab (Approve, Request Changes or Comment) leaves the Inbox's Ready for your approval and Needs your review sections straight away, instead of waiting for the next refresh
- A mouse wheel over the Claude Code window's tab bar scrolls the tabs sideways
- A session now shows as needing you, with its Allow and Deny card, when Claude Code's permission prompt is on screen even if Claude Code didn't notify Gannin of it, as with a command that also reads outside the session's folders (sessions on this Mac only)
- Re-run Failed Checks on a session's PR now checks GitHub again first, so it no longer fails with a confusing error when a check it last saw as failing has since passed

### Changed
- When a review looks again after new comments, it answers the PR author's comments and other people's only if they disagree with the review or the reviewer disagrees with them
- The sidebar can be dragged wider, up to 500 points instead of 340
- A project board view now opens with the swimlane (or table grouping) you last picked for it, instead of going back to its GitHub grouping each time
- Review Now on a session whose review has ended now launches the reviewer again, restarting its Claude Code if that had exited, and brings its tab to the front; when it can't start, the panel says why instead of doing nothing
- Opening a session's tab (from the tab bar, by cycling to it, or from the Agents page, the command palette or a notification) now shows its reviewer when the reviewer is waiting for an answer and the session itself isn't, instead of the work
- Open issues are kept once on disk instead of in both the workload snapshot and the issue history, shown as Issues in Settings › Storage. Existing caches are moved across on first launch, so nothing is fetched again
- A plan can be ended from its own tab with End: Claude stops and the tab closes, and the plan stays on Rituals › Planning as Finished to read, but leaves the sidebar. An Ask's tab has a Delete button, with the same confirmation as the list's
- A session's Changes pane colours the code in a file's diff by its language, as a pull request review's diff does

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
