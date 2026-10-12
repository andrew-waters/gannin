---
title: Onboarding and decisions
description: Map a project's decisions, requirements and plans by area for someone new, and keep the team's decisions as records.
sidebar:
  order: 41
---

The code shows what was built, but not why. The reasons are in the project's [harness](/docs/concepts/projects-and-harnesses/): spread across its plans and requirements, and in decision records written to keep them. Harness › Onboarding puts them in order, so someone new can find the area they'll work on and read why it is the way it is, without being talked through it.

## Onboarding

Harness › Onboarding, first under Harness in the sidebar, is a map of the window's project: its decisions, requirements and plans, grouped by area. Only documents that follow the harness's `STANDARDS.md` (front matter with a summary) are on it.

- **Areas** come from each document's `domains`. A document naming several domains is under each one. One with no domains is under its folder (a requirement's module), else under Other, which comes last.
- **Within an area**, documents marked `key: true` in their front matter come first, then decisions (accepted and proposed), then requirements, then plans, each newest first.
- **Older**, at the foot of an area, holds its superseded and rejected decisions, folded away. A superseded decision links to the one that replaced it. Plans are never folded, whatever their status.

Click a document to read it in the drawer. The search at the top finds areas by name, and documents by title or summary. Fold All folds every area to its header, and Open All opens them again.

### What you've read

A document you open from the map is marked read, with a tick on its row. Each area's header counts how many of its documents you've read. A document under several areas is ticked in each.

When a document you've read changes, it stays read but says **Updated since you read it** until you open it again.

Read marks are kept on this Mac only. They're never committed to the harness or sent anywhere, so nobody else sees how far you've got.

### Making the map useful

- Give every document `domains`, using the names your `STANDARDS.md` lists, so each lands in the right area.
- Mark the few documents someone should read first with `key: true`.
- Write down the decisions that matter as decision records (below), rather than leaving them in plans.

## Decisions

Decisions are decision records, sometimes called ADRs: one decision the team made, why it made it, what else it considered and what follows from it. They're Markdown files in the harness's `decisions/` folder (or anywhere with front matter `type: decision`), listed under Harness › Decisions, in the [command palette](/docs/guides/command-palette/), and in the briefs of [sessions](/docs/agents/work-on-this/) about their issues, as other documents are.

| Field | What it holds |
| ----- | ------------- |
| `status` | `proposed`, `accepted`, `rejected` or `superseded` |
| `summary` | The decision, in a sentence or two |
| `domains` | The areas it belongs to, the main one first |
| `superseded_by` | For a superseded decision, the path of the one that replaced it |
| `plans` | The plans it came from, by path |
| `key` | `true` to put it first in its area on Onboarding |
| `issues` | The issues it's about, as `owner/repo#123` |

A decision's page shows what superseded it, the decisions it supersedes, and the plans it came from. Don't rewrite an accepted decision when things change: write a new one, then open the old one's Edit Details, set its status to Superseded and pick the new one in Superseded by. Moving its status off Superseded clears the link.

### Writing a decision

New Decision in the toolbar of Harness › Decisions opens an editor with the decision template: Context, Decision, Alternatives considered and Consequences. It uses the harness's `decisions/_template.md`, or Gannin's own when the harness doesn't have one. Set its status, and for a superseded decision pick what superseded it. You can also name the plans it came from, and tick Key to its area.

Draft with Claude can write it with you ([Write with Claude](/docs/agents/write-with-claude/)). Its guidance for decisions is in [Settings › Harness](/docs/settings/org/harness/), with the other kinds'. Commit to Harness commits the one file to `decisions/`.

### Suggest Decisions

A harness that's had plans for a while already holds decisions; they just aren't written down as records. Suggest Decisions, in the toolbar of Harness › Decisions, has Claude find them:

1. Pick an area, or All. The button says how many plans it will read: those in the area that no decision cites in its `plans` yet.
2. Read Plans. Claude reads them five at a time, and the decisions it proposes show as each batch is done. Stop ends it once the batch Claude is reading is done (it says Stopping after this batch meanwhile), keeping what's been proposed.
3. Each proposal names the plan it came from. Edit its title, summary, text and domains, and untick any not worth keeping. When Claude didn't name one of the plans it read, it says Plan not named: pick the plan, or leave it to commit the decision citing none.
4. Commit Decisions, confirmed first, writes each ticked one as its own file under `decisions/`, marked proposed and citing its plan, in one commit.

It skips plans a decision already cites, so plans you've turned into decisions aren't read again; plans that gave nothing, or whose proposals you unticked, are read again next time. Mark the proposals accepted once the team agrees them (Edit Details on the decision's page).
