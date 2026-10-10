---
type: requirement
status: in-progress
summary: "Anyone using, configuring or evaluating Gannin can answer 'what does this do, how do I set it up, and what does this setting change' from gannin.ai/docs, in plain words, and the docs stay in step with the app."
issues: [andrew-waters/gannin#107]
plans: [plans/2026-10-10-documentation.md]
---

# Documentation

## Problem

Almost everything about using and configuring Gannin is written down only in CLAUDE.md, which is for developers. People using Gannin can't find out what a part does, how to set it up, or what a setting changes, except by asking or reading code.

## Goal

Anyone using, configuring or evaluating Gannin can answer 'what does this do, how do I set it up, and what does this setting change' from gannin.ai/docs, in plain words, and the docs stay in step with the app.

## Who it's for

Everyone equally: teammates adopting Gannin in an org, whoever configures an org's projects and settings, and people evaluating it from gannin.ai.

## Requirements

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

## Out of scope

- Phase 1 leaves out Using Gannin (the sidebar tour), Agents and the Harness reference; they follow in later phases
- Redesigning confusing settings: raised as follow-up issues instead
- Screenshots in phase 1: demo mode and automated capture come in phase 2
- Repositories (local git), the Claude Code window and Recap pages: phase 2, with Using Gannin and Agents
- '?' buttons on Settings panes and Learn More links in empty states

## Acceptance criteria

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

Planned in [plans/2026-10-10-documentation.md](../plans/2026-10-10-documentation.md).
