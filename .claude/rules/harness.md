---
paths:
  - "Gannin/Harness/**"
---

# Harness

## Indexing
- `HarnessStore` indexes a harness from GitHub so everyone sees the same: branch head commit (stops if unchanged), the tree (REST), then changed blobs 30 to a query, parsed off the main thread. Cached in Application Support/Harness as `org@owner~name.json`; every cached index loads at launch. The fetch is the store's own task so a view going away doesn't cancel it.
- Indexes, loading and errors are keyed by `key(org, repo)`. `loadAll` fetches every harness in view; `combined(org:_:)` is the views' index: the first's documents plus the others' under `owner/name:path` (`HarnessIndex.split`, `HarnessDocument.harnessRepo`).
- `HarnessDocument.parserVersion` makes a cached index re-read its documents when parsing changes. The index also reads `.gannin/*.json` beside the documents (`HarnessIndex.dataFiles`).

## Projects and harness resolution
- Every harness is a project (`RepoProject`, identified by its harness's repo). Which harnesses are the org's is the user's own setting (`OrgConfig.harness` = home, then `otherHarnesses`, `projectHarnesses`), changed via `OrgConfigStore.updateHarnesses` (`addHarness`, `removeHarness`, `makeHome`, `updateHarness`). No org-wide harness and no All: every window works in a project.
- `OrgConfig.allHarnesses` = every project's (covering its repos, `RepoProject.ownHarness`); `harnesses` = the window's project's only. `harness(covering:)`: the window's project's, or, from the shared store with no window (notifications, auto review, `baseConfig`), the first naming the PR's repo, else one naming none, else the first. `harness(repo:)` searches all.
- Projects (`Workload/RepoProjects.swift`) live in their harness as `.gannin/project.json` (`ProjectFile`): name, repos (none = every repo), `boardsRepo` (repo whose linked boards the sidebar lists via `ProjectStore.boards(org:repo:)`; nil = every board).
- Window project is `@SceneStorage("workspace")` = harness repo, home when empty (not `selectedProject`, which is a board); carried to new tabs/windows by `NavigationRequest.workspace`; last pick per org on this Mac.
- `MainView` puts the project's store (`OrgConfigStore.scoped`, sharing `Storage` and `root`, which reads home) in the environment, so `configs.config(for:)` is `baseConfig(for:)` (home's, with every project in `repoProjects`) with the project's own laid on (`HarnessTeamData.appliedProject`) and narrowed (`OrgConfig.apply`: `focusRepos`, `scope`).
- Views that drop excluded repos check `repoExclusion`. A project's repos count even when excluded org-wide (it names them). CI fetches skip only excluded repos no project names (`unfetchedRepos`). Fetchers stay org-wide.
- `update` stages each changed file in the right harness (`HarnessTeamStore.stage(org:project:)`: org-wide files to home, the rest to the window's project); `updateProject` stages `project.json`. Make Home offers to copy org-wide files first (`HarnessTeamStore.moveOrgWideData`).
- Legacy: harnesses named by `.gannin/repo-projects.json` in the old org harness, or projects saved on-device, become projects at launch once home is indexed (`OrgConfigStore.adoptProjects`, `OrgConfig` decoding); a harness with no `project.json` takes name and repos from that list.
- Checkouts per harness: `SessionStore.harnessPathKey(org, repo:)`.

## Team data (`HarnessTeamData.swift`)
- JSON under `.gannin/` (`TeamFile`), keys sorted, days as `2026-10-03` (`TeamCoding`). Per project: `project.json`, `investments.json`, `workflow.json`, `goals.json`, `recap.json`, `scorecard.json`, `prioritisation.json`, `triage.json`, `field-notes.json`. Home also holds org-wide (`TeamFile.isOrgWide`): `views.json`, `working-week.json`, `leave.json`, `exclusions.json`, `authoring.json`, `people/<login>.json` (time off incl. sick days). A missing file is the default.
- `HarnessTeamStore` reads one harness at a time (`data(for:in:)`; `data(for:)` for home's) from the user's list; `OrgConfigStore`, `PeopleDatesStore`, `FieldNotesStore` read their parts from it. Only an org with no harness keeps them on-device. Stars, hidden items, app settings and which harnesses are projects stay user-local.
- Edits apply at once and wait as `HarnessTeamStore.pending` (per harness, on disk in Application Support/<bundle ID>/HarnessPending) until `HarnessCommitSheet` commits each harness together or discards. Commit merges each file three ways onto the harness's copy at the head (`TeamCoding.merge`: objects by key, lists of objects by `id`, ours wins a clash) so changes made there since survive. Written content shows until the index catches up.

## Harness writes (`HarnessWrites.swift`, `HarnessStore.commit`)
- Commits go through GraphQL `createCommitOnBranch` (`GitHubAPI.mutate` takes object variables), several files at once with `expectedHeadOid`: texts in `HarnessChange.files`, bytes in `data` up to `HarnessChange.maxDataBytes` (5 MB, refused before sending). If the branch moved, the change is re-planned on the new head and retried once. Then the index is refetched until GitHub reports the new commit as head (`load(expecting:)`, up to five tries, each a second longer apart).
- Every write is confirmed first.

## Documents
- Layout (`HarnessKind`): plans flat in `plans/` (and `requirements/<module>/plans/` until moved), requirements the rest of `requirements/`, `findings/`, `skills/`, `prompts/`, `learnings/<repo>/`, `research/<folder>/README.md` and `refines/<date>-<slug>/README.md` (front matter type `refine`; both `HarnessKind.isRecord`, no New: written by Ask's Commit to Harness and Design and Refine's Agree). Other READMEs and `_templates` are left out. Front matter `type` overrides the folder. Plans/requirements group by first domain else module folder (`HarnessDocument.area`).
- A document is about an issue named in its file name (`prd-123`), header table GitHub row (`owner/name#123`) or front matter `github:`; other issues are mentions. Bare `PRD-123` means the repo the harness names most (`HarnessIndex.issuesRepo`).
- `HarnessFrontMatter` reads `STANDARDS.md` front matter (`type`, `status`, `summary`, `domains`, `issues`, `touches`...): `status` and `issues` first, then the older header table's Status and GitHub rows. `statusLabel` unifies old spellings ("Complete" as "Done").
- Only documents that follow the standard (`followsStandard`: front matter with a summary) are listed, in the Harness page and in an issue's plans and requirements. Session briefs still include older ones.
- `HarnessFrontMatter.setting` edits status/owner/domains against the file at the head (`HarnessDetailsEditor`). Issue references in text (`owner/repo#123`, `#123`, `PRD-123`) become `gannin-issue:` links (`linkedBody`); ones outside the history are looked up by number (`HarnessReferences`, `GitHubAPI.issueOrPullRequest`).

## Prompts
- `prompts/<name>.md` (`HarnessPrompt`, `HarnessPromptLibrary`): front matter `use` (work, review, planning, ask, session; all if omitted), `default`, `repos` (a repo's own defaults replace the general ones), `skills` (by name from `skills/`, `HarnessSkill`). Body placeholders: `{{issue}}`, `{{title}}`, `{{url}}`, `{{repo}}`, `{{number}}`, `{{branch}}`. For a quick change `{{issue}}` says so and `{{number}}`/`{{url}}` are empty.

## Learnings (`HarnessLearnings.swift`)
- `learnings/<repo>/<date>-<slug>.md`, front matter `repo`, `paths` (folders end `/`, files, `path#L10-L24`; none = whole repo, `HarnessLearning.Scope`), `commit`, `source`, `author`, `status` (`active`/`retired`); body `## Rule`, `## Reason`, `## Source`, rule as summary. `HarnessIndex.learnings(for:)` = a repo's active ones; used by review prompts (`reviewInstructions`) and Work on This briefs.
- `HarnessLearningEditor` commits one file only when asked.

## Editors and authoring
- `HarnessNewDocumentSheet` (`HarnessEditors.swift`) dispatches to `HarnessSkillEditor`, `HarnessPromptEditor`, `HarnessLearningEditor`, `HarnessDocumentEditor` (front matter per STANDARDS.md, body from the folder's `_template.md`), or Plan with Claude. Each commits one file.
- `DraftWithClaudeSection`: `ClaudeRunner` conversation, one session per sheet (`--resume`, same folder); guides sent as files on the first message (`HarnessAuthoring.request`); replies are JSON with `message`; the editor's text goes with each later message. Guidance is `OrgConfig.authoring` (`.gannin/authoring.json`) else `HarnessAuthoring.defaultGuidance`. For plans it is the planning session's first prompt (`{{topic}}`, `{{plan}}`, `{{docs}}`, `{{assets}}`, `{{starting_point}}`).

## Create Harness (`HarnessCreate.swift`, `HarnessOnboarding.swift`)
- REST `POST /orgs/{org}/repos` (private, `auto_init` so there's a branch) then one commit of `HarnessSkeleton` (README, starter CLAUDE.md listing repos, generic `STANDARDS.md`, template folders, `.gannin/README.md` from `HarnessTour.readme`, `.gitignore` keeping out `projects/` and `.worktrees/`) with `project.json`. It becomes a project, home if first.
