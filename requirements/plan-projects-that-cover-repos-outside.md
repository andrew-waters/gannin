---
type: requirement
status: in-progress
summary: "A project can name repos its account doesn't own, and their open and recently merged PRs, open issues and review requests show on the workload pages as the account's own repos' do, with nothing changing for projects that name none."
issues: [andrew-waters/gannin#170]
plans: [plans/2026-10-10-plan-projects-that-cover-repos-outside.md]
---

# Projects that cover repos outside the account

## Problem

A project can only name repos its account owns (or the org's). An outside collaborator never sees the client's org in Gannin's account list, and a personal account lists only repos it owns, so a client's repos, and open-source repos you contribute to, can't be in any project: their PRs, reviews owed and issues don't show anywhere in Gannin.

## Goal

A project can name repos its account doesn't own, and their open and recently merged PRs, open issues and review requests show on the workload pages as the account's own repos' do, with nothing changing for projects that name none.

## Who it's for

Anyone whose work spans repos their accounts don't own: first an outside collaborator on a client's private repos, then an open-source contributor to someone else's public repo.

## Requirements

1. Name outside repos (owner/name) in a project's repos, saved in its project.json
2. Check an outside repo exists and is readable when it's added
3. Fetch outside repos' PRs and issues into the workload snapshot
4. Show them on Pull Requests, Issues › All, Inbox, the Dashboard's Needs attention and people's load
5. Pages not covered say so for outside repos
6. Writes on outside repos' items behave as today, showing GitHub's reason when refused
7. Sessions on outside repos' issues find their PRs

## Out of scope

- Metrics history, issue history (Issue flow, Investments, Recap, Scorecards from them), work log and Standup for outside repos
- CI (Actions) and Releases for outside repos
- Boards owned by the outside repo's owner
- An account of its own for an outside owner
- People from outside repos on the Team, time off or people's load
- A harness outside the account
- Checking write permission on outside repos up front

## Acceptance criteria

- **R1** When adding a repo to a project, the system shall let you type owner/name for a repo the account doesn't own, beside the account's repos in the picker.
- **R2** When an outside repo is typed, the system shall check with GitHub that it exists and the token can read it before adding it, and when it can't, shall say why and not add it.
- **R3** When a project names an outside repo, the system shall save it in the project's .gannin/project.json with its other repos, and Settings › Projects shall mark it as outside the account.
- **R4** When the workload snapshot is fetched for an account whose projects name outside repos, the system shall include those repos' open PRs, PRs merged in the lookback and open issues, in the full search and the incremental changes search alike.
- **R5** When a window's project names an outside repo, its PRs and issues shall show on Pull Requests, Issues › All, the Inbox, the Dashboard's Needs attention and people's load as the account's own repos' do.
- **R6** When an outside repo's PR or issue involves people who aren't the account's members, the system shall show them as authors, reviewers and assignees in the lists, and give a load only to the account's members.
- **R7** When no project of an account names an outside repo, the system shall send exactly the queries it sends today.
- **R8** When an outside repo stops being readable, the system shall leave it out of searches so the rest still fetch, keep its last items marked stale, mark it Can't be read in Settings › Projects with GitHub's reason, and keep it in project.json.
- **R9** When a window's project names outside repos, pages not covered (metrics, Issue flow, Investments, Recap, Scorecards, work log, Standup, CI, Releases and boards) shall say outside repos aren't covered there.
- **R10** When GitHub refuses a write on an outside repo's item, the system shall show GitHub's reason, writes being confirmed first as today.
- **R11** When outside repos are fetched, their cost shall be charged to the workload in the usage ledger, so Settings › Sync shows it with the rest.
- **R12** When a window's project doesn't name an outside repo, that repo's items shall not show in it.
- **R13** When a Claude Code session works on an outside repo's issue, the system shall find the PRs it opens on that repo for its PRs pane, as it does for the account's own repos.

Planned in [plans/2026-10-10-plan-projects-that-cover-repos-outside.md](../plans/2026-10-10-plan-projects-that-cover-repos-outside.md).
