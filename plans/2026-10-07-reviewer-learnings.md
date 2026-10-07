---
type: plan
status: In Review
summary: Keep the reasons people give in review as scoped learnings in the harness, have Claude's reviews follow them and say where, and let people capture, challenge and edit them from Gannin.
issues: [andrew-waters/gannin#37]
domains: [harness, reviews]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Reviewer learnings

## Context

When someone explains in review why code is the way it is, the reason stays in the PR thread.
Later reviews, Claude's included, don't see it, so the same questions and the same wrong
suggestions come back.

## Decisions

- Learnings are a harness kind of their own: `learnings/<repo>/YYYY-MM-DD-<slug>.md`, front matter
  `repo`, `paths`, `commit`, `source`, `author`, `status` (`active`, `retired`), the rule as the
  summary, and Rule, Reason and Source sections. The format is in `learnings/README.md` here and in
  the skeleton for new harnesses.
- Scopes are folders (ending `/`), files or `path#L10-L24`. Lines record the commit they were
  given at. Gannin matches on the file, and on the lines when a diff shows them. The reviewer
  checks the code still fits and says when one looks stale. Symbols aren't anchored for now.
- Captures happen both ways. A person can press Save as Learning on a PR comment or a review
  thread, and the reviewer suggests learnings from what people explained in the PR. Both open an
  editor, with Draft with Claude, and nothing is written until Commit to Harness.
- Writes are direct commits to the harness, like every other harness document.
- Review with Claude (and automatic reviews) gets the PR repo's active learnings. The helper
  reviewer gets the harness's, and Work on This briefs list those for the issue's repos.
- The reviewer says which learnings it applied and how (`applied`, with a `concern` when in
  doubt). The review tab shows them on the diff, with Challenge (your objection, sent to the
  reviewer to look again) and Edit Learning (change or retire it).
- Stale or contradicting learnings are flagged by the reviewer in its summary or as a concern,
  and retired through Edit Learning by anyone who can push to the harness.

## Tasks

- [x] `HarnessKind.learnings`, `HarnessLearning` (scopes, matching) and the index lookup
- [x] `HarnessLearningEditor`, Save as Learning and Edit Learning, guidance for Draft with Claude
- [x] Review prompts list the learnings; the review JSON gains `applied` and `learnings`
- [x] Review tab: Learnings row, learnings matched onto the diff, applied ones with Challenge and Edit
- [x] Capture from drawer comments and the PRs pane's review threads
- [x] Learnings in Work on This briefs, and on a learning's own page
- [x] `learnings/README.md` and `_template.md`, here and in the skeleton; CLAUDE.md
- [ ] Try it end to end in the app: capture one, review a PR that it covers, challenge it
