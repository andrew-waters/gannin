---
title: Sign in with GitHub
description: How signing in works, and why Gannin asks for each permission.
sidebar:
  order: 3
---

The first time Gannin opens it asks you to sign in with GitHub. It uses GitHub's device sign-in: Gannin shows a short code, opens GitHub in your browser, and you paste the code there and approve. Your token is kept in your Mac's keychain, and only Gannin's requests to GitHub use it.

## Why it asks for each scope

GitHub's sign-in for apps like Gannin offers broad scopes only, so Gannin asks for these four.

| Scope | Why Gannin needs it |
| --- | --- |
| `read:user` | Your name, login and avatar. |
| `read:org` | The orgs you belong to, their members and teams. |
| `repo` | Reading pull requests, issues, checks and files in private repos. GitHub has no read-only scope for private repos, so this one also allows writing. Gannin writes when you ask it to, and confirms first: issues, labels, reviewers, reviews, boards and harness commits. A few writes you can switch to happen by themselves; [Privacy and terms](/docs/concepts/privacy/) lists every write and those exceptions. |
| `project` | Reading project boards (the Issues pages and Boards need it), and changing them when you ask: adding an issue to a board, setting a field, editing a board's fields, making, copying, linking or closing a board. |

## If your org isn't listed

Some orgs restrict which OAuth apps can see their data. If an org you belong to is missing, or its pages are empty, ask an owner of the org to approve Gannin in the org's settings on GitHub (Third-party access), or request access from your own GitHub settings under Applications.

## Signing out

**Settings › General** has your account with Sign Out. **Settings › Storage › Erase Everything and Sign Out** also deletes what Gannin keeps on this Mac.
