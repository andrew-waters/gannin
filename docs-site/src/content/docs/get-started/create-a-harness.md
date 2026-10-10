---
title: Create a harness
description: Make the repo that holds a project's settings, plans and documents.
sidebar:
  order: 5
---

A harness is a GitHub repo beside your code that holds a project's team settings, plans, requirements, findings, skills, prompts and learnings, and where agent sessions run. [Projects and harnesses](/docs/concepts/projects-and-harnesses/) explains why.

## Making one

1. Open **Org settings › Harness** (while the org has none) or **Org settings › Projects** and click **Create Harness**.
2. If this is your first project, Gannin first explains what a project and its harness are, and shows the harness's layout as an annotated tree. Anyone else starts at the name, with the tour a link away.
3. Name the project, check the harness repo's name (the project's, ending `-harness`) and tick the code repos it covers. The busiest are ticked to start.
4. Create. Gannin makes a private repo in the org (or your personal account) and commits a starter layout: a README, a CLAUDE.md listing its repos, a `STANDARDS.md` for documents, folders for requirements, plans, findings, learnings, skills and sessions, and `.gannin/README.md` explaining the team files.

The new harness is a project from then on, and the org's **home** project if it's the first. The home project's harness also holds the org-wide team settings (working week, leave, exclusions, people's dates and so on).

## Using a harness you already have

In **Org settings › Projects**, Add Project and pick the repo. Then, in **Org settings › Harness**, say where it's checked out on this Mac if sessions should run in it.

## Moving settings across

An org that had no harness kept its team settings on this Mac. Making a harness the home project offers to copy them into it, so the team reads the same copy from then on.
