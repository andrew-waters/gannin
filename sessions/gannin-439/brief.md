# andrew-waters/gannin#439: Track time allocated to R&D work on issues so tax credit claims can be reported from them

https://github.com/andrew-waters/gannin/issues/439

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 21 Oct 2026

## Description

## Problem

Part of preparing an R&D tax credit claim is showing how much of the team's time went to qualifying R&D work. At the moment that has to be pieced together by hand after the fact, even though the work itself already lives in the issues Gannin tracks. That makes claims slow to prepare and hard to back up from the original tickets.

This affects whoever prepares the claim (often an engineering lead or founder working with an accountant or adviser). It is not only a UK need: not every Gannin user is in the UK, and other countries run similar schemes (for example the US federal research credit, Canada's SR&ED, Australia's R&D Tax Incentive and Ireland's R&D tax credit). Each scheme has its own rules for what qualifies and what evidence it wants. Those rules have not been researched for this issue.

## Proposal

Let Gannin record how much time is allocated to issues and whether that work counts as R&D, and produce a report from that data for a chosen period.

- **Time only, no money.** Gannin records time allocated (per person, per issue, over a period). It does not store salaries, rates or any other cost data. Turning time into a claim value stays with the user or their adviser.
- **Built on the base tickets.** The report should be traceable back to the issues (and, where useful, their PRs) the time was spent on, so each line can be checked against the work.
- **Not tied to one country.** Avoid hard-coding UK rules or terms. Where scheme-specific fields or wording are needed, keep them configurable or out of scope for a first version.

Undecided, to settle before work starts:

- **How time gets captured.** Entered by hand, estimated from activity Gannin already sees (issue and PR timelines, sessions), or both. Accuracy and how defensible each method is for a claim are both unknown.
- **How work is marked as R&D.** A label, a board field, the existing investment category setting (Settings > How we track investments), or something new. Whether R&D should be one of the investment categories or sit apart from them is open.
- **Granularity.** Per issue, per parent issue or project, per person, and whether partial allocation (say 60% of an issue counts as R&D) is needed.
- **Report period and format.** Claims usually follow the company's accounting period, not the calendar year. Export format (CSV, Markdown, PDF) and which columns an adviser needs are unknown.
- **Who can see it.** Time per person is sensitive. Who can view and export it has not been decided.
- **Which schemes to aim at first.** The UK is the known need; whether to check the first version against any other scheme is open.

## Acceptance criteria

- [ ] Time allocated to an issue can be recorded or derived, per person, without entering any salary or cost data
- [ ] Issues (or parts of them) can be marked as R&D, and the reason or description can be kept with them
- [ ] A report for a chosen date range lists R&D time by issue and by person, with links back to each issue
- [ ] The report can be exported in a format an accountant or adviser can use
- [ ] Nothing in the feature assumes the UK scheme; terms that are scheme-specific are configurable or left out
- [ ] Docs: which pages at gannin.ai/docs change is unknown until the capture method is decided; at least a new page on R&D time tracking and reporting

## Context

- Raised by andrew-waters, who prepares R&D tax credit claims as part of their role.
- Not checked yet for duplicates or related open issues (the search could not be run when this was drafted).
- Not tax advice: the feature records and reports time, and what qualifies under a given scheme is for the claimant and their adviser to decide.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/439-track-time-allocated-to-r-d-work-on/`: give each repo it touches a worktree there, on the branch `439-track-time-allocated-to-r-d-work-on`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/439-track-time-allocated-to-r-d-work-on/<name>" -b 439-track-time-allocated-to-r-d-work-on origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/439-track-time-allocated-to-r-d-work-on/gannin" -b 439-track-time-allocated-to-r-d-work-on origin/HEAD`, and do everything there, the plan included.
- When the change is ready for review (committed, built and checked; before a pull request is opened as ready for review, though a draft is fine), run `.worktrees/439-track-time-allocated-to-r-d-work-on/.gannin/ready-for-review "<what changed and where to look>"` and end your turn. Gannin may have a second agent review it; it can't edit, and its findings come back to you as a message. Fix those you agree with, say why not for the rest, commit, and run the script again. Gannin says when the review has settled, or to carry on without one.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#439" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#439]` and a summary in its front matter as `~/Code/andrew-waters/gannin/STANDARDS.md` sets out, if the harness has one (don't look for it anywhere else), so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/439-track-time-allocated-to-r-d-work-on/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
