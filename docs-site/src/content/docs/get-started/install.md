---
title: Install and update
description: Download Gannin, put it in Applications, and keep it up to date.
sidebar:
  order: 2
---

## Install

1. Download Gannin from [gannin.ai](https://gannin.ai) (the Download button) or the [latest release](https://github.com/andrew-waters/gannin/releases/latest) on GitHub.
2. Open the disk image and drag Gannin to Applications.
3. Open Gannin from Applications. It's signed and notarised by Apple, so it opens like any other app.

## Update

Gannin checks gannin.ai for new versions by itself and offers to install them. To check now, pick **Gannin › Check for Updates**. Each release's notes are on its [GitHub release](https://github.com/andrew-waters/gannin/releases).

## Uninstall

Quit Gannin and drag it to the Bin. To remove what it keeps as well, first:

1. Turn sandboxing off in **Settings › Sandbox**, if it's on, and say yes to removing the sandboxes and images Gannin made.
2. Use **Settings › Storage › Erase Everything and Sign Out**, which deletes its caches, the release download history, what you've entered and your GitHub token.

That still leaves your app settings, agent sessions and routines (in `~/Library/Application Support/dev.andon.gannin` and Gannin's preferences) and any sandbox credentials in the keychain (under `dev.andon.gannin.sandbox`). Delete those by hand if you want them gone.
