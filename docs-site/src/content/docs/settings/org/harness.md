---
title: Harness settings
description: Every option in Org settings › Harness, covering where team data is kept, prompts, drafting guidance, checkouts and the sandbox GitHub token.
sidebar:
  order: 8
---

Org settings › Harness is about the harness behind the project your window is working in: where the team's data lives, what Claude Code sessions are told, where the harness is checked out on this Mac, and the GitHub token sandboxed sessions use. Open it with the cog beside the account menu in the sidebar's footer, then pick Harness in the toolbar. Projects themselves are added and edited under [Projects](/docs/settings/org/projects/).

A harness is a repo of plans, requirements, findings, skills and prompts beside the code. Gannin keeps the team's settings in it as JSON files under `.gannin/`, so everyone in the org works from the same copies. Changes to those settings apply at once and wait in the sidebar ("N changes to commit") until you review and commit them. An org with no harness keeps its team data on this Mac instead.

## Harness

You only see this section while the org has no harness yet. It is the way in.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Add Harness | No harness | A menu of the org's repos. Picking one makes it the org's first project, and Home. | This Mac |
| Create Harness | Not applied | Opens the Create Harness sheet, which makes a new private repo with starter files and makes it the first project. | This Mac (the new repo is on GitHub) |

## Team data

This section says where things are kept. It names the window's project and its harness repo, and, when that project is not Home, Home and its repo. The rest of the page then covers the settings that are yours alone.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| The project's name | The project's harness repo | Shows the harness repo the project's data is read from. Read only. | This Mac |
| Home (the project's name) | The first project's harness repo | Shown only when the window's project is not Home. Read only. | This Mac |

Where each kind of setting is kept:

| Setting | Where |
| --- | --- |
| Project name, repos and boards ([Projects](/docs/settings/org/projects/)) | Harness, `.gannin/project.json` |
| Investment categories ([Investments](/docs/settings/org/investments/)) | Harness, `.gannin/investments.json` |
| Issue workflow ([Issues](/docs/settings/org/issues/)) | Harness, `.gannin/workflow.json` |
| Goals ([Goals](/docs/settings/org/goals/)) | Harness, `.gannin/goals.json` |
| Scorecard, recap cadence, committed date field and notes from the field | Harness, `.gannin/scorecard.json`, `recap.json`, `prioritisation.json` and `field-notes.json` |
| Repos and people left out, repos without review, repos that need the Mac ([Repositories](/docs/settings/org/repositories/), [People](/docs/settings/org/people/)) | Home's harness, `.gannin/exclusions.json` |
| Working week and holiday allowance ([Working Time](/docs/settings/org/working-time/)) | Home's harness, `.gannin/working-week.json` and `leave.json` |
| People's dates and time off | Home's harness, `.gannin/people/<login>.json` |
| Saved views and the drafting guidance below | Home's harness, `.gannin/views.json` and `authoring.json` |
| The team's prompts | The project's harness, `prompts/<name>.md` |
| Which harnesses are your projects, and each one's branch | This Mac |
| Checkout folders, Ask before recording a session, Review requests automatically, the sandbox token | This Mac |
| Hidden items ([Hidden](/docs/settings/org/hidden/)) and stars | This Mac |

### Changes to commit

When there are pending changes, the sidebar shows "N changes to commit" above the Refresh row, with a Review button. Review opens a sheet listing them. Gannin commits each harness's changes together, on top of anything changed there since, so other people's edits are not lost.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Review | Shown while changes wait | Opens the sheet of pending changes. | This Mac |
| Commit | Not applied | Commits the changes to the harness. | Harness |
| Discard Changes | Not applied | Throws the pending changes away, after asking, and goes back to what the harness has. | This Mac |
| Cancel | Not applied | Closes the sheet and leaves the changes waiting. | This Mac |

## Prompts

The team's prompts are what Claude Code sessions are told besides Gannin's own prompt, for everyone in the org. Each is offered when work, a review or planning starts (defaults ticked, a repo's own default in place of the general ones), or from the menu under a session's terminal. Saving, or deleting, commits straight to the harness. Each row shows the prompt's title and where it is offered, whether it is a default, and its skills.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Edit | Not applied | Opens the prompt in the editor. | Harness (`prompts/<name>.md`) |
| New Prompt | Not applied | Opens the editor for a new prompt. Disabled until the harness has been read. | Harness (`prompts/<name>.md`) |

### The prompt editor

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Title | Empty | The prompt's name (the example prompt reads "Security review"). Required. | Harness (`prompts/<name>.md`) |
| File | The file's path | For an existing prompt, shows its file. Read only. | Harness (`prompts/<name>.md`) |
| File name | Made from the title | For a new prompt, the file name in `prompts/`. | Harness (`prompts/<name>.md`) |
| Summary | Empty | What it is for, in a line. | Harness (`prompts/<name>.md`) |
| Work on an issue | Ticked | Offers the prompt when you start work on an issue. | Harness (`prompts/<name>.md`) |
| Reviews | Ticked | Offers it when you review a PR with Claude. | Harness (`prompts/<name>.md`) |
| Planning | Ticked | Offers it when you start a planning session. | Harness (`prompts/<name>.md`) |
| Ask | Ticked | Offers it in Ask sessions. | Harness (`prompts/<name>.md`) |
| In a session | Ticked | Offers it in the prompt menus under a session's terminal. At least one place must be ticked. | Harness (`prompts/<name>.md`) |
| Ticked by default | Off | Ticks the prompt when a session starts. | Harness (`prompts/<name>.md`) |
| Only for repos | Any repo | Shown when it is a default. A comma-separated list of repos. A default for named repos takes the place of the general defaults there. | Harness (`prompts/<name>.md`) |
| A skill's name | Unticked | Under "Skills it brings", one checkbox for each skill in the harness's skills folder. Ticked skills come with the prompt. | Harness (`prompts/<name>.md`) |
| Prompt | Empty | The text itself, in Markdown. `{{issue}}`, `{{title}}`, `{{url}}`, `{{repo}}`, `{{number}}` and `{{branch}}` are filled in. Required. | Harness (`prompts/<name>.md`) |
| Message | Empty | In the Draft with Claude section at the top. What you tell Claude about the prompt, or your answer to its questions. | Not kept |
| Start with Claude | Not applied | Sends the first message. Once Claude has answered, the button reads Send. Claude drafts into the fields below and says what it did. | Not kept |
| Start Over | Not applied | Shown once there is a conversation. Forgets it; what is in the editor stays. | Not kept |
| Cancel | Not applied | Closes the editor. | This Mac |
| Delete | Not applied | Shown on an existing prompt. Asks first. | Harness (`prompts/<name>.md`) |
| Delete from Harness | Not applied | The confirmation: commits the prompt's removal. Sessions already started keep what they were told. | Harness (`prompts/<name>.md`) |
| Commit to Harness | Not applied | Saves the prompt by committing its file. The button reads "Committing" while it works. | Harness (`prompts/<name>.md`) |

## Drafting with Claude

This is what Claude is told when it drafts a new document from the Harness page. For plans it is a planning session's first prompt. Gannin's default stays until you change it, and the line under the editor says whether you are seeing "The org's own" or "Gannin's default".

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| For | Skills | Picks the kind of document you are editing guidance for: Plans, Requirements, Findings, Skills, Prompts or Learnings. | Not kept |
| Write with Claude | Not applied | Opens a conversation with Claude to write the guidance with you. Nothing changes until you press Use This Draft. | Harness (`.gannin/authoring.json`) |
| Restore Default | Not applied | Goes back to Gannin's default for that kind. Disabled while it is already the default. | Harness (`.gannin/authoring.json`) |
| Save | Not applied | Saves the text as the org's guidance for that kind. Disabled until the text changes. Saving Gannin's default, or nothing, clears it. | Harness (`.gannin/authoring.json`) |

## Checkouts

A disclosure group, open by default, with one "Claude Code" section for each project's harness (named "Claude Code in" the repo's name when there are several). It says where the harness is checked out on this Mac, which is where Claude Code sessions run. The first project's section also holds the two choices that apply to the whole org.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| On this Mac | A checkout already in a usual place, else `<workspace>/<org>-<repo name>` (`<org>-harness` when the repo is named harness) | Shows the folder sessions use. Each issue's code is a git worktree under `.worktrees`, beside the shared clones in `projects`. If it is not checked out yet, the first session clones it. | This Mac |
| Choose | Not applied | Opens a folder picker for the harness's checkout, or the folder to clone it into. | This Mac |
| Default | Not applied | Shown once you have chosen a folder. Goes back to the default folder. | This Mac |
| On the server | Empty (prompt `~/<org>-harness`) | Shown only when Connect with is set in [Settings › General](/docs/settings/app/general/). Where the harness is checked out on that server, as a path on that box. | This Mac |
| Ask before recording a session | On | Work on This commits the session's brief and a `session.json` to the harness's sessions folder, and adds its pull request later. Switch this off and it does so without asking. Shown on the first project only. | This Mac |
| Review requests automatically | As in Settings (on or off, following [Settings › General](/docs/settings/app/general/)) | Your own choice for this org: whether a review request here starts Claude's review by itself. Choose As in Settings, On or Off. Shown on the first project only. | This Mac |

## GitHub in a sandbox

The fine-grained GitHub token this org's sandboxed sessions use to push and open pull requests, passed to them as `GH_TOKEN` for git and gh. Gannin's own sign-in and your gh login never go in. The section lists the permissions the token needs. Create One on GitHub fills them in; you pick the repos there. Changing workflow files needs Workflows as well.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Token | Empty (prompt `github_pat_`) | Where you paste the token. Once one is saved, the row reads "Saved in the keychain". | This Mac (the keychain) |
| Save | Not applied | Saves the pasted token. Disabled while the box is empty. | This Mac (the keychain) |
| Remove | Not applied | Removes the saved token. | This Mac (the keychain) |
| Create One on GitHub | Not applied | A link that opens GitHub's new token page, already filled in. | This Mac |
