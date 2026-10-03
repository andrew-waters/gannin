# Handover: projects as workspaces (Org › Project)

## Status (3 October 2026)

Built and compiling locally; not yet run by hand, not committed. `CLAUDE.md`'s Harness and
Projects paragraphs describe what's there now, so "What exists today" below is history.

- Answers to the open questions: a project also owns its **recap cadence** and **committed date
  field**; field views, Inbox sections and people stay org-wide. Settings doesn't follow the
  window's project (it's shown with the shared store; projects are edited in Settings ›
  Projects). No "Everything else" scope.
- How the scope reaches views: `OrgConfigStore.scoped(_:)` returns a per-project store sharing
  the app's `Storage`; `MainView` puts it in the window's environment, so the ~140
  `config(for:)` calls needed no changes. `update` on it routes changes to what the project
  keeps of its own into the project (`OrgConfig.separate`).
- Harnesses: `otherHarnesses` is only read now and moves into projects at launch
  (`moveHarnessesToProjects`, skipped until the org's harness is indexed). Mention this in the
  release notes.
- Still to check by hand: the migration on a real config with several harnesses, a session
  started from a project window landing in the project's harness, and Open in New Tab carrying
  the project.

For the agent picking this up. Read the repo's `CLAUDE.md` first: it's the map of the app, and
the parts named here are described there in more detail. Then read this whole document before
changing anything.

## The goal

Make a **project** the unit you work in. A project is a named set of repos that can have its
own harness, workflow board, investments, goals and scorecard. In a window you pick
**Org › Project** in the sidebar footer, and the whole window narrows to that project: the
workload, metrics, issues, Scorecard, CI, Recap, the Harness pages, and the Claude Code sessions
it starts. **All** is everything, as the app behaves today. The org is also the catch-all for
repos no project names.

This merges two features that half-overlap today:

- **Harnesses** (`OrgConfig.harness` plus `otherHarnesses`, each `HarnessConfig` with the
  `repos` it's for). They decide where sessions run and which prompts and skills a session
  gets, but the rest of the app still shows every repo.
- **Projects** (`RepoProject`, `OrgConfig.repoProjects`) with a **Focus** in the account menu
  (`OrgConfigStore.focus`). Focusing narrows everything that filters by repo, but it's per
  account, not per window, and sessions and Harness pages ignore it.

## Decisions already made (with the user)

1. **The structure above.** A project has repos and optionally a harness. Picking it narrows
   the window to it. All is today's behaviour.
2. **Per window, not per account.** One window, flicking between projects with the picker. A
   tab or window opened on another project keeps its project. So the project selection is
   `@SceneStorage`, exactly as `selectedOrg` is, and is carried by Open in New Tab and Open in
   New Window (`NavigationRequest.pending`, `Navigation.swift`).
3. **A project owns more than repos and harness.** Agreed so far: its **workflow board**
   (`IssueWorkflow`), **investments** (`InvestmentConfig`), **goals** (`MetricGoals`) and
   **scorecard measurables** (`[Measurable]`). Each is optional on the project; unset means
   the org's. The user asked whether there are more; see "Open questions" and confirm with
   them before adding any.

## Naming: avoid a collision

"Project" already means a GitHub Projects board in the code: `Gannin/Projects/`,
`ProjectStore`, `@SceneStorage("selectedProject")` (a board number in `MainView`), and
`SidebarItem.project`. The UI calls those **Boards**. Keep the user-facing word **Project** for
the new concept, as agreed, but in code use a distinct name for the selection, such as
`@SceneStorage("workspace")` / `WorkspaceScope`, or keep the existing `RepoProject` type name.
Don't reuse the `selectedProject` key.

## What exists today (verify before relying on it)

- `Gannin/Workload/RepoProjects.swift`: `RepoProject { id, name, repos }`, `RepoExclusion`
  (`contains(repo)`: excluded, or outside the focus), and `RepoProjectsSection` (Settings ›
  Repositories › Projects). Stored as team data in `.gannin/repo-projects.json`
  (`TeamFile.repoProjects`, `HarnessTeamData`).
- `Gannin/Metrics/OrgConfigStore.swift`: `config(for:)` returns `baseConfig(for:)` plus
  `focusRepos` from the account-wide focus; `update` edits `baseConfig` and strips the focus;
  `setFocus`, `focusedProject`, `focus` (UserDefaults `repoFocus`). `OrgConfig.repoExclusion`
  is what about 20 views check instead of `excludedRepos` (grep `repoExclusion`). The fetchers
  (`ActionsStore.sync(excluding:)`, `MetricsStore`, `IssueStore`) fetch for the whole org and
  must stay that way; only views filter.
- Harnesses: `OrgConfig.harnesses`, `harness(covering:)`, `harness(repo:)`, `keepTeamData`,
  `removeHarness`, `updateHarness`; `HarnessStore` keyed by `key(org, repo)`, `loadAll`,
  `combined(org:_:)` (the primary's documents plus others' under `owner/name:path`,
  `HarnessIndex.split`); Settings › Harness (`HarnessSettingsSection`, `HarnessesSection` in
  `HarnessViews.swift`); session starters with a harness picker (`SessionLaunchSheet` in
  `Sessions/SessionLaunch.swift`, `StartSessionButton`, `ReviewWithClaudeButton`,
  `NewPlanningSheet`); checkouts per harness (`SessionStore.harnessPathKey(org, repo:)`).
  Which harness keeps the team data is `OrgConfig.harness` (the first in the list).
- The sidebar footer is `SidebarFooter` in `Views/MainView.swift` (`orgMenu`, with the Focus
  picker currently inside it).
- About 140 calls of `configs.config(for:)` (or `orgConfigs.`) across 46 files read the org's
  settings in views.

## The model to build

```swift
struct RepoProject: Codable, Hashable, Identifiable {   // existing, extended
    var id = UUID()
    var name: String
    var repos: [String]                  // owner/name
    var harness: HarnessConfig?          // nil: the org's harness
    var workflow: IssueWorkflow?         // nil: the org's
    var investments: InvestmentConfig?   // nil: the org's
    var goals: MetricGoals?              // nil: the org's
    var scorecard: [Measurable]?         // nil: the org's measurables
}
```

- Decode new fields with `decodeIfPresent`, as everything in the team data does, so older
  files load.
- A project's harness is the user's own config in today's model (harnesses aren't team data),
  but projects are team data. Decide where `RepoProject.harness` lives: simplest is in the
  project (team data), since a project and its harness belong together for everyone. The
  per-Mac checkout path stays per harness repo, as now.
- `OrgConfig.otherHarnesses` becomes redundant once projects carry harnesses. Migrate (below)
  and then remove it, or keep it only for decoding old configs.
- The **org** is the implicit catch-all: its own harness (`OrgConfig.harness`, which also keeps
  the team data), its own workflow, investments, goals and measurables, and every repo no
  project names.

## The scope, per window

Add a scope that views read instead of the account-wide focus:

- `@SceneStorage("workspace")` in `MainView` (a project ID string; empty is All), beside
  `selectedOrg`. Clear it when the org changes. Put it in the environment
  (`@Entry var workspace: UUID?`, or a small `WorkspaceScope` value with the org and project).
- **Effective config:** give `OrgConfigStore` `config(for org: String, project: UUID?)`, which
  is `baseConfig` with the project applied: `focusRepos = project.repos`, and the project's
  `workflow`, `investments`, `goals` and `scorecard` laid over the org's where set. Then change
  the view call sites from `configs.config(for: org)` to read the scope from the environment.
  A small helper keeps that short, for example a view extension or a `@Environment` value
  that carries a closure. Non-view code (stores, `GanninApp`, `EngineerWatch`) keeps
  `config(for:)` with no project.
- **"Everything else":** All should include every repo. If you also want a pickable "the rest"
  (repos no project names), it's `focusRepos = allKnownRepos - every project's repos`; only add
  it if the user wants it.
- Remove the account-wide focus (`OrgConfigStore.focus`, `setFocus`, the Focus picker in the
  account menu, the `repoFocus` UserDefaults key) once the scope replaces it.
- **Tabs and windows:** Open in New Tab / New Window carry the org, sidebar item and trail
  through `NavigationRequest`; add the project to it so a new tab opens on the same project.
  Tabs already opened on other projects keep theirs, because scene storage is per window.

## Behaviour by area, with a project picked

- **Everything that filters by repo:** already works through `repoExclusion` once
  `focusRepos` comes from the scope rather than the account focus.
- **Harness pages** (`HarnessView`, `HarnessDocumentPage`, `HarnessIssueSection`, sidebar
  counts in `harnessCount`): use the project's harness index only (`harness.index(for:setup)`)
  rather than `combined`. Drop the Harness filter and column. New writes to the project's
  harness. With All, keep today's combined view.
- **Sessions:** Work on This, Review with Claude, Review the Changes and planning start in the
  scope's harness. Skip the harness picker in `SessionLaunchSheet` when a project with a
  harness is picked; with All, route by repo through `harness(covering:)` as now (which should
  then look through projects' harnesses).
- **Issue flow, Investments, Board Hygiene, Prioritisation, Epics:** read the effective
  workflow and investments from the scoped config.
- **Overview goals, Weekly Digest, Scorecard:** read the effective goals and measurables. The
  Scorecard's hand-entered values live on each `Measurable`, so a project's measurables keep
  their own.
- **Sidebar:** the Harness section shows when the scope has a harness (or, with All, when any
  harness exists). Show the project's name under the org in the footer.

## Settings

- **Settings › Projects** (a new org Settings pane, replacing the Projects section under
  Repositories and absorbing the Harnesses list): each project with its name, repos (the token
  picker from `RepoProjectsSection`), harness (none, an existing repo, or Create Harness, with
  branch), and "Use the org's" or "Its own" for workflow, investments and goals. Its own opens
  the existing editors (`IssueWorkflowSection`, `InvestmentCategoriesSection`,
  `GoalsSettingsSection`) bound to the project's copy. Those editors currently take `org:`
  and write through `configs.update`; they need a target (org or project) to read and write.
- **Settings › Harness** keeps the org's harness, team data and checkouts. Prompts and
  authoring stay per harness, so a project's harness shows its prompts in its project page.
- Consider making the Settings window follow the window's scope (editing the picked project's
  workflow, say). Ask the user.

## Migration

On first load with the new model (a flag in UserDefaults, as `BundleMove` and
`migrateFromUserDefaults` do):

- Each `otherHarnesses` entry with repos becomes a project named after the harness repo's
  name, with those repos and that harness. One with no repos becomes a project with no repos.
  Tell the user in the release notes.
- Existing `repoProjects` keep their repos and get no harness. If one has the same repos as a
  converted harness, merge them.
- Drop the account-wide focus.

## Open questions for the user

The user asked "there may be more?" about what a project owns. Candidates, none agreed yet:

- **Field views** (Views): a project's own saved views.
- **Recap cadence**: some teams recap on different rhythms.
- **Prioritisation's committed date field** and **Inbox sections**: per project or per org.
- **People**: a project's team (a GitHub team or a list of logins), so People, Standup, the
  work log and Time off narrow to them. Big, and probably its own piece of work.
- **Working week and leave policy**: almost certainly stay org-wide.

Also ask: whether the Settings window should follow the window's project, and whether All
should offer a pickable "Everything else".

## How to work here

- **Building.** `xcodegen generate` after adding or removing files, then
  `xcodebuild -project Gannin.xcodeproj -scheme Gannin -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation build`.
  Builds are expensive on the user's machine: make the whole set of edits, then build once,
  writing the log to a file and grepping it. Never re-run a build to re-read its result.
- **CI uses Xcode 26.6, an older compiler than the local Xcode 27.** It has rejected code the
  local build accepts. Avoid: a local `let` with the same name as a method called earlier in
  the same scope (it reports a circular reference); passing a main-actor method directly as a
  `Binding` setter (`set: method` crashes the compiler; use `set: { method($0) }`); long
  chained expressions mixing `flatMap`, `+` and `compactMap` (split them). Before tagging a
  release, check CI on `main` is green.
- **Style.** Match the surrounding code: doc comments in plain sentences, no em dashes, en
  dashes or the single-character ellipsis anywhere (code, UI text, docs, commits). No Claude
  attribution in commits or PRs. UI text is plain and specific.
- **Docs.** Update `CLAUDE.md` as you go: the Harness, Projects and Settings paragraphs, and
  this handover's "What exists today" becomes history.
- **Releases.** `docs/RELEASING.md`. A tag `vX.Y.Z` releases; the version comes from the tag.
  Only tag when the user asks.
- **Commits.** The user commits on `sessions-and-harness`, which is kept level with `main`.
  Commit and push only when asked.
