---
title: Sandbox settings
description: Every option in Settings › Sandbox, with setup steps and what you need before sessions can run in a sandbox.
sidebar:
  order: 3
---

Settings › Sandbox is where you turn on sandboxed Claude Code sessions and give them what they need. A sandbox is a Linux VM from Apple container, one per issue. It sees the harness read-only, its own issue's folder and the shared clones' git, and nothing else of this Mac. Its network is open. Every option here is kept on this Mac only. For the full story, see the [sandbox guide](/docs/sessions/sandboxes/).

## What you need

- A Mac with Apple Silicon on macOS 26 or later.
- Apple container installed and running. Gannin can install it for you.
- A signing key for commits (see Commit signing below).
- A way for Claude to sign in: Sign in with Claude, or an API key.

## Setting up

1. Open Settings › Sandbox. If the switch says it needs something first, add a signing key, and an API key if you chose that.
2. If Apple container is not installed, press Install Apple container first. Turning the switch on does not install it.
3. Turn on Run Work on This sessions in a sandbox. Gannin gets this Mac ready: its service running, a Linux kernel set and Gannin's base image built. This takes a few minutes the first time.
4. Watch the steps: Check this Mac, Start Apple container, Set the Linux kernel and Build Gannin's base image. Steps already done show "Already done".
5. Start a Work on This session. Each one can also be started on this Mac instead.

## Sandbox

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Run Work on This sessions in a sandbox | Off | Starts new Work on This sessions in a sandbox. Turning it on sets this Mac up first. Repos marked Needs the Mac stay on this Mac. Turning it off asks first. | This Mac |
| Apple container | Shown once checked | Shows "<version>, running", "<version>, stopped" or "Not installed". Read only. | This Mac |
| Install Apple container | Only shown when it is not installed | Downloads Apple's signed installer, checks it, and installs it. macOS asks for your password once. | This Mac |
| Update to | Only shown when an update is offered | Updates Apple container to the version Gannin was tested with. This stops every container running on this Mac, Gannin's or not. | This Mac |
| Set Up | Only shown when this Mac is not ready | Starts the service, sets a kernel and builds the base image, without installing. Once the Mac is ready and the signing key and Claude sign-in are there, it also turns sandboxing on. | This Mac |
| Check Again | Not applicable | Checks this Mac again. | This Mac |
| Show Output | Only shown once there is output | Shows what Apple container said. | This Mac |
| Install | Not applicable | Confirms the install. Gannin then does the same as Set Up: it starts the service, sets a kernel, builds the base image, and turns sandboxing on once the Mac is ready and the keys are there. | This Mac |
| Turn Off and Remove | Not applicable | Turns sandboxing off and deletes every container and image Gannin made on this Mac, a running session's sandbox included, and nothing else. | This Mac |
| Turn Off, Keep Them | Not applicable | Turns sandboxing off. Sessions already in a sandbox stay in one. | This Mac |
| Cancel | Not applicable | Closes a confirmation without changing anything. | This Mac |

## Claude in a sandbox

Each person signs in with their own Claude account or key, never a shared one. Your own Claude login on this Mac never goes in.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Claude signs in with | Sign in with Claude | Chooses Sign in with Claude or API key. With sign-in, the first sandbox asks you to sign in through Anthropic's own sign-in, and the rest share that login. Gannin never sees it. | This Mac |
| Sign Out of Claude in Sandboxes | Not applicable | Removes the login your sandboxes share, so the next one asks again. | This Mac |
| Sign Out | Not applicable | Confirms the sign out. Sandboxes running now stay signed in until they stop. | This Mac |
| API key | Not saved | Shows "Saved in the keychain" once saved. Passed to each sandbox as ANTHROPIC_API_KEY. | This Mac |
| Save | Not applicable | Saves the API key you typed to the keychain. Keys start with the prefix shown in the field. | This Mac |
| Remove | Not applicable | Removes the saved API key, and turns sandboxing off. | This Mac |

## Commit signing

