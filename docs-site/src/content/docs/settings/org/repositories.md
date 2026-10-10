---
title: Repositories settings
description: Every option in Org settings › Repositories, which decides which repos count and which need a review or a Mac.
sidebar:
  order: 1
---

Org settings › Repositories decides which of the org's repos Gannin pays attention to, which need a review before merging, and which can only be built on a Mac. Open it with the cog beside the account menu in the sidebar's footer, then pick Repositories in the toolbar. It is the pane the settings open on.

Every option here is a team file. An org with a harness keeps it in the home project's harness as `.gannin/exclusions.json`, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps them on this Mac.

## Repositories

The list shows every repo GitHub has told Gannin about, included ones first, then the rest, each by name. Under each name is a short summary (open PRs, open issues, merged). The header says how many are excluded. If the list is empty, repos appear once GitHub's list has loaded.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Filter | Empty | Narrows the list as you type (the prompt reads "Type to filter repositories"). Esc clears it. The bulk buttons below then change only the repos shown. | This Mac |
| Included | On | Switch at the end of a row. Off leaves the repo out everywhere in the org: the workload lists, People and the stats. | Harness (`.gannin/exclusions.json`) |
| Needs Review | On | Checkbox on a row. Untick it for a repo whose PRs can merge without a review (docs, config, the harness), so they are not flagged as merged without review. Disabled while the repo is not included. | Harness (`.gannin/exclusions.json`) |
| Needs the Mac | Off | Checkbox on a row. Tick it for a repo that only builds on a Mac (an Xcode app), so its Claude Code sessions run on the Mac rather than in a sandbox. Disabled while the repo is not included. | Harness (`.gannin/exclusions.json`) |

A window that has a project picked also narrows to that project's repos. A repo the project names counts even if you have excluded it here.

## Change all (or the shown)

The row of small buttons above the list says "Change all N", or "Change the N shown" while a filter is typed. Each button changes every repo it names in one go, as a single change to the settings. They are disabled when there is nothing to change.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Include | Not applied | Includes every repo named, so none is left out. | Harness (`.gannin/exclusions.json`) |
| Exclude | Not applied | Excludes every repo named, leaving them out everywhere. | Harness (`.gannin/exclusions.json`) |
| Needs Review | Not applied | Ticks Needs Review on every repo named, so each is expected to have a review. | Harness (`.gannin/exclusions.json`) |
| No Review | Not applied | Unticks Needs Review on every repo named, so their PRs may merge without one. | Harness (`.gannin/exclusions.json`) |
| Needs the Mac | Not applied | Ticks Needs the Mac on every repo named, so their sessions run on the Mac. | Harness (`.gannin/exclusions.json`) |
| Doesn't Need the Mac | Not applied | Clears Needs the Mac on every repo named, so their sessions can run in a sandbox again. (It used to be labelled Sandbox.) | Harness (`.gannin/exclusions.json`) |
