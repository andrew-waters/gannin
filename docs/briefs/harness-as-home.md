# Brief: the harness as Gannin's home

For the next agent picking this up. Read the repo's `CLAUDE.md` first (it maps every part of the
app), then this.

## Where things are

- Branch `sessions-and-harness`, 14 commits ahead of `main`, nothing pushed. Latest is `0d87f4c`
  (groundwork for running sessions on a server).
- Build (Mac): `xcodebuild -project Gannin.xcodeproj -scheme Gannin -destination 'platform=macOS'
  -allowProvisioningUpdates -skipPackagePluginValidation build`. Run `xcodegen generate` after
  adding or removing files. SwiftTerm's build plugin needs `-skipPackagePluginValidation` (or
  trusting it once in Xcode).
- The built app is at `~/Library/Developer/Xcode/DerivedData/Gannin-*/Build/Products/Debug/Gannin.app`;
  the user expects you to quit and relaunch it after a build (`pkill -x Gannin`, then `open` that app).
- The Mac app is not sandboxed (sessions run git, gh and claude as the user). iPad builds from
  the same sources; Claude Code sessions are Mac only (`#if os(macOS)`).

## The goal

Make the org's harness repo (Ctrl Hub's is `ctrl-hub/harness`) the place sessions start from
and the place the team's shared, versioned data lives. Decisions already made with the user:

1. Sessions always launch in the harness checkout, on this Mac or on a server reached with a
   Connect with command.
2. Code for a session is a git worktree per issue, inside the harness:
   `harness/.worktrees/<123-branch>/<repo>`, with `projects/<repo>` staying on its default branch
   as the shared clone.
3. The harness stores session briefs and logs, team settings, plans Claude writes, and people's
   dates and time off, sick days included for now (the user will revisit that).
4. Gannin writes to the harness by committing through the GitHub API, never through a checkout,
   and every write is confirmed first, as all GitHub writes in Gannin are.
5. For an org with no harness, Gannin offers to create one.

## What exists to build on

