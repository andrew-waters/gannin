---
title: Privacy and terms
description: Every service Gannin talks to, what it sends, what it writes, and Claude logins.
sidebar:
  order: 5
---

Gannin has no server of its own and no analytics. It talks to these services.

| Service | What Gannin sends | Why |
| --- | --- | --- |
| GitHub (github.com, api.github.com) | Your token with each request, and the queries for what you look at. | Everything Gannin shows comes from GitHub. |
| gannin.ai | A request for `appcast.xml`, and the download of an update you accept. | Checking for updates (Gannin › Check for Updates). |
| date.nager.at | A country code and a year. | Bank holidays for the regions you pick in Working Time. |
| Anthropic, through Claude Code | What you and the session give Claude: prompts, the issue's brief, files Claude reads. | Agent sessions and Claude's drafting help. Claude Code sends this, signed in as you; Gannin doesn't call Anthropic itself. |
| github.com (Apple's `container` releases) | A download request. | Installing or updating `container` for sandboxes, when you say so. |
| Docker Hub, Debian's package mirrors, cli.github.com and npm | Download requests, from the sandbox's image build. | Building Gannin's sandbox base image (Node, git, gh and Claude Code), when sandboxing is on. A repo's own Containerfile may fetch more. |

## What Gannin writes to GitHub

What you ask for, confirmed first: creating and closing issues and sub-issues, adding and removing labels, requesting and removing reviewers, posting a review and resolving its threads, adding issues to boards and setting their fields, editing a board's fields, making, copying, linking, unlinking, closing and reopening boards, creating a harness repo, and commits to a harness (team settings, documents, session and review records, attached images).

The exceptions, each one you turn on yourself:

- **Post automatic reviews** (Settings › General) posts the reviews Gannin starts by itself as comments, and resolves the threads they say are dealt with. They never approve or request changes.
- **Don't ask again** on recording a session commits its record to the harness without asking, for that org. Org settings › Harness undoes it.
- **Routines** that work on an issue commit its session record without asking: scheduling it is the consent.

Agent sessions run Claude Code as you, so what a session does on GitHub (pushing a branch, opening a pull request) is done with your own git and gh login. Routines' limits say how far an unattended session may go.

## What stays on this Mac

Your GitHub token (in the keychain), caches, your app settings, stars, hidden items and sessions. [Where things are kept](/docs/concepts/where-things-are-kept/) has the full list.

## Claude logins

Gannin never collects, stores or passes on a Claude subscription's login. Claude Code signs in through Anthropic's own flow, on this Mac or inside a sandbox, and keeps that login itself. The only Claude credential Gannin can hold is an API key you paste for sandboxes, kept in your keychain.

**A Claude login is one per person, never shared.** Sign in with your own account or key. Pro and Max subscriptions are for personal use; for a team's work, use Team or Enterprise seats or API keys.
