---
title: A server
description: Run sessions on another machine over ssh with Connect with.
sidebar:
  order: 3
---

Set **Connect with** in [Settings › General](/docs/settings/app/general/) (under Claude Code) to a command that opens a terminal on another machine, such as `ssh -t devbox`. Sessions then run there.

## What it needs

- The command working from your Mac without a password prompt (an ssh key or agent).
- On the server: Claude Code signed in, git, and ideally gh signed in.
- The harness checked out on the server. Set where in **Org settings › Harness** (there's no default for a server).

## How it works

Gannin packs each session's script, brief and settings into one command and runs it through Connect with. Its terminal is still a tab in Gannin's Claude Code window, and the panel reads over one shared ssh connection: the session's state every couple of seconds, and its Changes when Claude edits (at least every 30 seconds). A session's screenshots are copied to the server before it starts.

Quitting Gannin ends server sessions with their connection; their conversations resume when opened again.

## What it protects

Your Mac. Claude works on the server as the user you connect as, with whatever that user can reach there.

## How Claude signs in

With Claude Code's own login on the server. If the server is an Apple Silicon Mac with Apple `container`, sessions can be [sandboxed there](/docs/sessions/sandboxes/#sessions-on-a-server) too.

A Connect with command that isn't ssh works, but Gannin can't hand it sandbox credentials, so its sessions aren't sandboxed.
