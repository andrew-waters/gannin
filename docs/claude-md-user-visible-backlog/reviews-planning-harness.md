# User-visible material: reviews, planning, wrap-up, harness

Source: CLAUDE.md lines 989-1264 and 1465-1602. No docs page exists yet for reviews, planning, wrap-up or the Harness pages unless noted. Already covered: settings rows for auto review, watch, post automatic, record reviews and pair review (settings/app/general.md); harness concept (concepts/projects-and-harnesses.md); team data, pending changes, prompts, drafting with Claude, checkouts (settings/org/harness.md); Create Harness (get-started/create-a-harness.md); Projects and Make Home (settings/org/projects.md).

## Review with Claude
- Button on a PR's drawer and window starts a review session; its tab is a review page, not a terminal.
- Opens on Overview: headline, whether the PR can merge (one sentence, also in the header, from conflicts, draft, review decision, checks, open threads and undismissed findings), Needs attention in tiers (blocking, fix before merging, waiting on, not blocking; empty tiers hidden; each item opens its file, checks or thread), walkthrough and flow, description, and a rail of the PR's comments and reviews with Ask the reviewer.
- File list: Comments on this PR, grouped by the walkthrough's areas, findings filter by severity or category, Learnings row (covering the diff, applied, suggested, with Save as Learning), files with learnings marked.
- Diff: findings on their lines (Keep, Edit, Dismiss), your own comments on any line, summary and verdict, Review Again, conversation beneath. Learnings show in place: file/folder ones at the top, line ones at their line with the lines marked; applied ones as a card with Challenge and Edit Learning.
- Post Review: Approve, Comment or Request Changes (only Comment on your own PR), inline comments on lines in the diff, suggestions as GitHub suggestions, the rest in the body. Offers threads the reviewer says are dealt with, ticked, and resolves them after posting (only threads you started). Record it in the harness checkbox.
- Finish ends the reviewer and removes its checkout but keeps the review under Agents › Reviews (after active ones), read-only; Resume brings it back. A badge on PRs in the Pull Requests table and Inbox opens the review tab.
- Review config: Review Config on a repository's page bar edits profile (quiet, chill, assertive), instructions, tone, files to skip, path instructions, checks (off, warning, error) and title keywords automatic reviews skip, in the project's harness or the repo's own file. Failed checks appear in the Overview tiers.
- Prompts picked in the launch sheet (prompts, skills, note) are added to the first prompt.

## Auto review and watching
- Review requests notify with Review with Claude; your PRs notify on failing checks, changes requested, approval. Menu bar extra and Agents show them.
- Auto review: two at a time in the background, no tab. Watch for changes on the review: after quiet minutes asks the reviewer to look again. Automatic reviews post only as Comment when enabled, never approve or request changes. Inbox's While you were away lists what happened, one row per review, until its tab is looked at.
- Ready for your approval: Inbox section (first), Dashboard Act now, and a notification that counts on the Dock and in Waiting on You. Post Review starts on Approve except when there are commits the review hasn't seen ("New commits since this review").
- Agents › Metrics: tiles (reviews, reviewers, findings posted, acted on, dismissed before posting, effort, posted to merge), by severity and category, reviews a week, Reviewers and Reviews tables, over a range and a reviewer.

## Learnings
- Rules and reasons from review, kept in the harness; Save as Learning (lightbulb) is on comments in issue and PR drawers and the PRs pane's review threads; Edit Learning also on a learning's page (repo, scope, source). Editor commits one file only when you say so.

## Write with Claude
- Beside prompts in Settings: House rules for Claude (Sandbox), each saved prompt (sparkles in General › Prompts, may suggest a name), drafting guidance (Harness). Sheet has the conversation beside an editable draft; Look It Over asks for suggestions; Use This Draft writes it to the setting (guidance is a change to commit); Cancel asks if anything changed.

