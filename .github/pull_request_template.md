Closes <!-- owner/repo#123, or "Part of owner/repo#123" when this doesn't finish the issue -->

## What

<!-- What changes for the person using it, in a few sentences. -->

## Why

<!-- The problem from the issue, and any decision made along the way (link the plan if there is one). -->

## How

<!-- The approach and where to start reading: the main types and files. -->

## Verified

<!-- What was built or tested and how; what wasn't, and why. For a UI change, before and after screenshots or a short recording. -->

## Not in this PR

<!-- Anything from the issue left for later, with its issue if there is one. -->

## Checklist

- [ ] The first line names the issue: `Closes` when this finishes it, `Part of` when it doesn't
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]` (Added, Changed or Fixed)
- [ ] No user-facing change (CI, docs, harness files), so no changelog entry
- [ ] Built once with the change complete, and the tests run (`xcodebuild test`), or Verified says why not
- [ ] `CLAUDE.md` is updated where this changes behaviour it describes
- [ ] `project.yml` keeps `MARKETING_VERSION` at `0.0.0` (releases take the version from the tag)
- [ ] No UI change, or Verified has before and after screenshots or a recording
- [ ] Verified says honestly what was and wasn't checked
