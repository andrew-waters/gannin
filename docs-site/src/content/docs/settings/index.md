---
title: Settings reference
description: Every option in Gannin's Settings, its default, what it changes and where it's kept.
---

Gannin has two kinds of settings.

- **App settings** are yours, on this Mac. Open them with Gannin › Settings (⌘,). They have four panes: [General](/docs/settings/app/general/), [Sync](/docs/settings/app/sync/), [Sandbox](/docs/settings/app/sandbox/) and [Storage](/docs/settings/app/storage/).
- **Org settings** belong to the org (or your personal account) picked in the window. Open them with the cog beside the account menu at the foot of the sidebar, and pick a pane from the bar at the top: [Repositories](/docs/settings/org/repositories/), [Projects](/docs/settings/org/projects/), [People](/docs/settings/org/people/), [Working Time](/docs/settings/org/working-time/), [Issues](/docs/settings/org/issues/), [Investments](/docs/settings/org/investments/), [Goals](/docs/settings/org/goals/), [Harness](/docs/settings/org/harness/) and [Hidden](/docs/settings/org/hidden/).

Each page has a table per section of the pane: the option as the app labels it, its default, what it changes, and where it's kept.

## Where a setting is kept

- **This Mac**: only you see it, and only on this Mac. All app settings are kept here, and so are a few org settings: where the harness is checked out, automatic review per org, recording sessions without asking, the sandbox's GitHub token and what you've hidden.
- **Harness**: most org settings are team settings. When the org has a harness they live in it as files under `.gannin/`, so everyone on the team reads the same copy. Changing one waits as a change to commit at the foot of the sidebar until you review it. An org with no harness keeps them on this Mac instead.

[Where things are kept](/docs/concepts/where-things-are-kept/) says more.
