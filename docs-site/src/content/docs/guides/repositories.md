---
title: Repositories
description: Everyday git on the repos you have cloned, from Work › Repositories.
sidebar:
  order: 3
---

Work › Repositories covers everyday local git: see what changed, stage and commit, switch branches, push and tag. It's the git you already have installed, so a separate git client is optional.

## What it uses, and what it won't touch

Gannin runs the `git` command on your Mac, with your own config, hooks, signing and credential helper. It never asks for, stores or handles a git credential, and nothing prompts for a password: if git needs one and your credential helper can't supply it, the action fails and shows you what git said.

When something fails, whether git itself or a hook, the full output is shown.

## Picking a repo

The page shows one repo at a time. The **switcher** at the top left of the bar picks it, and your choice is remembered per window and per org.

The switcher lists the window's project's repos, those cloned on this Mac first, each with its branch, changes, and how far ahead or behind it is. **Add a Repo** adds one to the project. The addition waits with the project's other changes until you commit them to its harness. A project that names no repos lists those with work in flight and the clones saved here, with no Add.

A repo that isn't on this Mac offers **Clone**, **Clone To** and **Add Existing Clone**. Clone uses gh when you have it, else git over https, and puts the repo inside the project's harness checkout, or in your workspace folder (set in Settings › General) with no harness checked out. If a clone can't be read, **Use Another Folder** points Gannin at a different one.

## The bar

Beside the switcher are the **branch** and **worktree** buttons, then **History** and **Changes**. At the right:

- The sync button, which changes with the state of the branch: **Publish Branch** when it has no upstream, **Pull** with the arrows when you're behind, **Push** when you're ahead, otherwise **Fetch**. Its menu has Fetch, Pull, Push (or Publish Branch) and **Force Push**.
- **Open**: Open in your editor, Open in Terminal, Show in Finder, Open on GitHub, Copy Path and Use Another Folder.

Force Push is always confirmed first and uses `--force-with-lease`, so it won't overwrite commits you haven't had, even ones a background fetch brought in.

Pull follows your `pull.rebase` setting. When git can't tell how to reconcile diverged branches, Gannin asks **Merge** or **Rebase**.

While the page is open, Gannin refreshes the repo every ten seconds while the app is active, and fetches from the remote every five minutes in the background. That's git's own network use, not your GitHub API [budget](/docs/concepts/github-budget/). It never runs beside something you started.

## History

The commits of the checked-out branch, newest first, 200 at a time (**Show 200 More** loads more). Search commits, authors, SHAs and tags from the field at the top. Each commit shows its SHA, author and time, **Not pushed** when it's only here, and the other branches and tags at it.

Pick a commit to see its whole message, its files and a file's diff. A merge shows changes against its first parent.

Tagging is done here. **Tag This Commit**, in the commit's right-click menu or its header, opens a sheet where you set the name (the next patch version is suggested, with the last tag beside it), an optional message that makes it an annotated tag, and **Push to origin**, on by default. It warns when the commit is tagged already. A tag's right-click menu pushes it, makes a branch from it, or deletes it, here or here and on origin. **Push N Tags** pushes the tags that are only here.

## Changes

Files are grouped as **Conflicted**, **Staged** and **Changes** (unstaged and new), with **Stage All** and **Unstage All**. Each file has a button and a right-click menu: stage or unstage, discard (confirmed), **Take Ours**, **Take Theirs**, **Mark Resolved**, open in your editor, and Show in Finder.

The diff numbers both sides. Each hunk has **Stage**, **Unstage** and **Discard** buttons. Hunk buttons are unavailable while **Hide whitespace** is on. Binary files show their size before and after, and images show as pictures.

Banners appear when a merge or rebase is under way (**Continue** once nothing is in conflict, or **Abort**), when changes were left on another branch (**Restore** or **Drop**), and on a detached HEAD.

### Committing

Write a summary and an optional description. The summary's count turns orange past 50 characters and red past 72. The button names the branch, such as "Commit 2 Files to main", and ⌘↩ presses it.

- **Amend** adds what's staged to the last commit. It's only available for a commit that hasn't been pushed.
- **Undo** takes the last unpushed commit back, keeping its changes staged and its message in the fields.

Discarding a staged file that also has unstaged edits says that both go.

## Branches

The branch button opens a popover with a search field (arrows move, Return switches), your local branches, and those that only exist on origin. A local branch can show how far ahead or behind it is, **Not published**, **Gone from origin**, or the worktree that holds it. **New Branch** is at the foot.

A branch's right-click menu has Switch to it, New Worktree for it, New Branch from it, Publish, Rename, Copy Name and Delete (here, on its remote, or both). **Delete Anyway** appears when the branch holds commits that are on no other branch.

New branches don't track their base, so the first push publishes them under their own name.

Switching with uncommitted changes asks whether to **Leave Them** on the branch you're leaving, which stashes them as "Gannin: left on <branch>" and offers them back when you return, or **Bring Them** along.

## Worktrees

A worktree is another checkout of the same clone, on its own branch, so work on two branches can sit side by side. The worktree button lists them: pick one to work in it, open it, or Remove it (forced only after Gannin says what would be lost). **New Worktree** makes one, and **Prune** clears the records of ones whose folders are gone. The clone itself is called Main.

New worktrees go beside the clone, or inside the harness checkout for a repo cloned there, as Claude Code sessions lay them out.

## Related

- [Org settings › Repositories](/docs/settings/org/repositories/) sets which repos count and which need review.
- [Keyboard shortcuts](/docs/keyboard-shortcuts/) lists the shortcuts for the popovers and the commit button.
