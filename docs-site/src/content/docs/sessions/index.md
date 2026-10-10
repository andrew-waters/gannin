---
title: Choosing where sessions run
description: This Mac, a server, a sandbox here, or a sandbox on a server.
sidebar:
  order: 1
---

Agent sessions (Work on This, Quick Change, routines and their helpers) run Claude Code in a terminal inside Gannin. Where that terminal runs is up to you.

| | This Mac | A server | A sandbox here | A sandbox on a server |
| --- | --- | --- | --- | --- |
| **Needs** | Claude Code, git (gh helps) | A Connect with command (`ssh -t devbox`), Claude Code and git there | An Apple Silicon Mac, Apple `container`, a GitHub token per org, a signing key | A Connect with server that's an Apple Silicon Mac with `container` |
| **Protects** | Nothing extra: Claude can reach what you can | Your Mac: Claude works on the server as the user you connect as | Your Mac: Claude sees only the issue's folder and what it's given | The server likewise |
| **Claude signs in** | Your own Claude Code login on this Mac | Claude Code's login on the server | Inside the sandbox, through Anthropic's sign-in, or an API key | As a sandbox here |
| **Set up in** | Nothing | [Settings › General](/docs/settings/app/general/) (Connect with), Org settings › Harness (the server's checkout) | [Settings › Sandbox](/docs/settings/app/sandbox/), Org settings › Harness (token) | Settings › Sandbox › Remote machines |

Review with Claude and planning sessions are never sandboxed: they follow Connect with, running on the server when one is set. Ask (and routine reports) always run on this Mac.

- [This Mac](/docs/sessions/this-mac/)
- [A server](/docs/sessions/server/)
- [Sandboxes](/docs/sessions/sandboxes/), here or on a server
