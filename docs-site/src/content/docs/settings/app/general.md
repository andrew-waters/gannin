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

## Session rules

Rules that block what a Claude Code session can do, whatever Claude decides. Nothing is blocked until you turn one on. Gannin checks each command before claude runs it, in every session you start or resume afterwards, on this Mac, on a server or in a sandbox, Attended or Unattended. A blocked command shows in the session's Activity pane with the rule's name, and claude is told why so it can carry on another way.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| No force push | Off | Blocks `git push --force`, `-f`, `--force-with-lease` and `+branch` refspecs. | This Mac |
| Push only to the session's branch | Off | Blocks `git push` to any branch but the session's own, and `--all`, `--mirror` and `--tags`. The branch has to be named, as `git push origin HEAD:<branch>`: a bare `git push` or `git push origin HEAD` pushes whatever is checked out, so it's blocked. | This Mac |
| No branch or tag deletes | Off | Blocks `git branch -d`, `git tag -d`, `git update-ref -d`, `git push --delete`, `--prune` or `:branch`, and deleting refs through `gh api`. | This Mac |
| No gh release writes | Off | Blocks `gh release create`, `edit`, `upload`, `delete` and `delete-asset`, and writes to releases through `gh api`. Reading releases is fine. | This Mac |
| Limit PR comments and reviews | Off | Allows a session at most this many PR or issue comments and reviews an hour (`gh pr comment`, `gh pr review`, `gh issue comment`, comment and review writes through `gh api`, and the GitHub MCP tools that add a comment, reply or review), then blocks the next. 10 when turned on. | This Mac |
| Name | Empty | A custom rule's name, shown in Activity and told to claude. | This Mac |
| Pattern | Empty | What a custom rule matches, as an extended regular expression over the whole command (`grep -E`); plain words work as they are. A rule with no pattern does nothing; one that isn't a valid expression blocks every command until it's fixed, and Settings says so. | This Mac |
| When it matches | Block | Block stops the command. Ask me turns it into a permission prompt, so the session goes to Needs you until you Allow or Deny it. | This Mac |
| Add Rule | Not applicable | Adds a custom rule. | This Mac |

While any rule is on, a session also can't change Gannin's settings, its own settings file, or Claude Code's settings (`.claude/settings*.json`, `disableAllHooks`), so it can't remove or edit its own rules. Reading them with `cat`, `grep` and the like is fine; any other command naming them is blocked. It can't set git config that changes what a push does or makes an alias (`git -c` or `git config` with `alias.*`, `push.*` or `remote.*.push`) either. If the check itself can't run on a box, every command is blocked rather than let through.

Rules match commands as they are written. That stops mistakes and casual prompt injection, but not someone set on getting round them, for example with an encoded or scripted command. Protect shared branches on GitHub as well.

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
