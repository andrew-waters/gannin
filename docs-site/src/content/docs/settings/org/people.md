---
title: People settings
description: Every option in Org settings › People, which decides whose PRs and reviews count in the workload lists and the stats.
sidebar:
  order: 3
---

Org settings › People decides whose work counts. Open it with the cog beside the account menu in the sidebar's footer, then pick People in the toolbar. Unticked people are left out everywhere in the org: their PRs and reviews do not count in the workload lists, People or the stats.

The list is the org's members plus anyone who authored or reviewed a PR in the metrics history (GitHub Apps aside), by name. Under a name you also see the login, when the name is not the login already. The header says how many are excluded. If the list is empty, people appear once the org has synced.

## People

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Filter | Empty | Narrows the list as you type by name or login (the prompt reads "Type to filter people"). Esc clears it. | Not kept |
| A person's name | Ticked, except accounts ending in -bot or [bot], which start unticked | One tick for each person. Unticking leaves them out of the workload lists, People and the stats. Ticking a -bot or [bot] account counts it anyway. | Harness (`.gannin/exclusions.json`) |

An org with a harness keeps the choices in the home project's harness, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps them on this Mac.

Older versions had a per-person Hide, kept on this Mac. A person hidden that way shows as unticked here too. Ticking them again clears the old Hide as well.

You can also leave someone out without opening Settings: right-click them in a list and choose Exclude from, followed by the org's name.
