---
title: Design and Refine
description: Step through a web page with the team, note what to improve, and end with issues.
sidebar:
  order: 16
---

Design and Refine is a ritual for the team to walk through a page it has already shipped, together on the shared screen, and turn the rough edges it spots into issues. One person drives; Claude Code sits in as co-reviewer, reading the code behind the page.

## Starting one

Open **Rituals › Design and Refine** and press **New Design and Refine** (it's also in the Claude Code window's **+**, the toolbar of **Agents › Waiting on You** and the command palette). The New Design and Refine tab asks for:

- **Project**: the harness the session runs in.
- **Page**: the address to step through. `https` is added when you leave the scheme out, and `http` for `localhost`.
- **Name**: what's being looked at, for the tab and the lists. Left empty, it's the page's address.
- **Its code**: the repos the page's code is in, the project's first ticked. Claude looks through these.
- **Who's here**: tick the org's people, and type names for anyone outside it.

**Start** (⌘↩) opens the session in its tab. It always runs on this Mac, in the project's harness, in its own folder `.worktrees/refine-<date>-<name>/`, which is kept out of git. Claude is told it's a co-reviewer: it reads the code and never changes it.

## Stepping through the page

The session's tab shows the page in a browser inside Gannin, with the findings beside it. Above the page are **Back**, **Forward**, **Reload** and the address: type a new one and press Return to go there. Links work as they would in a browser. **Terminal** opens Claude's terminal below, with its composer.

Each project keeps its own logins for these pages, so signing in to staging once lasts from one session to the next, and never reaches another project's sessions. **⋯ › Sign Out of Pages** forgets this project's logins; Settings › Storage signs out of every project's. Plain `http` pages, such as `localhost`, load here too.

## Noting findings

Beside the page, **Who's here** lists the meeting: take someone off with ×, or type a name and press **Add**. Below it, type what the room spotted and press **Add Finding** (⌘↩). Each finding keeps the page's address and title as they were then, and the time, shown under its note; the page's link opens it again.

Double-click a finding, or use **Edit** in its menu, to change its note; **Delete** removes it. Drag findings to put them in order.

## Screenshots

**Screenshot** takes the part of the page in view and opens it to mark up. Pick **Box**, **Arrow** or **Text** above it: drag to draw a box or an arrow, or type the text and click where it goes. **Undo** (⌘Z) takes the last mark off and **Clear** takes them all. Under **Attach to**, pick a finding already noted, or leave it on **A new finding** and type what the room spotted, then press **Attach** (⌘↩).

A finding's screenshots show under it. Click one to change its marks; its menu also has **Show in Finder** and **Delete Screenshot**. Screenshots are saved in the session's folder on this Mac, made small enough to commit to the harness later, and nothing leaves this Mac until the room agrees the session and ticks each one.

## Claude as co-reviewer

Claude reads the code of the repos ticked at the start (cloning any not in the harness's `projects/` yet), and never changes it. Each finding is passed to it as it's noted, and soon after, **Where it lives** shows under the finding: the files and components Claude thinks it's in, and why. You can keep noting findings while it looks; it works through them in order, and the panel says while it's busy.

Claude also looks at each screenshot and may suggest findings the room didn't raise. These show under **Claude suggests**, marked as Claude's with where they came from. **Keep** turns one into a finding (marked "Claude's suggestion, kept", with its screenshot attached); **Dismiss** puts it away.

## Meeting transcript

After the session, press **Transcript** and paste the meeting's transcript (Google Meet's, say), or press **Choose File**, or drop the file on the findings: text, `.vtt`, `.srt`, Word and RTF files are read. **Share with Claude** (⌘↩) passes it on, and Claude suggests findings from it under **Claude suggests**, marked "From the transcript", to keep or dismiss like any other. Open **Transcript** again to replace it.

The transcript stays on this Mac, as `transcript.txt` in the session's folder, for Claude to read. It's never committed to the harness or put in an issue.

## Agreeing

When the room is done, press **Agree**. Each finding shows as an issue to raise: edit its title, description (its note, the page, and where Claude thinks it lives), repo and labels, or untick it to leave it out. The repo starts as the one Claude's scouting points to, else the first ticked at the start.

Below are the screenshots attached to the findings being raised, each with a warning: a screenshot shows whatever was on screen, everyone who can read the harness will see it, and git keeps it for good. Each starts unticked; tick only those you've checked. A screenshot left unticked is neither committed nor linked from any issue.

**Agree and Write** makes the issues and adds each to the project's workflow board, each linking to its ticked screenshots in the harness, then commits the record, `refines/<date>-<name>/README.md`, with the ticked screenshots beside it. The record lists who was here, the page, and each finding with its issue (or "not raised") and screenshots. If another session's record already has that name, this one takes the next free one (`-2`, `-3`). Many screenshots go in more than one commit. Cancel is the default, so Return never writes. If something fails, Agree and Write again makes only what wasn't made. If an issue couldn't be added to the board, the sheet says so and stays open, and **Agree** stays available to try again.

Screenshots in issues show only to people who can read the harness; anyone else sees a broken image. The transcript is never committed.

## Coming back to it

The session is kept with Gannin's others, findings, screenshots and Claude's suggestions included, so quitting Gannin or closing the tab and opening it again brings it back on the page it was last on. Once agreed, each finding links to its issue, and **Rituals › Design and Refine** shows the session as agreed. Noting findings, screenshots and the transcript stop then, since nothing new would reach the issues or the record. A screenshot an issue links to can't have its marks changed or be deleted, so the links keep working.
