---
title: Investments settings
description: Every option in Org settings › Investments, where you choose how work is tracked and edit the investment categories.
sidebar:
  order: 6
---

Org settings › Investments is where you set up the categories the Investments page balances work across, such as new things, improving things and keeping the lights on. Open it with the cog beside the account menu in the sidebar's footer, then pick Investments in the toolbar.

Everything here belongs to the project your window is working in. A project's harness keeps it as `.gannin/investments.json`, and changes wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps it on this Mac. Until you edit anything, the categories are the Balance framework preset and issues are tracked in Gannin.

## How we track investments

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Tracked by | In Gannin | Where a category is recorded. In Gannin keeps choices and rules in Gannin and writes nothing to GitHub. GitHub labels makes each category a label. A board field makes each category an option of a single-select field on a board. Writing to GitHub is always confirmed first. | Harness (`.gannin/investments.json`) |
| Board | Choose a board | Shown for A board field. The project board that holds the field. | Harness (`.gannin/investments.json`) |
| Field | Choose a field | Shown once a board is picked. The board's single-select field whose options are the categories. | Harness (`.gannin/investments.json`) |

## Investment categories

Each row shows the category's colour, name and a summary, with arrows to reorder it. With In Gannin tracking, an issue goes to the first category, top to bottom, with a rule matching it, so higher categories win. There are at most eight categories, one for each chart colour.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Edit | Not applied | Opens a category's editor (described below). | Harness (`.gannin/investments.json`) |
| Add Category | Not applied | Opens the editor for a new category. It is saved when you press Done. Disabled once all eight colours are used. | Harness (`.gannin/investments.json`) |
| Start From Preset | Not applied | A menu of presets (Balance framework). Picking one asks before it replaces your categories and the choices made by hand. | Harness (`.gannin/investments.json`) |
| Replace Categories | Not applied | The confirmation button for a preset. | Harness (`.gannin/investments.json`) |
| Write N Chosen in Gannin to GitHub | Not applied | Shown with GitHub tracking when issues were categorised by hand before. N is how many. Proposes writing them to GitHub, which you confirm first. | GitHub, then Harness (`.gannin/investments.json`) |
| Clear N Chosen by Hand | Not applied | Shown when some issues were categorised by hand. Forgets those choices. | Harness (`.gannin/investments.json`) |

## The category editor

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Name | "New category" for a new one | The category's name. | Harness (`.gannin/investments.json`) |
| Description | Empty | A line saying what belongs in it. | Harness (`.gannin/investments.json`) |
| Target share | None | How much of the work it should be, as a percentage. The Investments page shows how far each is from its target. | Harness (`.gannin/investments.json`) |
| Colour | The first free colour | One of the eight chart colours. Colours used by other categories are disabled. | Harness (`.gannin/investments.json`) |
| Label | Empty | With GitHub labels tracking: the label that puts an issue in this category. The field is named after the tracking, so it reads, for example, "Bucket option" for a board field called Bucket. | Harness (`.gannin/investments.json`) |
| Field | Label | In a rule's condition: what to compare (Label, Title, Repository, Issue type, Milestone or Project field). | Harness (`.gannin/investments.json`) |
| Operator | is | In a condition: is, contains, starts with or matches regex. | Harness (`.gannin/investments.json`) |
| Value | Empty | In a condition: what to compare against. An empty value never matches. A menu beside it lists the values seen in the stored history, and picking one fills it in. | Harness (`.gannin/investments.json`) |
| Remove condition | Not applied | The minus button on a condition row. Removes that condition. | Harness (`.gannin/investments.json`) |
| Add Condition | Not applied | Adds another condition to a rule. A rule matches when all of its conditions do. | Harness (`.gannin/investments.json`) |
| Remove Rule | Not applied | Removes the rule. | Harness (`.gannin/investments.json`) |
| Remove It | Not applied | Shown on a rule that only repeats the label or option, so it never suggests anything. Removes that rule. | Harness (`.gannin/investments.json`) |
| Add Rule | Not applied | Adds a rule. A category matches an issue when any of its rules does. With GitHub tracking, rules only suggest a category when you assign issues that do not have one. | Harness (`.gannin/investments.json`) |
| Delete Category | Not applied | Removes the category and any choices made by hand for it. | Harness (`.gannin/investments.json`) |
| Cancel | Not applied | Closes the editor without saving. | This Mac |
| Done | Not applied | Saves the category and closes the editor. | Harness (`.gannin/investments.json`) |

A condition on Project field also asks which board field to compare (a text box with the Field label, such as Bucket). A menu beside it lists the board field names seen in the stored history.
