---
title: Review with Claude
description: Have Claude review a pull request, go through its findings, and post one review to GitHub yourself.
sidebar:
  order: 10
---

Review with Claude starts a review session for a pull request. It's on a PR's drawer and window. The reviewer runs in your project's [harness](/docs/concepts/projects-and-harnesses/), can't edit anything, and reads the PR with `gh`. Its tab is a review page, not a terminal.

If you have team prompts or skills for reviews, a sheet first lets you tick which to add, and a note. Starts with no sheet (notifications, the menu bar) use the defaults.

## Overview

The review opens on its Overview:

- **The headline**, and whether the PR can merge, in one sentence (also in the tab's header). It weighs conflicts, draft state, the review decision, checks, open threads and findings you haven't dismissed.
- **Needs attention**, in tiers: Blocking the merge, Fix before merging, Waiting on and Not blocking. Empty tiers are hidden. Each item opens its file, its checks or its thread.
- The walkthrough, the description, and a rail of the PR's own comments and reviews. Ask the reviewer there pastes your question to it and opens the conversation.

When the PR has new commits the review hasn't seen, the Overview says "New commits since this review". Review Again looks at them now.

## Files and findings

The file list has Comments on this PR and the files grouped by the walkthrough's areas. A filter narrows findings by severity or category. Files with learnings are marked (see [Learnings](/docs/agents/learnings/)).

Code in a file's diff is coloured by its language, chosen from the file name: Swift, TypeScript and JavaScript, Go, PHP, Python, JSON, YAML, Markdown and shell (including Dockerfiles). Added and removed lines are marked by the `+` or `-` in a tinted gutter and a lighter tint across the row, so they stay clear in light and dark appearance. Other files, and files too large to colour without slowing the page, show as a plain diff with the whole row tinted.

On each file's diff, findings sit on their lines. For each you can Keep, Edit or Dismiss it. You can also leave comments of your own on any line, and write the summary and verdict. The conversation with the reviewer is beneath.

## Post Review

Post Review sends one review to GitHub as you:

- **Approve**, **Comment** or **Request Changes**. On your own PR only Comment is offered, as GitHub allows nothing else.
- Kept findings and your comments go inline on lines the diff shows. A suggestion becomes a GitHub suggestion block. Anything else goes in the body.
- If the reviewer says threads of yours are now dealt with, Post Review offers them ticked and resolves them after posting. Only unresolved threads you started are resolved.
- When you press Post to GitHub, Gannin first checks the PR for comments added since the review was drafted. A finding is left out, and listed under "left out", when someone has already commented on its line, on the new side of the diff, saying much the same (case, punctuation and suggestion blocks are ignored; the wording has to be nearly the same). Only findings that go inline are checked, not ones that go in the body. If the findings left out change at that point, nothing is posted yet: look over the list and post again. A finding wrongly left out can't be put back from the sheet, so add it as a comment of your own, which is never left out. If the check fails, the error is shown and pressing Post again sends the review without it.
- Record it in the harness saves a record of the review (see [Automatic reviews](/docs/agents/auto-review/)).

Nothing is posted until you press it, unless you've turned on Post automatic reviews. Gannin never approves a PR by itself.

## Finish and Resume

Finish ends the reviewer and removes its checkout, but keeps the review. It then shows under Agents › Reviews after the active ones, opens read-only, and Resume brings it back. PRs that have a review show a badge in the Pull Requests table and the Inbox, which opens its tab.

## Metrics

Agents › Metrics reads the reviews recorded in your project's harnesses, plus any on this Mac not recorded yet. It shows tiles (reviews, Reviewers, findings posted, Acted on, dismissed before posting, effort and Posted to merge), findings by severity and category, reviews a week by reviewer, and Reviewers and Reviews tables, over a range and a reviewer.
