---
type: plan
status: Done
summary: Planning's Agree never offers a repo with issues turned off, and files issues by an org-wide issue strategy kept in the home harness, either one central repo or each in its own repo collected on a project.
issues: [andrew-waters/gannin#472]
domains: [planning, issues, harness]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Planning follows the org's issue strategy

## Context

Agree built its repo list from the repos the plan named, the project's repos and the busiest
ones, with no check that a repo accepts issues, so it offered repos where an issue can't be filed.
Claude chose each task's repo during the session with no idea how the org keeps its issues. Orgs
differ: some file every issue in one repo (a `product` repo), others file each in the repo it
touches and collect them on a board.

## Decisions

- The strategy is org-wide, in the home harness as `.gannin/issue-strategy.json`, beside
  exclusions and the working week, so everyone on the org reads the same one. No file means
  Per repo, which is the old behaviour plus the issues-off filter.
- Per repo names its own project, defaulting to the project's Issue workflow board, so existing
  setups add issues to the same board as before.
- Under Central repo, a task's `repo` still means where its work is, so the plan's `touches` stays
  right; the issue is filed in the central repo and its body names the code repo. The Issue
  workflow board still gets each issue.
- Whether a repo accepts issues is looked up at Agree in one aliased query. It's advisory: a failed
  lookup filters nothing, and `createIssue` still reports its own error. A central repo with issues
  off stays offered, with a warning, so the choice is visible.
- Claude is told the strategy in the planning instructions: under Central repo it needn't weigh
  which repos accept issues; under Per repo it checks with `gh repo view --json hasIssuesEnabled`.
- Only planning follows the strategy for now. New Issue, Draft Issues, Quick Change, Refine Agree
  and `skills/create-issue.md` are a follow-up. No exceptions to the central repo: Agree's pickers
  stay editable for the odd one.

## Tasks

- [x] `IssueStrategy` (lenient decoding, central repo, board, filing repos) and its org-wide team file
- [x] `GitHubAPI.reposWithIssuesOff`, one aliased read
- [x] Org settings › Issues › Where issues go: Strategy, Repository, Project, with a warning when the central repo has issues off
- [x] Agree: filter repos with issues off, file under the central repo, say why a repo changed, add to the strategy's board
- [x] Planning instructions follow the strategy
- [x] `IssueStrategyTests`
- [x] Docs (Issues settings, Planning, Harness settings, Where things are kept), rules and CHANGELOG
