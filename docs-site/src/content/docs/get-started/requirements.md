---
title: What Gannin needs
description: macOS 26, a GitHub account, and the optional tools that unlock more.
sidebar:
  order: 1
---

## Required

- **A Mac on macOS 26 (Tahoe) or later.** Gannin is a native Mac app.
- **A GitHub account.** Gannin reads your orgs, repos, pull requests, issues and boards through GitHub's API, signed in as you.

That's enough for everything that reads GitHub: the Inbox, Dashboard, pull requests and issues, delivery metrics, CI, releases, the team views and the rituals.

## Optional

Gannin looks for these when it needs them, and says so when one is missing.

| Tool | What it unlocks |
| --- | --- |
| [Claude Code](https://claude.com/claude-code) (`claude`) | Agent sessions: Work on This, Ask, Quick Change, planning, Review with Claude, routines, and Claude's help drafting issues and prompts. Claude Code signs in with your own Claude account; Gannin never sees that login. |
| [git](https://git-scm.com) | Work › Repositories (everyday local git) and the sessions' worktrees. It uses your own git config, signing and credentials. |
| [GitHub CLI](https://cli.github.com) (`gh`) | Cloning with your gh login, and what sessions do on GitHub as you (opening pull requests, reading checks). Without it, Gannin clones over https with git. |
| Apple's [`container`](https://github.com/apple/container) | [Sandboxed sessions](/docs/sessions/sandboxes/), on an Apple Silicon Mac. Gannin can install it for you. |

A Mac with Homebrew finds these in Homebrew's folders as well as your `PATH`.
