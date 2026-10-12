---
title: Automatic reviews
description: Let Gannin review PRs you're asked to review in the background, keep watching them, and tell you when one is ready for your approval.
sidebar:
  order: 11
---

Gannin can start a [review](/docs/agents/reviews/) for you when someone asks for yours. It never approves a PR by itself, and nothing goes to GitHub without you unless Post automatic reviews is on.

## Turning it on

Settings › General › Agent has Review requests automatically. An org can choose its own in Settings › Harness: on, off, or the default. These are yours alone, on this Mac.

A review request is reviewed this way once. Drafts, ones you've dismissed, ones already reviewed, and PRs whose title contains a skip keyword (see below) are left alone. Reviews run in the background with no tab, two at a time. Others wait for a later check. Review requests are found every few minutes (Settings › Sync, Your reviews and PRs).

## Watching a reviewed PR

With Watch for changes on the review (on by default), Gannin keeps checking the PR. When new commits or comments from others (not yours, not bots') arrive and things have been quiet a while, it asks the reviewer to look again. A merged or closed PR stops the watch. How often it checks is under Settings › Sync, Watched reviews.

## What gets posted

By default nothing. An automatic review waits for you to open it and press Post Review. If you turn on Post automatic reviews, Gannin posts them itself, always as a plain comment, never approving or requesting changes, and resolves the threads it says are dealt with.

## Ready for your approval

When Claude's review says approve, covers the PR's latest commits, and the PR has no draft, failing checks or conflicts, it counts as ready for your approval. A review that would approve with nothing to say isn't posted at all. The approval is always yours.

Such PRs are first in the Inbox (Ready for your approval), at the top of Act now on the Dashboard, and arrive as a notification that counts on the Dock and in Waiting on You. Opening one starts Post Review on Approve, unless there are commits the review hasn't seen.

## While you were away

The Inbox's While you were away lists what happened on PRs Claude reviewed, one row per review, until you've looked at its tab.

## Review config

Review Config, in a repository's bar, sets how reviews go: a profile (Quiet, Chill or Assertive), instructions, a tone, files to skip, instructions for paths, checks (each off, warning or error) and title keywords that automatic reviews skip. You can edit the repo's section in the harness, every repo in the project, or the repo's own `.gannin/review.json` file. Later layers win. Failed checks show in the Overview's tiers.

## Recording reviews

With Record reviews in the harness (Settings › General › Agent, on by default) each review is committed to the harness as a file under `.gannin/reviews/`: who ran it, the verdict, what was posted, and what happened to each finding. [Metrics](/docs/agents/reviews/#metrics) reads them.

For a second agent reviewing a session's own work, see [Pair review](/docs/agents/pair-review/).