- Sessions (`Gannin/Sessions/`): `SessionStore` (sessions, their terminals, launch, hook state),
  `SessionScript` (the bash start script, the hooks' settings JSON, the remote bootstrap),
  `SessionViews` (session window, Work on This, sidebar rows, settings section).
  - Today a session clones the code repo into `~/Gannin/<owner>/<name>` and makes a worktree
    beside it (`<name>.worktrees/<branch>`). That is what changes in stage 1.
  - `CodeSession.connect` and `remoteWorkspace` are set from the `sessionsConnect` and
    `sessionsRemoteWorkspace` defaults when a session is made. With `connect`, the launch packs
    script, brief and settings as base64 into one command (`SessionScript.remoteCommand`,
    `connecting`) run through the user's login shell. There is no Settings UI for these yet
    (add it to `SessionSettingsSection`: "Connect with", placeholder `ssh -t devbox`, and "Remote
    workspace"). It has not been run against a real server.
  - Hook state arrives two ways: files in the session folder (polled locally) and an escape code,
    OSC 7777 with `state:<state>` or `pr:<url>`, written to `/dev/tty` and read by SwiftTerm's
    `registerOscHandler` in `SessionTerminal`. The escape code is what works remotely.
- Harness (`Gannin/Harness/`): `HarnessStore` indexes the repo from GitHub (head commit, REST
  tree, blobs 30 to a GraphQL query, parsed off the main thread, cached on disk).
  `HarnessConfig` (repo, branch) is in `OrgConfig.harness`. `HarnessKind` fixes the layout.
- Org data today: `OrgConfigStore` (views, investments, issue workflow, working week, leave
  policy, harness) and `PeopleDatesStore` (`WorkLog/PeopleDates.swift`: start and end dates,
  time off with kind holiday or sick and half days, own working pattern, time zone, holiday
  region, allowance, carry-over). Both write through `UserDatabase` (SwiftData, synced with
  CloudKit), per user.
- Confirmed writes: `BulkWriteSheet` (confirm, write one at a time, tick off). Board field writes
  go through `FieldWriter`.

## Stage 1: sessions launch in the harness

- Settings: a harness checkout path per box. On this Mac default to an existing checkout if the
  user has one (Ctrl Hub's is `~/Code/ctrl-hub/harness`), else `~/Gannin/<org>-harness`. For a
  server, the remote workspace setting becomes the harness path there.
- The start script (`SessionScript.start`), on whichever box:
  1. Clone the harness if it isn't there (`gh repo clone`, else `git clone`), else
     `git pull --ff-only` it (don't fail the session if the pull can't fast-forward; say so).
  2. Make sure `projects/<name>` is cloned; fetch it.
  3. Add the worktree `.worktrees/<branch>/<name>` from `projects/<name>` (existing local branch,
     else origin's, else new from origin's default), and make sure `.worktrees/` is ignored
     (`.git/info/exclude` of the harness, or its `.gitignore` in stage 3).
  4. `cd` into that worktree and start or resume claude as now. Claude Code loads `CLAUDE.md`
     from the working directory and every directory above it, so the harness guide and the
     repo's own guide both load. Check that is true for the installed version before relying
     on it; if not, pass `--add-dir` for the harness root.
- Work on This keeps its repo picker; later a session could add a second repo's worktree to the
  same `.worktrees/<branch>/` for cross-repo work (the harness's normal way of working).
- The session panel's Show in Finder and paths should follow the new layout, and only offer
  Finder for local sessions.

## Stage 2: briefs and logs in the harness

- On Work on This, commit `sessions/<repo-name>-<number>/brief.md` and `session.json` (issue,
  repos, branch, who started it, when, which box, later its PRs) to the harness's default branch.
  The script's pull brings them to the box; drop the base64 brief from the remote bootstrap once
  this works (settings and the script can stay in the command).
- Use GraphQL `createCommitOnBranch` (several files in one commit, and `expectedHeadOid` gives a
  clean conflict check); on a conflict, refetch the head and retry once.
- When a PR is reported (the `pr:` signal), commit it into `session.json`.
- Add to the brief: plans go in `requirements/<module>/plans/` with `| GitHub | owner/name#N |`
  in the header table, committed in the harness checkout, so they appear on the Harness page and
  the issue (the rules in `HarnessDocument.init`).
- These are writes to a shared repo: confirm the first time (or per org, with a "don't ask
  again" the user can undo in Settings).

## Stage 3: create a harness

- Settings › Harness, when the repo is None: Create Harness. REST `POST /orgs/{org}/repos` with
  `private: true, auto_init: true` (GraphQL `createRepository` makes no first commit, and
  `createCommitOnBranch` needs a branch), then one commit with the skeleton: `README.md`, a
  starter `CLAUDE.md` in the spirit of Ctrl Hub's (projects table, workflow, where plans go),
  `requirements/README.md` and `_template.md`, `findings/`, `skills/README.md`, `sessions/`,
  `.gannin/README.md`, and `.gitignore` with `projects/` and `.worktrees/`. Confirm first, then
  select it as the org's harness.

## Stage 4: team data in the harness

- Files under `.gannin/`, JSON, one concern each so commits and conflicts stay small, for example
  `views.json`, `investments.json`, `workflow.json`, `working-week.json`, `leave.json`, and
  `people/<login>.json` (dates, time off including sick days for now, pattern, time zone,
  region, allowance, carry-over).
- Read them in the harness index (they aren't `HarnessKind` documents; index `.gannin/` too).
  The stores (`OrgConfigStore`, `PeopleDatesStore`) take the harness's copy as the source when
  the org has a harness, and keep CloudKit for what stays personal (stars, hidden items, app
  settings) and for orgs without a harness.
- Writes: each change is a confirmed commit through `createCommitOnBranch`, with a short message
  (`Gannin: time off for ian, 3 to 5 Oct`). On `expectedHeadOid` mismatch, fetch the file, apply
  the change to the newer copy, and retry once; tell the user if it still fails. Show the new
  state at once (as `IssueStore.recordFieldValue` does) and let the next index confirm it.
- A one-off Move to Harness copies the org's current data from CloudKit in one commit.
- Think about frequency: time off and view tweaks are frequent; batch rapid edits (a short
  debounce, or an explicit Save in the editors) rather than one commit per keystroke.

## How the user works (follow these)

- No Claude attribution anywhere (commits, PRs). No em dashes, en dashes or single-character
  ellipses in anything written: code comments, UI text, commits, docs.
- Builds and tests are expensive on their machine: make the whole change, then build once;
  capture output the first time; don't rebuild to reread.
- Native macOS patterns (they notice amateur UI): system controls, sidebars as Mail does,
  toolbars, searchable pickers where lists are long. Match the surrounding code's comment style.
- Every GitHub write is confirmed first.
- Commit on the branch as coherent pieces with plain, descriptive messages; update `CLAUDE.md`
  when behaviour or structure changes.

## Open questions to raise with the user, not decide

- Whether people's data (especially sick days) should stay in the repo long term, or move to
  something access-controlled.
- Whether settings changes should go straight to the default branch or through a PR.
- Where each box's harness checkout lives by default on a server.
