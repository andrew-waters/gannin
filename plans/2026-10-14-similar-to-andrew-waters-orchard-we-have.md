---
type: plan
status: in-progress
summary: "A script that captures Gannin on key screens for the site, docs and README, running against a fake GitHub so the screenshots show invented data rather than real people's."
issues: [andrew-waters/gannin#334, andrew-waters/gannin#335, andrew-waters/gannin#336, andrew-waters/gannin#337, andrew-waters/gannin#338, andrew-waters/gannin#339, andrew-waters/gannin#340]
touches: [andrew-waters/gannin, andrew-waters/orchard]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-14
requirement: requirements/similar-to-andrew-waters-orchard-we-have.md
---

# Screenshot capture with a demo environment

A script that captures Gannin on key screens for the site, docs and README, running against a fake GitHub so the screenshots show invented data rather than real people's.

## Requirement

In full in [requirements/similar-to-andrew-waters-orchard-we-have.md](../requirements/similar-to-andrew-waters-orchard-we-have.md).

**Problem:** gannin.ai, the docs and the README have few or no screenshots, so people can't see what Gannin does before installing it. Maintainers would refresh them after UI changes or a release, but there's no repeatable way to, and a screenshot taken today shows real orgs, people and PRs from GitHub.

**Goal:** One script refreshes a set of screenshots of key screens, from invented data, into the repo where the site and README use them.

**Who it's for:** People evaluating Gannin on gannin.ai, the docs and the README; maintainers who refresh the screenshots.

**Scope:**

1. A capture script that drives the running app to each listed screen and saves a screenshot
2. A way to run the app against invented GitHub data, with no calls to GitHub
3. Three example shots: Workload, one PR or issue detail, Delivery metrics
4. Adding a screen is one new entry, without changing the machinery
5. Each pose captured dark then light, into site/assets/screens/<name>.png and site/assets/screens/light/<name>.png, used by the site, README and docs
6. A sealed demo mode: no GitHub calls, no keychain token, its own Application Support and SwiftData store, and it runs beside the user's real Gannin without quitting it
7. Docs: README and site/index.html show the shots (switching with the reader's theme), three docs-site guide pages embed them, and a contributor doc explains running the capture and adding a screen
8. Simulated Claude Code sessions in demo mode: invented sessions (tabs, working and needs-you states, a fixture transcript, overview and changes) shown from a fixture with no process run

**Out of scope:**

- Screens beyond the three examples (added later, one entry each)
- A demo mode users can switch on from the app
- Running the capture in CI
- Visual regression testing or diffing screenshots
- Faking git repositories or harness content
- A live stand-in claude that streams a conversation in a real terminal

**Acceptance criteria:**

- **R1** When a maintainer runs the capture script, the system shall launch Gannin in demo mode, pose each listed screen and write site/assets/screens/<name>.png (dark) and site/assets/screens/light/<name>.png (light) for each.
- **R2** When Gannin runs in demo mode, the system shall make no requests to GitHub and shall not read the keychain token.
- **R3** When Gannin runs in demo mode, the system shall use its own Application Support folder and SwiftData store, so nothing from the user's real caches, settings, stars or hidden items is shown or changed.
- **R4** When the user's real Gannin is running, the capture shall run beside it without quitting it or ending its Claude Code sessions.
- **R5** When demo mode shows orgs, people, repos, PRs and issues, the system shall show only invented names, avatars and content from a checked-in fixture.
- **R6** When a capture runs, the system shall capture the Workload screen, a PR or issue detail and Delivery metrics, each with enough fixture data that no shot is an empty state.
- **R7** When a maintainer adds a screen, the system shall need only a new shot entry (and fixture data if the screen needs it), with no change to the capture machinery.
- **R8** When the capture script finishes or fails, the system shall restore the user's appearance setting and quit the demo instance.
- **R9** When the work ships, the README, site/index.html (switching with the reader's theme) and the matching docs-site guide pages shall show the shots, and a contributor doc shall explain running the capture, its one-time permissions and adding a screen.
- **R10** When Gannin runs in demo mode, the system shall show invented Claude Code sessions from a checked-in fixture (session tabs in their states, a transcript, overview and changes) without starting claude, git or gh, or calling Anthropic or GitHub.
- **R11** When a capture runs, the system shall also capture a Claude Code session from the fixture, showing a conversation in progress.

**Decisions:**

- What does the lack of screenshots cost today, and who feels it? **The site and README look bare: people can't see what Gannin does before installing. Maintainers are the ones who'd refresh the shots.**
- Which screens does the first pass capture? **Three core screens: Workload, one PR or issue detail, Delivery metrics. The rest are added later, one entry each.**
- Where do screenshots land, in which themes? **One folder, dark and light: site/assets/screens/<name>.png and site/assets/screens/light/<name>.png, each pose captured in both themes back to back.**
- What must the demo environment guarantee? **Sealed and runs beside the real app: no GitHub calls, no keychain token, its own Application Support and SwiftData, never showing or touching the user's real data, and it runs as a separate instance so capturing doesn't quit the user's Gannin or its sessions. Revisited by the room and kept.**
- Which pages and docs change? **README, site/index.html (switching with the reader's theme), three docs-site guide pages for the shots, and a contributor doc on running the capture and adding a screen.**
- Are the requirements right? **Yes, but demo mode must also simulate Claude Code sessions.**
- What does simulating Claude Code sessions cover? **Revisited by the room: static sessions plus one shot. Invented sessions are shown from a fixture with no process run, and a session is a fourth example shot. (Before: a live fake claude streaming a scripted conversation.)**
- Are the requirements right? **Yes (R1 to R11), move to design.**

## Design

**A demo build, sealed at the edges, posed from inside the app.**

1. **Gannin Demo target.** A separate `Gannin Demo` target in `project.yml` sharing the Gannin sources plus `Gannin/Demo/` (fixtures, poses), which only it compiles. It has bundle ID `dev.andon.gannin.demo`, a `DEMO` compilation condition and its own scheme. Its own bundle ID gives it its own UserDefaults and Sessions folder and lets it run beside the real Gannin (R4). The release workflow never builds it, so no demo code ships. `ci.yml` builds it, without capturing, so the fixtures can't rot unnoticed.
2. **One storage root.** Add `AppPaths.support` and move every `URL.applicationSupportDirectory` call site onto it. In demo it points at a throwaway `Application Support/dev.andon.gannin.demo/Data`, wiped on launch, and `UserDatabase` is in memory (R3). A unit test fails if `URL.applicationSupportDirectory` appears outside `AppPaths`.
3. **Network gate.** One `NetworkGate` check in `GitHubAPI.send`, `RequestLimiter`, `ActionsQueries`, `DeviceFlow` and `BankHolidays` that throws in demo, and Sparkle's updater not started. A missed fetch then fails loudly instead of reaching GitHub (R2). In demo, `AuthStore` starts signed in as an invented viewer with a dummy token and never reads the keychain.
4. **Fixtures in Swift.** `Gannin/Demo/DemoFixture.swift` builds invented orgs, people (generated avatars, no real logins), repos, PRs, issues, delivery metrics and sessions as model values. They're seeded into `OrgStore`, `PullRequestStore`, `MetricsStore`, `DetailStore` and `SessionStore` at launch, with sync off. Swift rather than JSON so a model change breaks the build, not the screenshots (R5, R6).
5. **Static sessions.** Fixture sessions are put into `SessionStore` with a state and a transcript; their terminal is a SwiftTerm `TerminalView` fed the transcript bytes, with no process (R10).
6. **Shots as data.** A `DemoShot` enum, one case per shot: file name, window size and a `pose()` that sets the `SidebarItem`, opens a detail or selects a session. The demo build takes `--shot <name> --appearance dark|light`, or a distributed notification so a run doesn't relaunch, and poses itself. It sets `NSApp.appearance` itself, so the system appearance is never flipped and needs no restoring (R8). When settled it writes its window number to a status file. Adding a screen is one case (R7).
7. **`scripts/capture-screenshots.sh`.** Builds Gannin Demo, launches it, and for each shot poses dark, captures with `screencapture -l <window> -o`, poses light and captures, into `site/assets/screens/` and `site/assets/screens/light/` (R1, R6, R11). A trap quits the demo instance on exit or failure (R8). It needs Screen Recording only, not Accessibility or Automation.
8. **Docs.** README, `site/index.html` (light or dark image by `prefers-color-scheme`), three guide pages and `docs/SCREENSHOTS.md` (R9).

**Why not orchard's way exactly:** Gannin has no accessibility identifiers and gets its data from GitHub rather than local services. Posing from inside the app and seeding fixtures avoids both adding identifiers everywhere and a fake GraphQL server that would have to answer every query shape.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/GitHub/GitHubAPI.swift#L162-L200`: Every GraphQL read and write goes through GitHubAPI.send, which posts to api.github.com with the token (reads via RequestLimiter.shared, writes via URLSession.shared). The one place to gate GraphQL.
- `andrew-waters/gannin` `Gannin/Sync/RequestLimiter.swift#L50`: REST and reads go through RequestLimiter, whose sender tests already replace. Other direct URLSession calls: Actions/ActionsQueries.swift, Auth/DeviceFlow.swift, WorkLog/BankHolidays.swift, plus Sparkle's update check. Each must be gated in demo mode.
- `andrew-waters/gannin` `Gannin/Auth/AuthStore.swift#L26-L80`: isSignedIn is token plus a cached viewer, the token from Keychain service dev.andon.gannin.github (Auth/Keychain.swift#L8, hard-coded). Demo mode needs AuthStore to start signed in as an invented viewer without touching the keychain.
- `andrew-waters/gannin` `Gannin/Sync/UserDatabase.swift#L120-L131`: SwiftData store at Application Support/UserData/Gannin.store, already falls back to in-memory. Demo can use an in-memory or demo-rooted store.
- `andrew-waters/gannin` `Gannin/Views/MainView.swift#L128`: SidebarItem is the navigation model (tab, person, repository, issueList, project, and so on). A demo pose can set it directly.
- `andrew-waters/gannin` `Gannin/Sessions/SessionStore.swift#L1566-L1590`: SessionTerminal wraps SwiftTerm's LocalProcessTerminalView, which needs a process. A fixture session needs a terminal fed transcript bytes with no process, so the session view must accept a plain TerminalView or a feed-only mode.

**Patterns to follow:**

- `andrew-waters/orchard` `scripts/capture-screenshots.sh`: Reference: drives the running app through the accessibility API (a small compiled Swift helper, scripts/orchard-ax.swift, presses sidebar rows by accessibility identifier), captures the window with screencapture, poses each shot once and captures it dark then light, writes to site/assets/screens and site/assets/screens/light for both GH Pages and the README. Needs Accessibility, Screen Recording and Automation permission for the terminal.
- `andrew-waters/orchard` `scripts/demo-env-up.sh`: Reference: brings up a real demo environment (containers, cluster, a stub model server) and records what it created so demo-env-down.sh removes only that. Gannin's equivalent must fake GitHub instead, since the data comes from the API.
- `andrew-waters/gannin` `Gannin/App/BundleMove.swift`: Precedent for per-bundle-ID data: UserDefaults domain and the bundle-ID folder follow Bundle.main.bundleIdentifier. A demo bundle ID (dev.andon.gannin.demo) gets its own defaults and Sessions folder and runs beside the real app as a separate LaunchServices app.
- `andrew-waters/gannin` `project.yml`: XcodeGen; one application target, Sparkle and SwiftTerm packages. A demo variant is a second configuration or target with its own PRODUCT_BUNDLE_IDENTIFIER and a DEMO compilation condition, never shipped by release.yml.

**Risks:**

- `andrew-waters/gannin` `Gannin (URL.applicationSupportDirectory, about 15 call sites)`: Stores root their files at URL.applicationSupportDirectory directly (Snapshots, Details.json, Issues, WorkLog, Releases, Projects, Harness, Routines, APIUsage, UserData/Gannin.store and so on), which for this unsandboxed app is the shared ~/Library/Application Support. Only Sessions is under the bundle ID. A different bundle ID alone does not isolate them, so one missed call site would show or overwrite real data in demo mode.
- `andrew-waters/gannin` `Gannin (accessibilityIdentifier)`: No accessibility identifiers anywhere, and no URL scheme. Orchard-style AX navigation would need identifiers added across the sidebar and pages; posing from inside the app avoids that.
- `andrew-waters/gannin` `Gannin/Harness, Gannin/Git`: Harness pages and Repositories read real clones and run git. Out of scope (non-goal); in demo they should show their empty state rather than reading the user's harness.

**Decisions:**

- How is the invented GitHub data provided? **Swift fixtures (DemoFixture.swift) built as model values and seeded into the stores at launch, with sync off.**
- How is the demo build set up? **A separate Gannin Demo target (bundle ID dev.andon.gannin.demo, DEMO condition, own scheme); demo-only code in Gannin/Demo compiles only into it.**
- Is the design right? **Yes, move to tasks.**

## Tasks

1. [andrew-waters/gannin#335](https://github.com/andrew-waters/gannin/issues/335) One storage root for Application Support (satisfies R3)
2. [andrew-waters/gannin#336](https://github.com/andrew-waters/gannin/issues/336) Gannin Demo target with a sealed network and auth (satisfies R2, R3, R4)
3. [andrew-waters/gannin#337](https://github.com/andrew-waters/gannin/issues/337) Demo fixtures for workload, PR detail and delivery metrics (satisfies R5, R6)
4. [andrew-waters/gannin#338](https://github.com/andrew-waters/gannin/issues/338) Fixture Claude Code sessions with a process-free terminal (satisfies R10)
5. [andrew-waters/gannin#339](https://github.com/andrew-waters/gannin/issues/339) DemoShot poses and the capture script (satisfies R1, R4, R6, R7, R8, R11)
6. [andrew-waters/gannin#340](https://github.com/andrew-waters/gannin/issues/340) Show the screenshots and document the capture (satisfies R9)

**Decisions:**

- Are the tasks right? **Yes, the plan is ready.**

## From the room

- We want to revisit "What must the demo environment guarantee?". We said "Sealed and runs beside the real app: no GitHub calls, no keychain token, its own Application Support and SwiftData, never showing or touching the user's real data, and it runs as a separate instance so capturing doesn't quit the user's Gannin or its sessions.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
- they're right but also we need to simulate claude code sessions (requirements)
- We want to revisit "What does simulating Claude Code sessions cover?". We said "A live fake claude: a stand-in binary that streams a scripted conversation in a real session terminal so sessions behave as if live.". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered. (requirements)
