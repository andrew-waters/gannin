---
title: Harness pages
description: Read, search and write the plans, requirements, findings and other documents in your project's harness.
sidebar:
  order: 40
---

Once a project has a [harness](/docs/concepts/projects-and-harnesses/), its documents are listed under Harness in the sidebar: Plans, Requirements, Decisions, Findings, Skills, Prompts, Learnings, Research, Refines and Specialists, each with a count, then Workflows ([Specialists and workflows](/docs/agents/workflows/)). Onboarding, first under Harness, maps the project's decisions, requirements and plans by area for someone new ([Onboarding and decisions](/docs/guides/onboarding-and-decisions/)). The Harness row shows whichever you picked last. Refresh in the sidebar fetches the harness again.

Only documents that follow the harness's `STANDARDS.md` (front matter with a summary) are listed, except specialists, which are listed whatever their front matter. Older ones aren't shown, though sessions still read them.

## Finding documents

A bar at the top has a search over title, summary, path, domains and issues. There's a menu for each front matter field that two or more documents share (such as Status, Domains, Owner, Touches and Severity), with counts. Not Linked, for plans and requirements, shows those that name no issue.

The table shows title with its summary, status, domain, issues, tasks, owner and date, newest first until you sort a column.

## A document

A document opens in a drawer, or as a page with Open as Page, or its own window with Open in Window. Done closes the drawer.

It has the summary and a folding section for each `##` heading, with Contents to jump between them. Beside it are the document's facts: status, kind, tasks, owner, branch and domains, then the issues it's about, its requirement, what it depends on, and what it mentions. Edit Details changes the status, owner and domains and commits them; for a decision marked superseded it also has Superseded by, the decision that replaced it.

Issues named in the text, such as `owner/repo#123`, open in a drawer. An issue's page lists the documents about it or mentioning it.

## Making documents

New in the toolbar makes one: a skill, prompt, specialist, learning, requirement, decision or finding. Decisions also have Suggest Decisions, where Claude proposes them from the harness's plans ([Onboarding and decisions](/docs/guides/onboarding-and-decisions/#suggest-decisions)). Plans use Plan with Claude, which starts a [planning session](/docs/agents/planning/). Each new document is committed as one file. Draft with Claude can write it with you ([Write with Claude](/docs/agents/write-with-claude/)). Learnings are usually saved from [reviews](/docs/agents/learnings/). Research comes from an Ask session's Commit to Harness, and Refines from a Design and Refine session, so neither has New.

## Changes to commit

Edits to team settings wait as pending changes. The sidebar shows "N changes to commit" above Refresh, with Review, which commits each harness's changes together. [Settings › Harness](/docs/settings/org/harness/) has the details.
