---
title: Projects settings
description: Every option in Org settings › Projects, where you add, create and edit the projects a window can work in.
sidebar:
  order: 2
---

A project is a harness (a repo of plans, requirements, findings, skills and prompts) plus the code repos it is for. Org settings › Projects is where you manage them. Open it with the cog beside the account menu in the sidebar's footer, then pick Projects in the toolbar. Every window works in one project, picked at the bottom of the sidebar.

Pick a project in the list to edit it in the sections below. The first project in the list is marked Home, and it also keeps the org's own data.

## Projects

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Add Project | No projects | Opens a searchable list of the org's repos. Picking one makes that repo a project's harness. | This Mac |
| Create Harness | Not applied | Opens the Create Harness sheet to make a new repo for a project's harness, with its starter files, and make it a project. | This Mac (the new repo is on GitHub) |
| Remove Project | Not applied | The minus button on a row, then Remove Project in the confirmation. Gannin stops reading that harness, but the repo and everything in it are untouched. If it was Home, the next project becomes Home. | This Mac |

Which harnesses are your projects is your own choice, so it stays on this Mac. Everything inside a project is kept in its harness.

## The project's name and repos

The header is the project's name. The footer says where it is saved: `.gannin/project.json` in its harness, so anyone who adds it as a project gets the same.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Name | The name given in Create Harness, else the harness repo's name | Renames the project. | Harness (`.gannin/project.json`) |
| Repositories | None yet, which means every repo | The code repos the project covers. Use the plus button to add one and the cross on a repo to remove it. With a project picked, every other repo is left out of the workload, the stats, CI and the issue pages. | Harness (`.gannin/project.json`) |

## Boards

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Boards | Every board in the org | Picks the repo whose linked GitHub boards the sidebar's Projects lists, with this project picked. | Harness (`.gannin/project.json`) |

## Harness

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Harness | The repo you added | Shows the harness repo. Read only. | This Mac |
| Branch | Default (the repo's default branch) | The branch Gannin reads the harness from and commits to. | This Mac |
| Make Home | Not applied | Makes this project Home, so the org's data is read from its harness. Shown only on projects that are not Home. | This Mac |

Make Home asks first. Choose Copy the Org's Data and Make Home to have Gannin commit a copy to the new home first of the org-wide files committed in the current home's harness (not settings from this Mac), or Make Home Without Copying to switch straight away. The old copy stays where it is either way.

## Prompts

This is the same list as on the [Harness settings](/docs/settings/org/harness/) page, here for the project you picked. The team's prompts are `prompts/<name>.md` files in the harness, and saving one commits it straight away.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Edit | Not applied | Opens a prompt in the editor. | Harness (`prompts/<name>.md`) |
| New Prompt | Not applied | Opens the editor for a new prompt. Disabled until the harness has been read. | Harness (`prompts/<name>.md`) |
