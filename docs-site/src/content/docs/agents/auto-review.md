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

## Review windows

Reviews build and run code, so they can slow your Mac while you work. Review windows say when automatic reviews may start: for example weekdays 12:00 to 13:00 and 18:00 to 20:00. Add them under Agents › Routines, in Review windows, with New Routine › New Review Window. Each has a name, the days it opens (working days or days you pick), Opens and Closes (it may cross midnight) and Reviews at once (1 by default).

With no review windows, nothing changes: requests start as above. With windows:

- A request, or a watched review's Look Again, that comes up outside every window waits in the review queue instead of starting. A request's notification says "waiting for a review window"; for a Look Again, the review's entry in While you were away says so.
- When a window opens, the queue is worked through in order, never running more reviews at once than the window's Reviews at once. That counts every automatic review on this Mac, whatever its org, so overlapping windows don't add up.
- A review still running when its window closes finishes. Nothing new starts until a window is open again.
- When a queued review's turn comes, it's skipped, and the reason noted, if the PR was merged, closed or made a draft while it waited, or no longer asks for your review.
- Reviews you start yourself, with Review with Claude, are never held.
- A window Gannin was closed or asleep through is missed: the queue waits for the next one. Pause All on Agents › Routines holds the queue too.

The queue is on Agents › Queue, beside the agent queue: see [Routines](/docs/agents/routines/#the-review-queue). Only you see it; nobody is told on GitHub that their review is queued.

Your review windows are kept in your own file in the org's harness (`people/<login>.json`), so every Mac you use with that harness follows the same windows once the change is committed. Teammates can see them there. A Mac that should behave differently can tick Override on This Mac beside Review windows: that Mac then uses windows of its own, starting from a copy of yours, and leaves your file alone. An org with no harness keeps your windows on this Mac.

Update Gannin on every Mac you use before you set review windows: an older version doesn't know about them, so changing your dates or time off there and committing it drops your windows from the file.

Right after Gannin opens, automatic reviews wait until it knows your windows: you're signed in and the org's harness has loaded. Nothing starts or joins the queue in that moment, so a window can't be missed by starting too early.

## Watching a reviewed PR

With Watch for changes on the review (on by default), Gannin keeps checking the PR. When new commits or comments from others (not yours, not bots') arrive and things have been quiet a while, it asks the reviewer to look again. The reviewer answers the PR author's comments, and other people's only when they disagree with the review or the reviewer disagrees with them. A merged or closed PR stops the watch. How often it checks is under Settings › Sync, Watched reviews.

## What gets posted

By default nothing. An automatic review waits for you to open it and press Post Review. If you turn on Post automatic reviews, Gannin posts them itself, always as a plain comment, never approving or requesting changes (one Claude would approve is held for you instead while it's ready for your approval, as below), and resolves the threads it says are dealt with. Just before posting it fetches the PR's comments and leaves out findings the PR already has, on or near their line or in an earlier review's body, as [Post Review](/docs/agents/reviews/#post-review) does; the review's log entry says how many. If it can't fetch them it posts anyway and the entry says that some comments may repeat. It also skips a review you've already posted with the same body on the same commit, and the entry says so.

## Ready for your approval

When Claude's review says approve, covers the PR's latest commits, and the PR has no draft, failing checks or conflicts, it counts as ready for your approval. Gannin never posts one by itself, even with Post automatic reviews on: the review is held, findings and all, until you sign off. The approval is always yours, and when you give it, the summary and comments go up with it as one review, so nothing appears on the PR twice.

An approving review of a PR that isn't ready (a draft, failing checks or conflicts) isn't held: with Post automatic reviews on, its findings are posted as a comment, as any other automatic review's are. One with nothing to say isn't posted at all.

Such PRs are first in the Inbox (Ready for your approval), at the top of Act now on the Dashboard, and arrive as a notification that counts on the Dock and in Waiting on You. Each row says how many findings the review holds (for example, Claude would approve · 2 findings); Post Review leaves out any the PR already has. Opening one shows the review, with its summary and comments, and starts Post Review on Approve, unless there are commits the review hasn't seen. In Post Review you can edit the body, leave out findings you've dismissed, or post it as a Comment instead. Until you post it, the review's log says it's waiting for you.

## While you were away

The Inbox's While you were away lists what happened on PRs Claude reviewed, one row per review, until you've looked at its tab.

When the PR has merged, right-click its row and choose Finish Review to end the reviewer and keep the review in your history, without opening it. The row leaves the Inbox, as it does when you open the review and choose Finish. Closed PRs that weren't merged don't get the menu item.

## Review config

Review Config, in a repository's bar, sets how reviews go: a profile (Quiet, Chill or Assertive), instructions, a tone, files to skip, instructions for paths, checks (each off, warning or error) and title keywords that automatic reviews skip. You can edit the repo's section in the harness, every repo in the project, or the repo's own `.gannin/review.json` file. Later layers win. Failed checks show in the Overview's tiers.

## Recording reviews

With Record reviews in the harness (Settings › General › Agent, on by default) each review is committed to the harness as a file under `.gannin/reviews/`: who ran it, the verdict, what was posted, and what happened to each finding. [Metrics](/docs/agents/reviews/#metrics) reads them.

For a second agent reviewing a session's own work, see [Pair review](/docs/agents/pair-review/).
