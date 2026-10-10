---
title: Privacy and terms
description: Every service Gannin talks to, what it sends, what it writes, and Claude logins.
sidebar:
  order: 5
---

Gannin has no server of its own and no analytics. It talks to these services, and only these.

| Service | What Gannin sends | Why |
| --- | --- | --- |
| GitHub (github.com, api.github.com) | Your token with each request, and the queries for what you look at. | Everything Gannin shows comes from GitHub. |
| gannin.ai | A request for `appcast.xml`, and the download of an update you accept. | Checking for updates (Gannin › Check for Updates). |
| date.nager.at | A country code and a year. | Bank holidays for the regions you pick in Working Time. |
| Anthropic, through Claude Code | What you and the session give Claude: prompts, the issue's brief, files Claude reads. | Agent sessions and Claude's drafting help. Claude Code sends this, signed in as you; Gannin doesn't call Anthropic itself. |
| github.com (Apple's `container` releases) | A download request. | Installing or updating `container` for sandboxes, when you say so. |

## What Gannin writes to GitHub

Only what you ask for, and every write is confirmed first: requesting reviewers, posting a review, creating issues and sub-issues, adding labels, setting board fields, making or closing boards, and commits to a harness (team settings, documents, session and review records, attached images). Automatic reviews, when you turn them on in Settings › General, post as comments and never approve or request changes.

Agent sessions run Claude Code as you, so what a session does on GitHub (pushing a branch, opening a pull request) is done with your own git and gh login. Routines' limits say how far an unattended session may go.

## What stays on this Mac

Your GitHub token (in the keychain), caches, your app settings, stars, hidden items and sessions. [Where things are kept](/docs/concepts/where-things-are-kept/) has the full list.

## Claude logins

Gannin never collects, stores or passes on a Claude subscription's login. Claude Code signs in through Anthropic's own flow, on this Mac or inside a sandbox, and keeps that login itself. The only Claude credential Gannin can hold is an API key you paste for sandboxes, kept in your keychain.

**A Claude login is one per person, never shared.** Sign in with your own account or key. Pro and Max subscriptions are for personal use; for a team's work, use Team or Enterprise seats or API keys.
