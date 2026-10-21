---
paths:
  - "Gannin/Harness/**"
---

# Harness

## Writes
- Every harness write is confirmed first and goes through `HarnessStore.commit` (`createCommitOnBranch` with `expectedHeadOid`). If the branch moved, re-plan on the new head and retry once.
- Binary `data` is capped at `HarnessChange.maxDataBytes`; refuse before sending.
- A branch whose rules require a pull request gets one instead of a direct commit: ask first with `GET repos/{repo}/rules/branches/{branch}` (rulesets only, advisory, so a failed lookup means try a direct commit), and retry once as a pull request if a direct commit is refused for needing one. `APIError.requiresPullRequest` treats both classic branch protection's named refusal and a ruleset's generic "repository rule violations" (GH013) refusal as needing one, since GitHub doesn't always say which rule blocked the push.
- Once the pull request exists the write is done. A merge GitHub refuses (405 or 422) leaves it open and notifies (`HarnessStore.onPullRequestOpened`); never turn that into an error, or a retry opens a second pull request.
- After a commit, refetch the index until GitHub reports the new head (`load(expecting:)`) so writes show without a Refresh.

## Team data (`.gannin/*.json`, `HarnessTeamData.swift`)
- Per project: `project.json`, `investments.json`, `rnd.json`, `workflow.json`, `goals.json`, `recap.json`, `scorecard.json`, `prioritisation.json`, `triage.json`, `field-notes.json`. Home only (`TeamFile.isOrgWide`): `views.json`, `working-week.json`, `leave.json`, `accounting.json`, `exclusions.json`, `authoring.json`, `people/<login>.json`. A missing file means the default.
- Keys sorted, days as `2026-10-03` (`TeamCoding`). Add new fields as optional (`decodeIfPresent`) so older files still decode: `TeamCoding.decode` returns nil on any failure, which reads as the default and drops that file's settings.
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

## Prompts and learnings
- Prompt front matter: `use`, `default`, `repos`, `skills`. Placeholders `{{issue}}`, `{{title}}`, `{{url}}`, `{{repo}}`, `{{number}}`, `{{branch}}`; keep the code that fills them in step (a quick change leaves `{{number}}` and `{{url}}` empty).
- Learnings live at `learnings/<repo>/<date>-<slug>.md` with front matter `repo`, `paths` (folders end `/`), `commit`, `source`, `author`, `status` (`active`/`retired`) and `## Rule`, `## Reason`, `## Source`. Only active ones reach prompts. Editors commit one file, only when asked.

## Testing
- Covered: `HarnessPullRequestTests`, `HarnessRefinesTests`, `HarnessRepoEntryTests`, `HarnessDecisionsTests` (decisions, Suggest Decisions), `OnboardingMapTests` (the map and read marks). Nothing covers `TeamCoding.merge`, front matter parsing or `harness(covering:)`; check by hand: edit team data, commit, and confirm another harness copy survives the merge.
