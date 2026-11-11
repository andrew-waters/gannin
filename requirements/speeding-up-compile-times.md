---
type: requirement
status: in-progress
summary: "The CI `build` job finishes in under 8 minutes."
issues: [andrew-waters/gannin#322]
plans: [plans/2026-10-13-speeding-up-compile-times.md]
---

# Speeding up compile times

## Problem

The CI `build` job on every pull request (macos-26 runner: xcodegen, xcodebuild build, then xcodebuild test) takes 10-15 minutes. Authors and reviewers wait on the required `build` check, and reruns are painful.

## Goal

The CI `build` job finishes in under 8 minutes.

## Who it's for

Anyone opening or reviewing a pull request in andrew-waters/gannin, plus agents whose PRs wait on the required `build` check.

## Requirements

1. Changes to .github/workflows/ci.yml (duplicate build work, caching, tool setup).
2. Changes to build settings in project.yml.

## Out of scope

- Splitting the app into modules or packages.
- Paid larger runners.
- Local dev builds and agent session builds are not the target (they may benefit incidentally).
- Changes to release builds (release.yml).

## Acceptance criteria

- **R1** When a pull request that touches Swift code runs CI, the median `build` job duration over 5 runs, cold-cache runs included, shall be under 8 minutes.
- **R2** When the change is proposed, the pull request shall record the median `build` duration of 5 runs before and 5 runs after.
- **R3** When CI runs on a pull request, the check reported to the main ruleset shall still be named `build`, and a failing build or test shall still fail it.
- **R4** Docs: no pages at gannin.ai/docs change, and no CHANGELOG entry is added, as nothing in the app changes for its users.

Planned in [plans/2026-10-13-speeding-up-compile-times.md](../plans/2026-10-13-speeding-up-compile-times.md).
