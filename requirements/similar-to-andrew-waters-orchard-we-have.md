---
type: requirement
status: in-progress
summary: "One script refreshes a set of screenshots of key screens, from invented data, into the repo where the site and README use them."
issues: [andrew-waters/gannin#334]
plans: [plans/2026-10-14-similar-to-andrew-waters-orchard-we-have.md]
---

# Screenshot capture with a demo environment

## Problem

gannin.ai, the docs and the README have few or no screenshots, so people can't see what Gannin does before installing it. Maintainers would refresh them after UI changes or a release, but there's no repeatable way to, and a screenshot taken today shows real orgs, people and PRs from GitHub.

## Goal

One script refreshes a set of screenshots of key screens, from invented data, into the repo where the site and README use them.

## Who it's for

People evaluating Gannin on gannin.ai, the docs and the README; maintainers who refresh the screenshots.

## Requirements

1. A capture script that drives the running app to each listed screen and saves a screenshot
2. A way to run the app against invented GitHub data, with no calls to GitHub
3. Three example shots: Workload, one PR or issue detail, Delivery metrics
4. Adding a screen is one new entry, without changing the machinery
5. Each pose captured dark then light, into site/assets/screens/<name>-dark.png and site/assets/screens/<name>-light.png, used by the site, README and docs
6. A sealed demo mode: no GitHub calls, no keychain token, its own Application Support and SwiftData store, and it runs beside the user's real Gannin without quitting it
7. Docs: README and site/index.html show the shots (switching with the reader's theme), three docs-site guide pages embed them, and a contributor doc explains running the capture and adding a screen
8. Simulated Claude Code sessions in demo mode: invented sessions (tabs, working and needs-you states, a fixture transcript, overview and changes) shown from a fixture with no process run

## Out of scope

- Screens beyond the three examples (added later, one entry each)
- A demo mode users can switch on from the app
- Running the capture in CI
- Visual regression testing or diffing screenshots
- Faking git repositories or harness content
- A live stand-in claude that streams a conversation in a real terminal

## Acceptance criteria

- **R1** When a maintainer runs the capture script, the system shall launch Gannin in demo mode, pose each listed screen and write site/assets/screens/<name>-dark.png and site/assets/screens/<name>-light.png for each.
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

Planned in [plans/2026-10-14-similar-to-andrew-waters-orchard-we-have.md](../plans/2026-10-14-similar-to-andrew-waters-orchard-we-have.md).
