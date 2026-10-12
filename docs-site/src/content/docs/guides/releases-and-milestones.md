---
title: Releases and milestones
description: Download counts, stars, stargazers, milestones and release pages. Nothing here writes to GitHub.
sidebar:
  order: 14
---

Delivery › Releases has two parts, picked with the **Show** control in the toolbar: **Releases**, which is where it opens, and **Milestones**. Everything here is read-only.

It covers repos that aren't archived and were pushed to in the last year. It is fetched only once you've opened the page for an org, then on the interval in Settings › Sync. Refresh includes it from then on.

## Releases

The **Repository** menu picks one repo or **All Repositories**. Clicking a repo in the table does the same, and clicking it again shows them all.

From the top:

- Tiles: downloads, stars, releases and latest. Downloads and stars show the last 30 days once there is that much history.
- **Over time**: downloads over time.
- **Downloads by release month**: each release's downloads so far, by the month it came out.
- **Stars**: a cumulative line, with published releases marked as dashed lines named on hover.
- **New stars by week**, or by month once the history runs past six months.
- **Repositories**, **Releases** and **Stargazers** tables.

A release's Downloads cell lists its assets. Toggle **Pre-releases** to include them.

### Download history

GitHub only keeps a running total of downloads. Gannin records one count a day, so the history starts from your first sync. It can't be fetched again, so Storage's Clear and signing out keep it, and only Erase Everything removes it. Downloads from your website's Download button and from app updates count, if they are release assets.

### Stars and stargazers

Gannin fetches who starred each repo with a release. The first backfill stops at 10,000 stars, counting older ones at its start. Stargazers lists login and name, repo, company, location, followers and when they starred. It has its own search, shows the first 500 in the table's order, and a click opens their GitHub profile. Accounts GitHub won't describe count as stars but aren't listed.

## Milestones

Milestones with the same title in different repos are shown as one: the counts are added up, with the soonest open due date. Progress is GitHub's: closed of all issues and pull requests in the milestone. Gannin adds how many are in progress and how many have a merged PR.

Open milestones come first, by due date: red when overdue, orange within the week. Turn on **Closed too** to include closed ones.

Click one for its page: state, due date, progress, the release that shipped it, each repo's milestone, the description and its issues (In progress, Open and Closed, each with its board status). It can list fewer issues than GitHub counts when closed ones predate the issue history. A release matches a milestone when its tag or name equals the title, ignoring case and a leading v.

A release's page has its tag, dates, author, downloads, Latest, Pre-release and Draft, the milestone it shipped, its assets with their downloads and its notes.
