---
type: plan
status: in-progress
summary: "Cut the pull request CI build job from 10-15 minutes to under 8 (median of 5 runs), by changing ci.yml and project.yml build settings, keeping the required `build` check name."
issues: [andrew-waters/gannin#322, andrew-waters/gannin#323, andrew-waters/gannin#324, andrew-waters/gannin#325, andrew-waters/gannin#326]
touches: [andrew-waters/gannin]
owner: dwrss
agreed_by: [dwrss]
agreed_at: 2026-10-13
requirement: requirements/speeding-up-compile-times.md
---

# Speeding up compile times

Cut the pull request CI build job from 10-15 minutes to under 8 (median of 5 runs), by changing ci.yml and project.yml build settings, keeping the required `build` check name.

## Requirement

In full in [requirements/speeding-up-compile-times.md](../requirements/speeding-up-compile-times.md).

**Problem:** The CI `build` job on every pull request (macos-26 runner: xcodegen, xcodebuild build, then xcodebuild test) takes 10-15 minutes. Authors and reviewers wait on the required `build` check, and reruns are painful.

**Goal:** The CI `build` job finishes in under 8 minutes.

**Who it's for:** Anyone opening or reviewing a pull request in andrew-waters/gannin, plus agents whose PRs wait on the required `build` check.

**Scope:**

1. Changes to .github/workflows/ci.yml (duplicate build work, caching, tool setup).
2. Changes to build settings in project.yml.

**Out of scope:**

- Splitting the app into modules or packages.
- Paid larger runners.
- Local dev builds and agent session builds are not the target (they may benefit incidentally).
- Changes to release builds (release.yml).

**Acceptance criteria:**

- **R1** When a pull request that touches Swift code runs CI, the median `build` job duration over 5 runs, cold-cache runs included, shall be under 8 minutes.
- **R2** When the change is proposed, the pull request shall record the median `build` duration of 5 runs before and 5 runs after.
- **R3** When CI runs on a pull request, the check reported to the main ruleset shall still be named `build`, and a failing build or test shall still fail it.
- **R4** Docs: no pages at gannin.ai/docs change, and no CHANGELOG entry is added, as nothing in the app changes for its users.

**Decisions:**

- Whose compile time is the problem? **CI on pull requests.**
- How slow is it and what does it cost? **10-15 minutes per run; annoying rather than blocking.**
- What counts as fast enough? **Under 8 minutes.**
- What is the smallest version worth shipping? **Workflow plus project settings: ci.yml and project.yml build settings. Module splitting and paid runners are out.**
- How is the target measured? **Median of 5 PR runs.**
- What must stay unchanged? **Only the required `build` check name was named as fixed.**
- Which user docs change? **None.**

## Design

**Where the time goes** (run 38384433961, a PR run of 9 min 6 s): Build the Mac app 6 min 38 s, Run the tests 1 min 54 s, everything else (checkout, xcodegen, SwiftPM cache) about 30 s. The build step is the lever.

**Why the build step is slow.** It builds Debug for `generic/platform=macOS`, which compiles the whole single-module app (237 Swift files) for both arm64 and x86_64. The test step then builds again for `platform=macOS` (arm64 only) into the same `DerivedData`, so the app is effectively compiled for arm64 twice.

**Proposed approach**
1. Keep two steps in the `build` job so a failure shows whether the build or the tests broke, but stop compiling twice: "Build the Mac app" becomes `xcodebuild build-for-testing` for `platform=macOS` (arm64 only, app and test bundle), and "Run the tests" becomes `xcodebuild test-without-building` against the same `DerivedData`. The job name stays `build` (R3), and a failing build or test still fails it.
2. Add CI-only overrides to the `build-for-testing` command: `ONLY_ACTIVE_ARCH=YES`, `DEBUG_INFORMATION_FORMAT=dwarf` (no dSYM generation) and `COMPILER_INDEX_STORE_ENABLE=NO` (no index store, which only Xcode's editor uses). Keep them in ci.yml so local builds and scripts/relaunch.sh are unaffected.
3. Trim setup: `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1` for `brew install xcodegen`.
4. Measure first (a task of its own): record median duration over 5 runs before, then after each change, so each lever is kept only if it pays.

**Not proposed:** caching `DerivedData`. A fresh checkout gives every file a new modification time, so Xcode would likely rebuild anyway, and a cache restore and save costs minutes on a multi-GB directory. Revisit only if the measurements fall short of R1.

**Risk: the x86_64 slice.** release.yml archives a universal build (`generic/platform=macOS`). Today's PR build is the only thing that compiles the Intel slice before a tag. Dropping it means an Intel-only compile error would surface at release time. **Decided with the room: drop the Intel slice from PRs.** The universal build is still exercised by release.yml, so an Intel-only break would surface at release time. That trade-off is accepted.

**Areas it touches:**

- `andrew-waters/gannin` `.github/workflows/ci.yml#L69-L121`: `build` job: SwiftPM cache only, then `xcodebuild build` (generic/platform=macOS, both architectures) and `xcodebuild test` (platform=macOS) into the same DerivedData. This is the file to change.
- `andrew-waters/gannin` `project.yml`: One app target of 237 Swift files plus GanninTests (53 files, hosted in the app), three SwiftPM packages (SwiftTerm, Sparkle, HighlighterSwift). No build-speed settings are set today.

**Patterns to follow:**

- `andrew-waters/gannin` `scripts/relaunch.sh#L17-L28`: Local builds already pass `-derivedDataPath`, `-skipPackagePluginValidation` and `-skipMacroValidation` on the command line rather than in project.yml; CI-only overrides on the command line follow the same pattern.

**Risks:**

- `andrew-waters/gannin` `.github/workflows/release.yml#L140-L150`: Releases archive `generic/platform=macOS` (universal). If PR CI stops compiling x86_64, an Intel-only failure would first show at release.
- `andrew-waters/gannin` `.github/workflows/ci.yml#L1-L14`: The main ruleset requires the `build` check and a skipped job counts as passing; the job name must not change and the job must still run for Swift changes.

**Decisions:**

- Keep compiling the Intel slice on PRs? **No. PRs build and test arm64 only; release.yml still builds universal.**
- One combined xcodebuild test step, or keep build and test separate? **Keep separate steps (build-for-testing, then test-without-building).**

## Tasks

1. [andrew-waters/gannin#323](https://github.com/andrew-waters/gannin/issues/323) Record the CI build baseline (satisfies R2)
2. [andrew-waters/gannin#324](https://github.com/andrew-waters/gannin/issues/324) Build and test arm64 once in the CI build job (satisfies R1, R3, R4)
3. [andrew-waters/gannin#325](https://github.com/andrew-waters/gannin/issues/325) Trim the xcodegen install in CI (satisfies R1)
4. [andrew-waters/gannin#326](https://github.com/andrew-waters/gannin/issues/326) Measure after the change against the 8 minute target (satisfies R1, R2)

**Decisions:**

- Are the tasks right? **Yes; four tasks in andrew-waters/gannin cover R1 to R4.**

## From the room

- Build and test happen in the same image so the tests shouldrun without a rebuild? (design)