Commits made in a sandbox are signed with a key of its own, kept in the keychain, and carry your git name and email. Your SSH keys never go in. Add it to GitHub as a Signing Key so its commits show as Verified.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Make a Signing Key | Not applicable | Makes a new key for sandboxes. | This Mac |
| Paste a Key | Not applicable | Lets you paste a key of your own. | This Mac |
| Use This Key | Not applicable | Saves the pasted key. | This Mac |
| Cancel | Not applicable | Backs out of pasting a key. | This Mac |
| Public key | None until a key exists | Shows the public half of the key. Read only. | This Mac |
| Copy | Not applicable | Copies the public key. | This Mac |
| Add to GitHub | Not applicable | Copies the key and opens GitHub's New SSH key page. Paste it there and pick Signing Key as its type. | This Mac |
| Remove | Not applicable | Removes the signing key, and turns sandboxing off. | This Mac |

## House rules for Claude

Your own rules for Claude in every sandbox: how to write commits and pull requests, attribution, anything you would keep in ~/.claude/CLAUDE.md. They are written to a file of their own each time a sandbox's Claude starts. Your own ~/.claude never goes in.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| House rules for Claude | Empty | The text of your rules, in a free text box. | This Mac |
| Copy from This Mac | Not applicable | Fills the box from your ~/.claude/CLAUDE.md, to edit before it goes in. Leave out @ imports, which name files a sandbox cannot read. Greyed out when that file does not exist. | This Mac |
| Replace | Not applicable | Confirms replacing what is in the box with this Mac's CLAUDE.md. | This Mac |
| Write with Claude | Not applicable | Drafts your rules by talking them through with Claude. Nothing changes until you use the draft. | This Mac |

## Each sandbox gets

Each sandbox's share of this Mac, applied when it starts.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| CPUs | 4 | How many CPUs each sandbox gets, from 1 up to the number this Mac has. | This Mac |
| Memory | 8 GB | How much memory each sandbox gets, from 2 GB up to this Mac's total. | This Mac |

## Remote machines

This section only appears once Connect with is set in [Settings › General](/docs/settings/app/general/). Sandboxed sessions on a server run in Apple container there, which needs a Mac with Apple Silicon on macOS 26 or later. Gannin checks it over ssh. Installing or updating asks for that Mac's password in a terminal, which Gannin never sees.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| The server's name | Empty | The row is labelled with the server's name, set by Connect with in Settings › General. It shows the server's architecture and macOS version. Read only. | This Mac |
| Apple container | Shown once checked | Shows "<version>, running", "<version>, stopped" or "Not installed" for the server. Read only. | This Mac |
| Install Apple container | Only shown when it is not installed | Opens a terminal on the server, where sudo asks for its password. | This Mac |
| Update to | Only shown when an update is offered | Updates Apple container there. This stops every container on that server. | This Mac |
| Install | Not applicable | Confirms the install in the dialog. | This Mac |
| Update | Not applicable | Confirms the update in the dialog. | This Mac |
| Set Up | Only shown when the server is not ready | Starts the service there, sets a kernel if none is set, and builds the base image. | This Mac |
| Check Again | Not applicable | Checks the server again. | This Mac |
| Show Output | Only shown once there is output | Shows what Apple container said. | This Mac |
| Done | Not applicable | Closes the install terminal once it has finished. | This Mac |
| Stop | Not applicable | Stops the install and closes the terminal while it is still running. | This Mac |
| Cancel | Not applicable | Closes a confirmation without changing anything. | This Mac |

## GitHub in a sandbox

This one lives in an org's Settings › Harness, not on this pane. It is the fine-grained GitHub token that the org's sandboxed sessions push and open pull requests with. It is passed to them as GH_TOKEN.

| Option | Default | What it changes | Kept |
| --- | --- | --- | --- |
| Token | Not saved | Shows "Saved in the keychain" once saved. | This Mac |
| Save | Not applicable | Saves the token you pasted to the keychain. | This Mac |
| Remove | Not applicable | Removes the saved token. | This Mac |
| Create One on GitHub | Not applicable | Opens GitHub with the permissions filled in. Pick the repos there. | This Mac |