## Planning sessions
- Started from a New Plan tab in the Claude Code window, Rituals › Planning (table with Delete), Plan This on an issue, Agents, the + menu or a harness document. Editable prompt: Start from a team planning prompt, a suggested one, or blank; saving commits it as a planning prompt.
- Tab is a staged spec: Context (documents, links, places to look), Requirements, Design, Tasks (each names criteria it satisfies; uncovered criteria flagged), then Agree. Each stage loops until the room approves; Back (with reason) reopens a stage and marks later ones Recheck. On top: the current question, what's being read, or whose turn it is. Left pane the stage, right the requirement as it stands; both dim while a question is open.
- Question styles (kept on this Mac): One at a Time (letter keys), Poll the Room (counts hands, sends the most), Keyboard List, Conversation. Comment box at the foot sends "From the room". Terminal and composer are a drawer. Findings can be dismissed.
- Agree sheet: what isn't approved or covered, who was here, edit tasks, makes parent and sub-issues on the workflow board, commits plan and requirement in one commit.
- Documents dropped on the terminal or picked are each confirmed (share, and separately may be committed).

## Wrap-up on close
- Closing a tab (X, Close Tab, close shortcut) of an issue's or quick change's session with claude running asks first: state, helpers, PRs, uncommitted files and unpushed commits per worktree, plans/requirements about the issue with `- [ ]` items to tick (committed in one commit; button names the harness) or Ask Claude to Tick Them Off. Buttons: Keep Running (default), Stop Claude (worktrees kept, resumes on open), Finish and Clean Up (once every PR merged, confirmed), Cancel. Settings › General › Agent "Ask to wrap up when closing a session's tab" (on), also the sheet's Don't ask again.
- Quitting with sessions running asks first: which are running and their state, working ones stop mid-task, server sessions end with ssh, conversations resume.

## Starting sessions
- Work on This runs in the project's harness, recorded there (`sessions/<repo>-<number>/`), confirmed with per-org Don't ask again (undone in Settings › Harness). Checkout location, workspace (`~/Gannin`), Connect with: see settings/org/harness.md "Checkouts" and sessions docs.

## Harness pages
- Sidebar rows under Harness: Plans, Requirements, Findings, Skills, Prompts, Learnings, Research, Refines, with counts; the Harness row shows the last picked.
- Bar: search (title, summary, path, domains, issues), a menu per shared front matter field with counts (Status, Domains, Owner, Touches, Severity...), Not Linked for plans and requirements. Table columns: title with summary, status, domain, issues, tasks, owner, date; newest first until sorted. Sidebar Refresh refetches. Only documents with front matter and summary are listed; older ones are hidden. New in the toolbar (not for Research and Refines).
- Document page / drawer: header (title, Open as Page, Open in Window, Done), summary and a folding section per `##` heading with Contents, facts Form (status, kind, tasks, owner, branch, domains; Edit Details commits front matter), issues it's about, requirement, dependencies, touches, mentions, file. Issue references in the text open in a drawer. An issue's page lists the documents about or mentioning it. Rows: state dot, number and title for issues/PRs; icon, title, status for documents.
- Create Harness onboarding: what a project and harness are, layout as annotated tree, then project name, harness repo name (`-harness` suffix), code repos (busiest ticked). No project: starts at the beginning. Already in get-started/create-a-harness.md.
- Settings › Projects: Home marked, Add Project, Create Harness, per-project name/repos/boards/harness/branch, Make Home. Already in settings/org/projects.md.
- Time off requests: holiday only, shown pale and dashed, Approve in row and context menu, committed like other changes.
- "N changes to commit" row above sync with Review: already in settings/org/harness.md "Changes to commit".

## Dropped
- Review's "in the spirit of CodeRabbit's" and "Kiro and spec-kit" comparisons: history/flavour.
- Issue/plan references (#145, #51, #146, #70, #135, plans/...): history.
- "Posting results to GitHub as statuses isn't done yet": kept in sessions-review.md as a one-liner only.
- Helper reviewer getting the harness's learnings, Sessions/ReviewActivity.json 500 cap detail: kept in rule file; not user-facing.
- "It's laid out large, for the room's screen", "Hooks write state to a file read every second": narration; poll rate kept in rule.
- `HarnessReferenceRow`/`HarnessDocumentRow`/`HarnessDocumentSection` names, `DetailSelection.harnessDocument`, the second Harness page paragraph (duplicate of the earlier one): duplicate/grep-able.
- Harness page "StatsTable" column list repetition: UI layout narration (kept once above).
- `ReviewConfig` "in the spirit of .coderabbit.yaml", `SessionStore.reviewConfig` type lists beyond layering: grep-able.
