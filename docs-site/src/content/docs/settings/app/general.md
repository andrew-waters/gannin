---
title: General settings
description: Every option in Settings › General, with its default and what it changes.
sidebar:
  order: 1
---

Settings › General is where you set how Gannin looks, who you are signed in as, how Claude Code sessions and reviews behave, and which editor files open in. Open it from Gannin › Settings. Every option here is kept on this Mac only.

## Appearance

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Appearance | System | Picks System, Light or Dark for the whole app. System follows macOS. | This Mac |

## Font

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Reset | Only shown once you have chosen a font | Puts the font back to the default. | This Mac |
| Change Font | The system monospaced font at 12 pt | Opens the macOS font panel. The font is used for diffs (Repositories, sessions and PR reviews) and the Claude Code terminal. | This Mac |

## Account

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Signed in as | Your GitHub login | Shows who you are signed in as. Read only. | This Mac |
| Sign Out | Not applicable | Signs you out of GitHub and clears the org list. When you are not signed in, the pane says "Not signed in" instead. | This Mac |

## Pull requests and issues

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Exclude draft PRs | Off | Leaves draft pull requests out of lists and counts. | This Mac |
| Show hidden PRs and issues | Off | Shows the items you hid by right-clicking them, so you can find one and Unhide it. Hidden items are otherwise left out of lists and counts. | This Mac |

## Agent

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Provider | Anthropic | Chooses the AI provider that sessions use. | This Mac |
| Model | Claude Code's default | Chooses the model sessions run with, from their next start or Resume. Pick Other to type a model ID yourself. | This Mac |
| Model ID | Empty | Only shown when you pick Other. The exact model ID to pass to Claude Code. | This Mac |
| Review requests automatically | Off | A new review request starts Claude's review in the background, two at a time. Each org can say otherwise in its Settings, under Harness. | This Mac |
| Watch reviewed pull requests | On | Once a review finishes, new commits or comments on its PR start another review after a couple of quiet minutes, until the PR is merged or closed. | This Mac |
| Post automatic reviews to GitHub | Off | Posts reviews that Gannin starts by itself as comments. They never approve or request changes. Off, they wait for you to Post Review. | This Mac |
| Record reviews in the harness | On | Commits a review's findings and outcome to its harness when it is posted, finished, merged or closed. Agents › Metrics reads them. | This Mac |
| Send new PR feedback to Claude | Off | Pastes failing checks and new reviewer comments on a session's PR into the session. Each session can say otherwise in its PRs pane. | This Mac |
| Review a session's work with a second agent | On | When a session says its change is ready, another agent that cannot edit reviews it, and the findings go back, round after round. Each session can say otherwise in its Activity pane. | This Mac |
| Ask to wrap up when closing a session's tab | On | Closing a running session's tab first shows its pull requests, what is not pushed, and its plans and requirements. | This Mac |
| Show in the menu bar | On | Shows Gannin in the macOS menu bar. | This Mac |
| Notify when a session needs you | On | Sends a notification when Claude asks something or finishes its turn and you are not looking at its tab. | This Mac |

How often Gannin looks for review requests is set in [Settings › Sync](/docs/settings/app/sync/).

## Claude Code

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Workspace | ~/Gannin | The folder where Gannin clones a harness. | This Mac |
| Choose | Not applicable | Opens a folder picker to set the Workspace. | This Mac |
| Connect with | Empty | The command that reaches a server to run sessions on, for example `ssh -t devbox`. Put `{command}` where the rest goes, or it goes at the end. Empty runs sessions on this Mac. Sessions stay where they were made. | This Mac |

## Prompts

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Open files in | Visual Studio Code | The editor files open in: Visual Studio Code, Cursor, Zed or Xcode. Xcode only opens files on this Mac. | This Mac |
| Name | Five starter prompts | The name of a saved prompt. | This Mac |
| Prompt | Five starter prompts | The text of a saved prompt. | This Mac |
| Write with Claude | Not applicable | The sparkles button beside each saved prompt. Drafts the prompt by talking it through with Claude. Nothing changes until you use the draft. | This Mac |
| Remove this prompt | Not applicable | The minus button beside each saved prompt. Removes it at once. | This Mac |
| Add Prompt | Not applicable | Adds a prompt named "New prompt" with no text. | This Mac |
| Restore Defaults | Not applicable | Replaces your saved prompts with the five starters. | This Mac |

Saved prompts are sent from the menu under a session's terminal. The first nine have the shortcuts ⌃1 to ⌃9.
