---
type: plan
status: in-progress
summary: "A Keep a Changelog CHANGELOG.md whose section for a version becomes that release's notes on GitHub and in Sparkle (release.yml refuses a tag without one), rendered by Orchard's changelog_to_html.py, and a pull request template whose checklist includes the changelog; the create-pull-request skill fills the template."
issues: [andrew-waters/gannin#179]
domains: [releases]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Releases ship with a changelog, and a PR template checks it

## Context

Gannin's releases take their notes from the tag message, so nothing in the repo records what changed between
versions, and there's no pull request template to remind an author to record a change. The
`create-pull-request` skill has a TODO where the template should be.

This plan was written by a scheduled session with nobody watching, so the issue's unknowns are decided here,
with the reasons, for review in the PR.

## What Orchard already has (the issue's first unknown)

- `CHANGELOG.md` in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format: an `## [Unreleased]`
  section that PRs add to, promoted to `## [x.y.z] - date` at release time (`scripts/release.sh`).
- `.github/scripts/changelog_to_html.py`: prints a version's section as Markdown (`--markdown`, the GitHub
  release body) or small HTML (the Sparkle appcast), and renders a whole file with `--file`.
- `release.yml` builds both the release body and the appcast notes from that section, under a preamble.
- `.github/pull_request_template.md`, whose checklist includes "I've added an entry to `CHANGELOG.md`".

## Decisions

- **Where it lives: both.** `CHANGELOG.md` in the repo is the record; the GitHub release and Sparkle's update
  panel show the version's section. One source, so they can't disagree.
- **Who writes entries: the PR author**, under `## [Unreleased]`, as in Orchard. Notes generated from PR titles
  would need labels nobody applies yet, and read worse.
- **Tied to the tag.** Whoever cuts the release promotes `[Unreleased]` to `[x.y.z] - date` in a PR
  (`scripts/promote-changelog.sh x.y.z` makes the edit), merges it, then tags. `release.yml` stops straight
  away, before building, if `CHANGELOG.md` at the tag has no non-empty `## [x.y.z]` section. A hard stop rather
  than Orchard's fallback line, because the issue asks that every release has an entry.
- **The tag message stays the title**, and any further lines in it become an introduction above the changes
  (as Orchard's preamble does), so tagging works as it did.
- **Reuse Orchard's script as it is** (`changelog_to_html.py`) in place of `release_notes.py`, which it
  covers. Orchard's `release.sh` isn't copied: it bumps `MARKETING_VERSION` and commits to the default branch,
  both of which Gannin rules out. Only its changelog promotion is taken.
- **No user-facing change, no entry.** CI, docs and harness files (plans, sessions, skills) can skip it; the
  checklist has a box to say so.
- **The PR template's checklist**: linked issue (`Closes` or `Part of`); a changelog entry or the skip box;
  built once and tests run; screenshots or a recording for a UI change; `CLAUDE.md` updated when behaviour it
  describes changes; `MARKETING_VERSION` left at `0.0.0`; the Verified section is honest. Its sections are the
  skill's (What, Why, How, Verified, Not in this PR), so the skill just fills the template. Orchard's
  Screenshots / recording section becomes a line in Verified and a checklist item, so the evidence sits with
  the rest of what was checked. "No Claude attribution" stays in the skill's Rules: it's a rule for agents
  rather than every contributor.
- **Backfill** 0.0.1 and 0.0.2 from their tag messages so the file starts complete.

## Tasks

- [x] `CHANGELOG.md` with `[Unreleased]`, 0.0.2 and 0.0.1
- [x] `.github/scripts/changelog_to_html.py` from Orchard, in place of `release_notes.py`
- [x] `release.yml`: check the section exists, build the notes from it and the tag's introduction
- [x] `scripts/promote-changelog.sh`
- [x] `.github/pull_request_template.md`
- [x] `skills/create-pull-request.md` uses the template and checks the changelog
- [x] `docs/RELEASING.md` and `CLAUDE.md` describe the new flow
- [ ] PR reviewed and merged

## Not covered

- A CI check that a PR touching `Gannin/` also touches `CHANGELOG.md`. The checklist asks; a check can follow
  if entries get missed.
