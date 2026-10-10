---
type: plan
status: in-progress
summary: "A user docs site at gannin.ai/docs (Astro Starlight, deployed with the unchanged landing page): Get started, Concepts with a metrics glossary, ways to run sessions, a Settings reference for every pane and keyboard shortcuts, linked from Help, with app copy fixes and a CI check, issue template and planning prompt to keep it current."
issues: [andrew-waters/gannin#107, andrew-waters/gannin#108, andrew-waters/gannin#109, andrew-waters/gannin#110, andrew-waters/gannin#111, andrew-waters/gannin#112, andrew-waters/gannin#113, andrew-waters/gannin#114, andrew-waters/gannin#115, andrew-waters/gannin#116, andrew-waters/gannin#117, andrew-waters/gannin#118, andrew-waters/gannin#119, andrew-waters/gannin#120, andrew-waters/gannin#121]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-10
requirement: requirements/documentation.md
---

# Documentation

A user docs site at gannin.ai/docs (Astro Starlight, deployed with the unchanged landing page): Get started, Concepts with a metrics glossary, ways to run sessions, a Settings reference for every pane and keyboard shortcuts, linked from Help, with app copy fixes and a CI check, issue template and planning prompt to keep it current.

## Context

- [Plan a documentation site for Gannin, served at alongside the existing landing page (site/index.html), deployed by the same Pages workflow. Gannin now has a lot of configuration and several ways to run, and almost all of it is described only in CLAUDE.md, which is written for developers. The docs are for people using Gannin: what each part does, how to set it up, and what each setting changes, in plain words. Starting point (a suggestion, not the whole list): - Generator: Astro Starlight, with the landing page carried over unchanged as the index, Geist and the site's colours so it reads as one site, and appcast.xml still served at the root for Sparkle. - Get started: install, GitHub sign-in, orgs and projects, what a harness is and Create Harness. - Concepts: where things are kept (this Mac, the harness, GitHub), projects and harnesses, the GitHub rate limit budget. - Ways to run sessions: this Mac, a server over Connect with, a sandbox here, a sandbox on a server; what each needs, protects and how Claude signs in (docs/SANDBOXES.md moves here). - Agents: Work on This, Ask, planning sessions, Attended and Unattended, pair review, Review with Claude, auto review, review config, learnings, prompts and skills. - Using Gannin, following the sidebar: Inbox, Dashboard, Work, Delivery, Team, Rituals. - Settings reference: one page per pane, every option, its default and what it changes. - Harness reference: layout, front matter, every .gannin/*.json team file. - Troubleshooting, privacy and terms (one Claude login per person, never shared). - Linking from the app: Help > Gannin Help and "?" buttons on Settings panes. - Keeping it current: a CLAUDE.md rule that user-facing changes update their docs page in the same PR. That outline is a starting point only. Before settling the structure, scout the codebase to find other important areas it misses or underplays: read CLAUDE.md in full, the Settings views (SettingsView, OrgSettingsView and their panes), the sidebar (OrgSidebar), the Sessions and Sandbox folders, the harness onboarding (HarnessOnboarding, HarnessTour) and the existing docs/ and site/ folders. List what you find that the outline didn't cover, say why each matters to a user, and fold it in or argue for leaving it out. Also decide: what ships in a first phase (enough to answer "how do I configure this" questions) and what follows; how screenshots are made and kept up to date; and whether any setting is confusing enough that the app should change rather than be documented.](http://gannin.ai/docs)

## Requirement

In full in [requirements/documentation.md](../requirements/documentation.md).

**Problem:** Almost everything about using and configuring Gannin is written down only in CLAUDE.md, which is for developers. People using Gannin can't find out what a part does, how to set it up, or what a setting changes, except by asking or reading code.

**Goal:** Anyone using, configuring or evaluating Gannin can answer 'what does this do, how do I set it up, and what does this setting change' from gannin.ai/docs, in plain words, and the docs stay in step with the app.

**Who it's for:** Everyone equally: teammates adopting Gannin in an org, whoever configures an org's projects and settings, and people evaluating it from gannin.ai.

**Scope:**

1. A docs site at gannin.ai/docs, deployed by pages.yml beside the unchanged landing page and appcast.xml
2. Get started: requirements, install, GitHub sign-in and its scopes, orgs and projects, Create Harness
3. Concepts: where things are kept, projects and harnesses, the GitHub rate limit budget, privacy and what leaves the Mac
4. Ways to run sessions: this Mac, a server, a sandbox here, a sandbox on a server (SANDBOXES.md moves here)
5. Settings reference: one page per app and org Settings pane, every option with its default, what it changes and where it's stored
6. Help menu link from the app
7. Fix app copy that contradicts how settings behave (where data is stored, the Sandbox bulk button)
8. Keyboard shortcuts: every shortcut, in menus or not
9. Metrics glossary under Concepts: how each number Gannin shows is worked out
10. Keep current: a CLAUDE.md rule, a CI check that every setting is in the Settings reference, an issue template whose acceptance criteria include docs, and a planning facilitator that asks about docs
11. Follow-up issues for the confusing settings and for phase 2

**Out of scope:**

- Phase 1 leaves out Using Gannin (the sidebar tour), Agents and the Harness reference; they follow in later phases
- Redesigning confusing settings: raised as follow-up issues instead
- Screenshots in phase 1: demo mode and automated capture come in phase 2
- Repositories (local git), the Claude Code window and Recap pages: phase 2, with Using Gannin and Agents
- '?' buttons on Settings panes and Learn More links in empty states

**Acceptance criteria:**

- **R1** When someone opens gannin.ai, the system shall show the landing page as it is today, and gannin.ai/appcast.xml shall still serve the latest release's appcast.
- **R2** When someone opens gannin.ai/docs, the system shall show the docs with navigation and search, in the landing page's fonts and colours, so it reads as one site.
- **R3** When a change to the docs or site is pushed to main, or a release is published, the Pages workflow shall build and deploy the docs with the site; when the docs build fails, it shall deploy nothing.
- **R4** Get started shall cover what Gannin needs (macOS 26; Claude Code, gh and git optional, with what each unlocks), installing and updating, GitHub sign-in and why it asks for each scope, the personal account and orgs, picking a project, and Create Harness.
- **R5** Concepts shall say where each kind of data is kept (this Mac, the harness, GitHub), what projects and harnesses are, how the GitHub rate limit budget and reserve work and what happens when it runs out, and, under privacy, every service Gannin talks to and what it sends, what it writes to GitHub (always confirmed first), and that a Claude login is one per person and never shared.
- **R6** Ways to run sessions shall describe this Mac, a server over Connect with, a sandbox here and a sandbox on a server: what each needs, what it protects and how Claude signs in. docs/SANDBOXES.md's content shall move there, leaving a link.
- **R7** The Settings reference shall have a page for each app Settings pane (General, Sync, Sandbox, Storage) and each org Settings pane, listing every option by its label in the app, its default, what it changes, and whether it's kept on this Mac or in the harness.
- **R8** A Keyboard shortcuts page shall list every shortcut, in the menus or not.
- **R9** A Metrics glossary shall say how each number on the Dashboard, PR flow, Issue flow, Scorecards and CI pages is worked out, and what's left out of it.
- **R10** When someone picks Help › Gannin Help, the app shall open gannin.ai/docs in the browser.
- **R11** Where the app's own text says data is kept only on this device but a harness holds it (Storage, Dates and time off), and on the Repositories bulk button labelled Sandbox, the app shall say what actually happens.
- **R12** When a pull request adds, renames or removes a setting in the Settings views without the Settings reference naming it, CI shall fail and name the setting.
- **R13** CLAUDE.md shall say where the docs live and that a user-facing change updates its docs page in the same pull request.
- **R14** Pages shall name things as the app shows them (labels, menu paths such as Settings › Sync), never by code type or storage key alone.
- **R15** Follow-up issues shall exist for the confusing settings (auto review set in two places, the inverted Ask before recording, Sync rows that can't be turned off, the hidden model default) and for phase 2 (Using Gannin, Agents, Harness reference, Repositories, the Claude Code window, Recap, demo mode and screenshots, per-pane help buttons).
- **R16** When someone opens a new issue on andrew-waters/gannin (on GitHub, in Gannin's New Issue or through the create-issue skill), the issue template shall ask for acceptance criteria and include an item for which docs pages change, or that none do.
- **R17** When a planning session runs with the team's planning facilitator prompt, it shall ask the room which docs pages the work changes and record the answer as a requirement or task.

**Decisions:**

- Whose questions should the first phase answer? **All equally: adopters, org configurers and evaluators, so phase 1 covers a little of everything rather than going deep for one group.**
- What ships in the first phase? **The spine and the Settings reference: Get started, Concepts (where data lives, projects and harnesses, the rate limit budget, privacy), Ways to run sessions (docs/SANDBOXES.md moves here), a page per Settings pane with every option and default, and links from the app's Help menu. Using Gannin, Agents and the Harness reference follow in later phases.**
- Should the app change where settings are wrong or confusing? **Fix wrong copy in phase 1, alongside the Settings reference: Storage's and the time off footer's 'only on this device' when a harness holds the data, and the Repositories 'Sandbox' bulk button that actually clears Needs the Mac. Confusing designs (auto review in two places, the inverted 'Ask before recording', Sync rows that can't be turned off looking ordinary, the hidden model default) become follow-up issues, not changed here.**
- How are screenshots made and kept current? **Automated capture: the app is launched on fixture data and each documented view is captured by a script, so screenshots can be regenerated whenever the UI changes.**
- Does automated screenshot capture ship in phase 1? **No. Phase 1 is text with menu paths (Settings › Sync) and no screenshots. A demo mode on fixture data and a capture script are phase 2, and pages gain screenshots as they're captured.**
- Where do the areas the outline missed go? **Phase 1 adds a Keyboard shortcuts page and a Metrics glossary under Concepts. Work › Repositories, the Claude Code window and Recap join Using Gannin and Agents in phase 2.**
- How does the app link to the docs in phase 1? **Help menu only: Help › Gannin Help opens gannin.ai/docs. Per-pane '?' buttons and Learn More links are left for later.**
- How do the docs stay current? **A CLAUDE.md rule that user-facing changes update their docs page in the same PR, plus a CI check that fails when a setting in the Settings views isn't named in the Settings reference.**
- Is a CLAUDE.md rule and a settings check enough to keep the docs current? **No: keep the CLAUDE.md rule, and also give andrew-waters/gannin an issue template that lists acceptance criteria, docs among them, and have the planning facilitator prompt ask about docs. The earlier approval of the requirements was answered by accident while the room was typing, so they're reopened.**
- Are the requirements right, with R16 and R17? **Yes, approved again; design rechecked against them.**

## Design

**Generator and layout.** An Astro Starlight project in a new top-level `docs-site/` (package.json, a committed lockfile, `astro.config.mjs` with `site: 'https://gannin.ai'` and `base: '/docs'`), pages as Markdown under `docs-site/src/content/docs/`. `site/` and its `index.html` aren't touched, so the landing page stays byte for byte (R1). Starlight brings sidebar navigation and Pagefind search (R2).

**One site.** Starlight's theme tokens set to the landing page's: Geist and Geist Mono from Google Fonts, the #0B6B5C teal accent, its greys, and a header link back to gannin.ai and to Download. Starlight's dark mode stays (the landing page has none), with the accent tuned for it.

**Deploy.** `pages.yml` keeps its shape: rsync `site/` to `_site`, then setup-node (pinned by SHA), `npm ci` and `astro build` in `docs-site/`, output copied to `_site/docs`, then the appcast download. Any failure fails the job, so nothing is deployed (R3). Its `paths` filter adds `docs-site/**`.

**Pages (phase 1).** Get started (Requirements, Install and update, Sign in with GitHub, Orgs and projects, Create a harness), Concepts (Where things are kept, Projects and harnesses, The GitHub budget, Metrics glossary, Privacy and terms), Ways to run sessions (Choosing, This Mac, A server, Sandboxes from docs/SANDBOXES.md, which becomes a link), Settings reference (App: General, Sync, Sandbox, Storage; Org: one page per pane), Keyboard shortcuts. Each Settings page is a table per section: the option as labelled, its default, what it changes, kept on this Mac or in the harness (and which file). Harness onboarding wording (HarnessIntroView, HarnessTour) is reused for Projects and harnesses.

**Keeping current.** A CI job on ubuntu (`docs` in ci.yml, every PR) builds the docs and runs `docs-site/scripts/check-settings.mjs`: a map from each Settings pane's Swift files to its reference page, every literal control label (Toggle, Picker, Stepper, TextField, LabeledContent, Button in those files) and every SyncSource title must appear on that page, with a small reviewed ignore list. It fails naming the label and the page (R12). CLAUDE.md gains a Docs section and the rule (R13). A Markdown issue template, `.github/ISSUE_TEMPLATE/issue.md` (Problem, Proposal, Acceptance criteria with a standing "Docs: which pages change, or none" item, Context), which GitHub, Gannin's New Issue (IssueTemplate) and skills/create-issue.md all pick up; the skill's TODO about the team's preferred body is resolved by pointing at it (R16). `prompts/planning-facilitator.md` gains a bullet: ask which docs pages the work changes, and make it a requirement or task (R17). This harness is the code repo, so it's the same repo, but the prompt is a harness change and goes in its own commit.

**App.** Help › Gannin Help (R10). Copy fixes in StorageSettings and PeopleDates (say the harness when there is one) and the Repositories bulk button (R11).

**Why Starlight.** It's Markdown that agents already write well, search and navigation for free, a static build that drops into the existing Pages job; the cost is a Node toolchain in a Swift repo.

**Areas it touches:**

- `andrew-waters/gannin` `site/index.html`: The landing page: one static HTML file (453 lines), Geist and Geist Mono from Google Fonts, teal #0B6B5C accent on white, no dark mode. Screenshots are still labelled placeholders (site/README.md).
- `andrew-waters/gannin` `.github/workflows/pages.yml`: Pages deploy: rsyncs site/ into _site and downloads the latest release's appcast.xml beside it. Triggered by pushes to site/** and by release.yml. A docs build step would slot in before the upload, and the paths filter would need the docs source added.
- `andrew-waters/gannin` `docs/SANDBOXES.md`: The only user-facing guide today (138 lines), on sandboxed sessions. docs/RELEASING.md is for maintainers and stays.
- `andrew-waters/gannin` `Gannin/Auth/DeviceFlow.swift#L15`: Sign-in asks for read:user read:org repo project. Users will ask why repo (write) and project are needed; the docs should say.
- `andrew-waters/gannin` `project.yml#L4-L5`: Requires macOS 26. Claude Code, gh and git are optional prerequisites found at run time (ClaudeRunner, SessionScript, LocalClones).
- `andrew-waters/gannin` `Gannin/Views/SettingsView.swift`: App Settings: General (appearance, font, account, drafts, hidden; Agent: model, auto review, watch, post, record, send feedback, pair review, menu bar, notify; Claude Code: workspace, Connect with; Prompts: editor, snippets), Sync (reserve, per-source Off/interval rows, lookback 14 days, Actions jobs), Sandbox, Storage. About 45 options in all, defaults readable from @AppStorage.
- `andrew-waters/gannin` `Gannin/Views/OrgSettingsView.swift`: Org Settings panes: Repositories, Projects, People, Working Time, Issues, Investments, Goals, Harness, Hidden. Most are team files in a harness; checkout paths, auto review, recording, sandbox token and Hidden are this Mac only. Nothing in the UI marks which is which.
- `andrew-waters/gannin` `Gannin/Views/MainView.swift#L1216-L1363`: Sidebar: New Ask; Dashboard, Inbox; Work; Delivery; Team; Rituals (includes Recap, missing from the brief's outline); Harness; Agents; then pending changes, sync footer, org and project pickers and the org settings cog.
- `andrew-waters/gannin` `Gannin/App/GanninApp.swift#L148-L164`: Menus: Check for Updates, New Issue, New Window, New Tab, Rename Tab, Command Palette, Next Session Waiting on You. No Help menu item and no help book; nothing in the app links to gannin.ai except the appcast.
- `andrew-waters/gannin` `Gannin/App/GanninApp.swift#L148-L164`: The main WindowGroup's .commands: CommandGroup(after: .appInfo), (replacing: .newItem), (before: .sidebar), SessionCommands. Help › Gannin Help is one more CommandGroup(replacing: .help) opening the URL with NSWorkspace.
- `andrew-waters/gannin` `.github/`: No ISSUE_TEMPLATE folder yet. Gannin's New Issue reads .github/ISSUE_TEMPLATE (IssueTemplate, Markdown or forms) and skills/create-issue.md step 3 follows it, so one template reaches GitHub, the app and agents.
- `andrew-waters/gannin` `prompts/planning-facilitator.md`: The harness's default planning prompt (use: planning). Adding a bullet here makes every planning session ask about docs; it's a harness file, committed separately from the code.

**Patterns to follow:**

- `andrew-waters/gannin` `plans/2026-10-06-serve-site-from-this-repo.md`: How the site came to this repo: appcast is a release asset, not committed; the deploy fails rather than publish a site without one. The docs build must keep that guarantee.
- `andrew-waters/gannin` `Gannin/Harness/HarnessOnboarding.swift#L123`: HarnessIntroView and HarnessTour already explain projects, harnesses and the .gannin files in plain words; HarnessTour.readme is written into new harnesses. The docs' harness pages should share this text or link to it, not restate it differently.
- `andrew-waters/gannin` `Gannin/Views/SyncSettingsView.swift#L231-L261`: The sync-off banner with a Sync Settings link is the one existing in-app pointer to further explanation; a '?' or Learn More link would follow the same shape.
- `andrew-waters/gannin` `.github/workflows/ci.yml`: CI is one macOS 26 job (xcodegen, build, test), with every action pinned by SHA and a grep-based guard step (MARKETING_VERSION placeholder). A docs check can follow that guard style, but belongs in a cheap ubuntu job of its own rather than the macOS one.
- `andrew-waters/gannin` `Gannin/Sync/SyncSettings.swift#L7-L35`: SyncSource lists every Sync row in order (SyncSource.settings), each with a title: the Sync reference page's rows should follow it, and the check can read the titles from here.

**Risks:**

- `andrew-waters/gannin` `CLAUDE.md`: 122 KB of developer notes is the only full description of behaviour; much of it is user-facing knowledge buried in type names. Docs written from it can drift unless something ties changes to pages.
- `andrew-waters/gannin` `Gannin/Views/StorageSettings.swift`: Copy contradicts behaviour: Storage says what's entered is 'Stored only on this device', and Working Time's Dates and time off footer (PeopleDates.swift:509) says 'kept only in this app on this Mac', but with a harness both live in the home harness. Docs can't paper over this; the app copy should change.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L1770-L1834`: Confusing settings: auto review is in General and again per org in Org › Harness ('As in Settings'); 'Ask before recording a session' is stored inverted; the Repositories 'Sandbox' bulk button means clear Needs the Mac; Sync rows that can't be turned off look like the others; Model's 'Claude Code's default' hides what that is.
- `andrew-waters/gannin` `site/index.html`: The landing page has no dark mode and is hand-written HTML; a generator's theme has to be bent to match it, and the index must be carried over byte for byte or redesigned deliberately.
- `andrew-waters/gannin` `GanninTests/`: No UI test target, no SwiftUI previews, no demo or fixture data anywhere in the app. Automated screenshots need a demo mode that fills the stores from fixtures without signing in to GitHub, plus a capture runner. That's real build work, and fixtures need upkeep as models change.
- `andrew-waters/gannin` `Gannin/Sessions/SessionViews.swift#L1655-L1666`: Settings keys are mostly constants on stores (SessionStore.modelKey, AutoReview.enabledKey), some per org (sessionsHarnessPath.<org>), Sync's are built from SyncSource cases, and org settings are OrgConfig fields, not @AppStorage. A check that resolves keys by grep would be brittle; checking the visible control labels in each pane's files is simpler and matches R14.
- `andrew-waters/gannin` `site/CNAME`: A GitHub Pages site has one custom domain (site/CNAME is gannin.ai). docs.gannin.ai would need a second Pages site, so a second repo pushed to from here with a deploy key, or another host. That's the arrangement plans/2026-10-06-serve-site-from-this-repo.md removed (publish-site.yml, SITE_DEPLOY_KEY).
- `andrew-waters/gannin` `Gannin/Views/SyncSettingsView.swift`: Labels built in helpers or from enums (Sync rows, interval names, the Agent section's pickers) aren't literals at the call site, so the label check misses them unless the script reads those enums' titles explicitly, as it does SyncSource's.

**Decisions:**

- Which generator? **Astro Starlight, in docs-site/ with base /docs, lockfile committed, actions pinned by SHA and Dependabot for npm.**
- gannin.ai/docs or docs.gannin.ai? **gannin.ai/docs: same Pages site, deploy and repo. A subdomain would need a second Pages site or host, which the serve-site plan removed.**
- How does the settings check find settings? **By control labels per pane: a Node script maps each pane's Swift files to its reference page and requires every literal control label, and Sync's row titles, on that page, with a reviewed ignore list. Labels built inside helpers can slip past; that's accepted.**
- Is the design right? **Yes, approved.**

## Tasks

1. [andrew-waters/gannin#108](https://github.com/andrew-waters/gannin/issues/108) Docs site: Starlight at gannin.ai/docs, deployed with the landing page (satisfies R1, R2, R3)
2. [andrew-waters/gannin#109](https://github.com/andrew-waters/gannin/issues/109) Say where data is actually kept, and name the Repositories bulk button for what it does (satisfies R11)
3. [andrew-waters/gannin#110](https://github.com/andrew-waters/gannin/issues/110) Docs: Get started (satisfies R4, R14)
4. [andrew-waters/gannin#111](https://github.com/andrew-waters/gannin/issues/111) Docs: Concepts (where things are kept, projects and harnesses, the GitHub budget, privacy and terms) (satisfies R5, R14)
5. [andrew-waters/gannin#112](https://github.com/andrew-waters/gannin/issues/112) Docs: Metrics glossary (satisfies R9, R14)
6. [andrew-waters/gannin#113](https://github.com/andrew-waters/gannin/issues/113) Docs: Ways to run sessions, with the sandbox guide moved in (satisfies R6, R14)
7. [andrew-waters/gannin#114](https://github.com/andrew-waters/gannin/issues/114) Docs: Settings reference for the app's panes (satisfies R7, R14)
8. [andrew-waters/gannin#115](https://github.com/andrew-waters/gannin/issues/115) Docs: Settings reference for the org's panes (satisfies R7, R14)
9. [andrew-waters/gannin#116](https://github.com/andrew-waters/gannin/issues/116) CI: check every Settings control is in the Settings reference (satisfies R12)
10. [andrew-waters/gannin#117](https://github.com/andrew-waters/gannin/issues/117) Docs: Keyboard shortcuts (satisfies R8, R14)
11. [andrew-waters/gannin#118](https://github.com/andrew-waters/gannin/issues/118) Help › Gannin Help opens the docs (satisfies R10)
12. [andrew-waters/gannin#119](https://github.com/andrew-waters/gannin/issues/119) Keep docs current: CLAUDE.md rule and an issue template with acceptance criteria (satisfies R13, R16)
13. [andrew-waters/gannin#120](https://github.com/andrew-waters/gannin/issues/120) Planning facilitator asks about docs (satisfies R17)
14. [andrew-waters/gannin#121](https://github.com/andrew-waters/gannin/issues/121) Raise follow-up issues for confusing settings and phase 2 (satisfies R15)

**Decisions:**

- Are the tasks right? **Yes, approved.**

## From the room

- Back to requirements: add to claude, but gannin itself has an issue template that should list AC. In iddation, the planning faciliator can ask about docs. I was typing when the last question got asked so it got auto answered. Set `phase` to `requirements`, fix it with us and ask us to approve it again, then recheck what came after against it. (design)
- Also consider docs.gannin.ai (design)
