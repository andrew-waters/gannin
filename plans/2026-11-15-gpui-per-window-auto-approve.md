---
type: plan
status: In Review
summary: In the gpui pilot's scheduler, each review window decides whether its reviews approve by themselves, under optional conditions on author, diff size, effort, findings' severity and a new risk level; otherwise an approve verdict posts as a comment, and why is shown.
issues: [andrew-waters/gannin#579]
domains: [reviews, scheduler]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# gpui pilot: per-window auto-approve with conditions

## Context

The pilot's scheduler has one global **Approve by itself** switch (`Settings.approve_by_itself`).
`auto_post` in `review_panel.rs` posts a window's review when its result is in, and turns `APPROVE`
into `COMMENT` unless that switch is on. A launch doesn't record which window started it. The
`Ran` history is written but nothing on the Schedule page shows it yet.

## Decisions

- **Risk** is a new field in the review JSON: `"risk": "low" | "medium" | "high"`, judged by what
  the change could break if it's wrong (blast radius, data, security, migrations, public APIs), not
  by how big it is. It's kept as `ReviewResult.risk`, and anything other than those three words is
  dropped. The review panel shows it beside the effort.
- **Migration:** if `schedule.json` has `approve_by_itself: true`, every window it holds is set to
  approve with no conditions when the schedule loads. The global field is read but never written
  (`skip_serializing`), so the first save drops it. The header button goes.
- **Conditions are checked at post time only.** `fill_review_window` still picks PRs as now.
- **Size comes from the post-time snapshot.** `review::snapshot` already fetches `pulls/{n}`, which
  has `additions`, `deletions` and `changed_files`, so `Snapshot` keeps them and the author's type
  (bot or not). The size is only unknown if those fields are missing, and an unknown size fails the
  condition (the post then comments).
- **The window is recorded on the launch:** `Launch.window: Option<String>` (`serde(default)`),
  set by `fill_review_window`. If that window has since been deleted, the review comments, with
  that as the reason.
- **Rules** are `ReviewWindow.approve: ApproveRules` (`serde(default)`, off):
  - `enabled`
  - `authors: Vec<String>`: an allow list of logins, matched without case. Empty means anyone.
  - `allow_bots: bool`, default true
  - `max_lines: Option<u32>`: additions plus deletions
  - `max_files: Option<u32>`
  - `max_effort: Option<i64>`: a missing effort fails
  - `block_severity: Option<String>`: no finding at or above it (blocker, major, minor, nit). All of
    the result's findings count, as `auto_post` dismisses none.
  - `max_risk: Option<String>`: a missing risk fails

  An unset condition doesn't restrict.
- **A pure decision function**, `approve::decide(rules, facts, result) -> Result<(), Vec<String>>`
  in a new `src/approve.rs`, gives the reasons for each condition that fails, for example "412
  lines changed, limit 200" or "a major finding". `auto_post` calls it only when `default_event` says
  `APPROVE`. Your own PR and `REQUEST_CHANGES` behave as they do now.
- **The reason is shown** in the review panel's record note ("Commented, not approved: 412 lines
  changed, limit 200"). Each auto post also goes into the schedule's `Ran` history against the
  window (outcome `posted`, note "Approved" or the reasons). The window editor gets a short "Last
  runs" list from that history, so the reason can be seen from the Schedule as well.
- **Editing** happens in the window editor, under an "Approves by itself" toggle that shows the
  conditions when it's on:
  - Authors: a picker menu of the org's members (from the Snapshots cache), with a checkmark on
    each one picked and "Anyone" when none are
  - Allow bots: a toggle
  - Lines and files: "No limit" or a value stepped with − and +
  - Effort: no limit, or 1-5
  - Findings: none, or "no blocker", "no major or worse", "no minor or worse", "no findings"
  - Risk: no limit, low, or medium

  The footnote says what the window does with an approve verdict.

## Tasks

- [x] `risk` in the review prompt's JSON and `ReviewResult`, parsed leniently; shown in the review panel
- [x] `Snapshot` keeps additions, deletions, files changed and whether the author is a bot
- [x] `ApproveRules` on `ReviewWindow`; global setting migrated on load and dropped; header button removed
- [x] `Launch.window`, set when a window starts a review
- [x] `approve::decide` with unit tests for each condition (off, no conditions, author, bots, lines, files, unknown size, effort and missing effort, severity, risk and missing risk)
- [x] `auto_post` uses the window's rules; reason in the record note and the `Ran` history
- [x] Window editor: the toggle, the conditions, the member picker, "Last runs", the footnote
- [x] `gpui-pilot/docs/scheduler.md` updated
