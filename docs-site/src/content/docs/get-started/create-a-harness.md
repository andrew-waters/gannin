---
title: Set up a harness
description: Create the repo that holds a project's settings, plans and documents, or link one you have.
sidebar:
  order: 5
---

A harness is a GitHub repo beside your code that holds a project's team settings, plans, requirements, findings, skills, prompts and learnings, and where agent sessions run. [Projects and harnesses](/docs/concepts/projects-and-harnesses/) explains why. Most of Gannin works in a project, so setting one up comes first.

## Where it starts

- The first time a window opens on an org with no project, **Set Up Harness** opens by itself.
- **Not Now** closes it, and it doesn't open by itself for that org again. Come back to it any time from **Set Up Harness** at the foot of the sidebar (while the org has no project), on the Harness and Onboarding pages, or from **Gannin › Set Up Harness**.
- **Gannin › Set Up Harness** works even when the org has projects, to add another.
- **Org settings › Harness** (while the org has none) and **Org settings › Projects › Create Harness** open it too.

## The steps

1. **Projects** and **The harness**: what a project is, and the harness's layout as an annotated tree. If the org already has a project, Gannin starts at the next step, with the tour a link away.
2. **Create or link**:
   - **Create a new harness**: name the project, check the harness repo's name (the project's, ending `-harness`) and tick the code repos it covers. **Create Harness** makes a private repo in the org (or your personal account) and commits a starter layout: a README, a CLAUDE.md listing its repos, a `STANDARDS.md` for documents, folders for requirements, plans, decisions, findings, learnings, refines, skills and sessions (decisions with a README and a template for [decision records](/docs/guides/onboarding-and-decisions/#decisions)), and `.gannin/README.md` explaining the team files.
   - **Link one you have**: search the org's repos, or type `owner/name` for one elsewhere. **Link Harness** checks that GitHub can find it and that you can push to it.
3. **Finish**: the harness is a project now, and the window works in it.
   - **Starter files** lists any of the starter layout the harness doesn't have, from a harness someone made by hand or a create whose first commit failed. **Add Missing Files** commits only those, after asking; nothing already there is changed. Skip it if the harness is laid out its own way.
   - **On this Mac** says where the harness is checked out for Claude Code sessions. Gannin clones it there when the first session starts, or choose a checkout you have.

The first project is the org's **home**. The home project's harness also holds the org-wide team settings (working week, leave, exclusions, people's dates and so on). Boards, code repos and the rest are under [Org settings › Projects](/docs/settings/org/projects/).

## Changing home

Settings an org kept on this Mac before it had a harness stay on this Mac; nothing copies them into a harness. Once there's a harness, make it home and set them there. When you make a different project home in **Org settings › Projects**, Copy the Org's Data and Make Home copies the org-wide files committed in the old home's harness to the new one.
