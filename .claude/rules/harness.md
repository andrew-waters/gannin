---
paths:
  - "Gannin/Harness/**"
  - "Gannin/Agents/AgentWorkflows*"
---

# Harness

## Writes
- Every harness write is confirmed first and goes through `HarnessStore.commit` (`createCommitOnBranch` with `expectedHeadOid`). If the branch moved, re-plan on the new head and retry once.
- Binary `data` is capped at `HarnessChange.maxDataBytes`; refuse before sending.
- A branch whose rules require a pull request gets one instead of a direct commit: ask first with `GET repos/{repo}/rules/branches/{branch}` (rulesets only, advisory, so a failed lookup means try a direct commit), and retry once as a pull request if a direct commit is refused for needing one. `APIError.requiresPullRequest` treats both classic branch protection's named refusal and a ruleset's generic "repository rule violations" (GH013) refusal as needing one, since GitHub doesn't always say which rule blocked the push.
- Once the pull request exists the write is done. A merge GitHub refuses (405 or 422) leaves it open and notifies (`HarnessStore.onPullRequestOpened`); never turn that into an error, or a retry opens a second pull request.
- Set Up Harness's Add Missing Files works out what's missing again at the head it commits onto and adds only absent paths: a linked harness is someone's own, so never overwrite a file in it.
- After a commit, refetch the index until GitHub reports the new head (`load(expecting:)`) so writes show without a Refresh.

## Team data (`.gannin/*.json`, `HarnessTeamData.swift`)
- Per project: `project.json`, `investments.json`, `rnd.json`, `workflow.json`, `goals.json`, `recap.json`, `scorecard.json`, `prioritisation.json`, `triage.json`, `field-notes.json`, `agent-workflows.json`. `workflow.json` is the issue workflow; agent workflows are `agent-workflows.json`, so never put them in it. Home only (`TeamFile.isOrgWide`): `views.json`, `working-week.json`, `leave.json`, `accounting.json`, `exclusions.json`, `authoring.json`, `issue-strategy.json`, `people/<login>.json`. A missing file means the default.
- Keys sorted, days as `2026-10-03` (`TeamCoding`). An older Gannin re-encodes a file it changes with only the keys it knows, so a new field is dropped by any Mac not yet updated; say so in the changelog when adding one. Add new fields as optional (`decodeIfPresent`) so older files still decode: `TeamCoding.decode` returns nil on any failure, which reads as the default and drops that file's settings.
- Edits stay pending (`HarnessTeamStore.pending`) until reviewed. Commit merges three ways onto the head's copy (`TeamCoding.merge`: objects by key, object lists by `id`, ours wins), so others' changes survive.
- `update` stages org-wide files to home and the rest to the window's project (`HarnessTeamStore.stage`).
- Stars, hidden items, app settings and which harnesses are projects stay user-local.

## Projects and resolution
- Every window works in a project; there is no org-wide harness and no All. Project = harness repo, in `@SceneStorage("workspace")` (home when empty; not `selectedProject`, which is a board).
- `harness(covering:)` with no window (notifications, auto review, `baseConfig`) picks the first harness naming the PR's repo, else one naming none, else the first. Keep that order.
- A project's repos count even when excluded org-wide. Fetchers stay org-wide; only views narrow via `repoExclusion`, and CI skips only repos no project names (`unfetchedRepos`).
- Per-harness checkouts use `SessionStore.harnessPathKey(org, repo:)`; index keys use `key(org, repo)`.

## Index and documents
- Bump `HarnessDocument.parserVersion` whenever document parsing changes, so cached indexes re-read.
- Document layout and front matter follow the harness's `STANDARDS.md`; keep `HarnessKind` and `HarnessFrontMatter` in step with it and with `HarnessSkeleton`'s templates.
- Only documents with front matter and a summary are listed (`followsStandard`); session briefs still include older ones.
- An issue's documents come from the file name (`prd-123`), header table GitHub row or front matter `github:`; other issues are mentions.
- `research/` and `refines/` are records (`isRecord`): no New, written by Ask's Commit to Harness and Refine's Agree.
- Decisions' `superseded_by` and `plans` are paths in their own harness: resolve them with `HarnessIndex.resolve(_:from:)`, never compare them raw, or a combined index's `owner/name:` prefix breaks the link.
- Onboarding read marks (`HarnessReadMarks`) never leave this Mac: don't commit, sync or report them. Keep their cache out of observation (only `version` is observed), since reading defaults mid-draw must not count as a change.

## Specialists and agent workflows
- A specialist (`specialists/<name>.md`) loads with prose only: list and run it whether or not it follows the standard. Front matter `name`, `provider`, `model`, `focus`; keep unknown fields.
- `agent-workflows.json` is keyed by activity at its top level; skip a workflow or rule this build can't read rather than failing the whole file (`Leniently`), since `TeamCoding.decode` returning nil reads as no workflows at all. A skipped entry is dropped if this Mac saves the file, so say so in the changelog when the shape changes. Every workflow, stage, step and rule has an `id`, which the three-way merge matches lists by.
- A missing file, activity or default is the built-in workflow (`AgentWorkflow.builtIn`), and a plain workflow (`isPlain`) must start exactly what the activity started before workflows.
- Personal specialists, workflows, rules and defaults (`PersonalAgents`, in `UserDatabase`) never go in a harness. Never stage a team `agent-workflows.json` that names a `personal/` specialist (`usesPersonalSpecialist`): it would publish one person's specialist to the team. Defaults are per person: ignore the team file's `default` (`WorkflowLibrary`), so someone new gets the built-in. A team rule only reaches team workflows.
- Never post or record a personal specialist's title: a review names it `ReviewRun.postedTitle` ("Reviewer"), in comments, the summary and the findings later steps see, or the person it's aimed at reads it on their PR.

## Prompts and learnings
- Prompt front matter: `use`, `default`, `repos`, `skills`. Placeholders `{{issue}}`, `{{title}}`, `{{url}}`, `{{repo}}`, `{{number}}`, `{{branch}}`; keep the code that fills them in step (a quick change leaves `{{number}}` and `{{url}}` empty).
- Learnings live at `learnings/<repo>/<date>-<slug>.md` with front matter `repo`, `paths` (folders end `/`), `commit`, `source`, `author`, `status` (`active`/`retired`) and `## Rule`, `## Reason`, `## Source`. Only active ones reach prompts. Editors commit one file, only when asked.

## Testing
- Covered: `HarnessPullRequestTests`, `HarnessRefinesTests`, `HarnessRepoEntryTests`, `HarnessDecisionsTests` (decisions, Suggest Decisions), `OnboardingMapTests` (the map and read marks), `HarnessSetupTests` (starter files missing). Nothing covers `TeamCoding.merge`, front matter parsing or `harness(covering:)`; check by hand: edit team data, commit, and confirm another harness copy survives the merge.
