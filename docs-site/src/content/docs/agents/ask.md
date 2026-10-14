---
title: Ask
description: Open-ended conversations with Claude, with the files it makes kept for you.
sidebar:
  order: 6
---

An Ask is a conversation about anything: it isn't tied to an issue, PR or plan. Use it for questions, quick analyses, or making a file.

## Starting one

New Ask is at the top of the sidebar, in the Claude Code window's **+**, on the Agents page and in the command palette. Type your first message ("Ask anything…"), pick the project and, if you like, the team's Ask prompts and skills, then press Start (Return; Shift-Return is a new line).

An Ask always runs on this Mac, in the project's harness checkout, in a folder of its own. Claude can read Gannin's view of your org there.

## The side panel

An Ask's panel is Session, then PRs once it has some, then Activity (there are no Changes).

**Artifacts** lists the claude.ai artifacts Claude published, with Open and Copy Link. **Ask for an Artifact** (or Ask for Another) asks Claude to publish its answer as a page, with an optional note on what it should show. Artifacts are private to you until you share them.

**Files** lists what Claude saved in the Ask's folder, and anything it wrote elsewhere under Written elsewhere, newest first with size and time. The list updates as Claude works. Click a file to open it, or drag it out. Its menu has Open With, Show in Finder, Save a Copy, Copy and Commit to Harness. (Files can only be listed for an Ask on this Mac.)

## Commit to Harness

Commit to Harness puts a file in the harness under `research/`, in a folder for the conversation with a README naming its question and files. The sheet previews the file, shows where it goes and warns about sensitive data. You have to tick a box before Commit is enabled, and Cancel is the default button, so Return never commits. Nothing else commits an Ask's files. Committed files appear under Research in the sidebar.

## Keeping and deleting

Asks are kept until you delete them. Agents and the sidebar's Agents › Ask list them with title, first message, files and last active. Open resumes one. Rename and Delete are in the row's menu. Delete asks first, ends Claude and removes the folder and every file in it; anything already committed to the harness stays. If the folder won't go, Delete Anyway forgets the session and leaves the folder. An Ask never offers Finish and Clean Up. The Ask's own tab has a Delete button beside Stop Claude, with the same confirmation.
