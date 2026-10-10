---
title: Metrics glossary
description: How each number on the Dashboard, PR flow, Issue flow, Scorecards and CI pages is worked out, and what's left out.
sidebar:
  order: 4
---

## What every metric shares

- **The window.** The metrics pages share a window picked in the toolbar: a number of days, or this or last month, quarter or year. Changes are against **the period before**: as many days before, or the same stretch of the previous month, quarter or year (the whole one before, for a whole one). A change only shows once the history reaches back that far.
- **Medians and p75, not averages.** Half of PRs were quicker than the median; three in four were quicker than the p75. One very slow PR doesn't drag them about as it would an average.
- **Left out everywhere:** repos and people unticked in Org settings › Repositories and People, PRs and issues you've hidden, and the repos outside the window's project. Draft PRs are left out of the workload when Exclude drafts is on (Settings › General).
- **Bots:** PRs by bot accounts, and by logins ending `-bot` or `[bot]`, are left out of the PR metrics, unless re-included in the org's settings. Bot reviews never count as a first review.

## Pull requests (Dashboard and PR flow)

| Metric | How it's worked out | Left out |
| --- | --- | --- |
| Cycle time | First commit (or the PR's creation, if earlier) to merge. | Unmerged PRs. |
| Time to first review (TTFR) | Ready for review (or creation) to the first review by someone who isn't the author or a bot. | PRs merged with no review. |
| Coding | First commit to ready for review. | |
| Waiting for review | Ready for review to the first review. | |
| Rework | First review to the *last* approval before merge. | Stages most PRs skip show the share of PRs that had one and the median when it happened. |
| Merging | Last approval to merge. | |
| PRs merged (throughput) | PRs merged in the window. | |
| PRs opened | A count from GitHub's search. | It ignores the org's exclusions. |
| Merged without review | PRs merged with no approving review, as a share of merged PRs. | Repos marked No Review in Org settings › Repositories. |
| Size and Files | Each person's median lines changed (added plus removed) and files changed per PR merged in the window. A large PR is over 400 lines. | |
| Rushed large PRs | Large PRs approved within 15 minutes with nothing asked, or merged unreviewed. | |

## Reviewers

- **Requests answered** and **time to review** come from review requests: each is matched to that reviewer's first review between the request and merge. The clock starts at the request, or at ready for review if that's later. Requests withdrawn before an answer are dropped.
- **Waiting now** is review requests still open on open PRs.
- The team filter applies to the reviewer, not the PR's author.

## The workload (Dashboard's Team, Inbox, People)

- **In flight** for a person is their open PRs, the reviews requested of them, and assigned issues with an open PR. Assigned issues nobody has started are backlog and not counted. An issue closed by one of their own PRs counts once.
- **Stale** PRs are open ones not updated for 7 days or more.

## Needs attention (Dashboard)

Items ranked into Act now, Today and Keep an eye on: CI red on a default branch, scorecard goals off target, review requests waiting over a day or on someone off today, approved PRs not merged, changes asked for and not answered, stale PRs, committed issues overdue, and people carrying far more than usual.

## Issues (Issue flow)

The issue workflow in Org settings › Issues picks the board and which of its statuses count as in progress.

| Metric | How it's worked out |
| --- | --- |
| Cycle time | Time spent in the in-progress statuses. Moving to any other status (Done, Backlog) or closing stops the clock; coming back starts it again. With the fallback on, an issue never moved on the board uses its first linked PR. |
| Lead time | Created to closed as completed. |
| Flow efficiency | The share of in-progress days with activity on a linked PR. |
| Scope creep | The share of sub-issues added after work started. |

Issues closed as not planned are left out of cycle and lead time.

## Scorecards

Each goal has a cadence (weekly, monthly, quarterly, annual), a source and a target (at least or at most).

- A goal is judged on its **last whole period**. The period under way is shaded and judged on its share so far.
- A count's target is held to the column's length: 20 a week is about 3 a day when viewed by day.
- **Hit** is how many whole periods were on target.
- Hand-entered numbers are judged only in their own periods, and added up (unjudged) in longer ones.
- From other sources: reviews waiting over a day (requested in the period and answered after a day, or never), open PRs at the period's end, issue cycle time (as above), and flaky CI runs (below).

## CI (GitHub Actions)

| Metric | How it's worked out | Left out |
| --- | --- | --- |
| Success and failure rates | Failure includes timed out and startup failure. | Cancelled and skipped runs. Only a run's latest attempt is listed. |
| Duration | The latest attempt's start to its last update; p50, p75 and p90. | |
| Run time | Wall-clock time of runs, by repo, workflow or job. | |
| Re-runs | Runs with more than one attempt. | |
| Flaky | A run that passed only on a re-run, or a commit with both a failed and a passing run. | |
| Default branch health | Runs on the default branch outside PRs: red now and since when, and time back to green. | |
| Needs attention | Red default branches, often-failing ones, flaky workflows, and ones 25% slower in the window's second half. | Failures on PRs alone: that's CI doing its job. |

Runs older than 190 days are dropped, and excluded repos aren't fetched.
