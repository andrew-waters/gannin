---
title: Storage settings
description: Every option in Settings › Storage, covering caches, what you have entered, and erasing everything.
sidebar:
  order: 4
---

Settings › Storage shows what Gannin keeps on this Mac, in two kinds. Caches are copies of what was fetched from GitHub, and can be cleared and fetched again. What you have entered in Gannin exists only here, so deleting it asks first. Everything on this page is kept on this Mac only.

## Fetched from GitHub

Caches are kept so pages open warm. Cleared data is fetched again when a page next needs it, or on Refresh (⌘R). A large org's history can take a few minutes. Each row shows its size on disk, or Empty, and a Clear button that is greyed out when there is nothing to clear.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Workload snapshots | Fills as you use the app | Members, teams, open and recently merged PRs, and open issues, per org. | This Mac |
| Merged PR history | Fills as you use the app | Merged PRs with their review timings, behind the delivery and people stats. | This Mac |
| Issue history | Fills as you use the app | Issues with their board history, behind the issue metrics and investments. | This Mac |
| Issue search index | Fills as you use the app | Issues' descriptions and recent comments, for searching them. | This Mac |
| Work log | Fills as you use the app | PRs with their commits and reviews, behind Activity. | This Mac |
| Project boards | Fills as you use the app | Project board definitions and items. | This Mac |
| Actions runs | Fills as you use the app | Workflow runs and the jobs of those opened, behind Actions. | This Mac |
| Milestones and releases | Fills as you use the app | Milestones, every GitHub Release and stars per repository, behind Releases. The daily download totals are kept. | This Mac |
| PR and issue details | Fills as you use the app | Bodies, comments and checks of items you have opened. | This Mac |
| Bank holidays | Fills as you use the app | Public holidays by country and year, from date.nager.at. | This Mac |
| Clear | Not applicable | Empties that one cache. | This Mac |
| Total | Sum of the rows | The size of every cache together. Read only. | This Mac |
| Clear All Caches | Not applicable | Empties every cache after you confirm. Everything fetched from GitHub is fetched again as it is needed. | This Mac |

## Entered in Gannin

This is stored only on this device and never sent anywhere. What the team shares belongs in the org's harness (Settings › Harness), where everyone reads the same copy. Deleting it cannot be undone.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| People's dates and time off | None | Shows how many people and time off entries you have entered. Read only. | This Mac |
| Org settings | Defaults | Shows how many orgs have settings of their own. Read only. | This Mac |
| Hidden items | 0 | Shows how many PRs and issues you have hidden. Read only. | This Mac |
| Starred orgs | 0 | Shows how many orgs you have starred. Read only. | This Mac |
| Stored | Empty | Shows the size of what you have entered. Read only. | This Mac |
| Delete Your Data | Not applicable | Removes your people's dates and time off, every org's settings, hidden items, stars, and changes not yet committed to a harness. What is already in a harness stays there. It asks first, and is greyed out when there is nothing to delete. | This Mac |

## Erase Everything and Sign Out

The last section has one button.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Erase Everything and Sign Out | Not applicable | Clears every cache and everything you have entered, removes your GitHub token from the keychain, and signs you out. It asks first with Erase Everything and Cancel, and cannot be undone. | This Mac |
