---
title: Attachments
description: Give a session's Claude screenshots and other files, wherever it runs.
sidebar:
  order: 9
---

Dragging a file into the terminal only works when Claude runs on this Mac. Attachments work wherever it runs: this Mac, a sandbox, your server or a sandbox there.

## Adding files

Drop files anywhere on a session's side panel, whichever pane it shows; an image dragged from a browser or Preview works too, saved as a PNG. The panel outlines itself while you drag, and the files appear under **Attachments** in the Issue pane (Session for an Ask or a helper). You can also use **Paste** there, for a screenshot copied with ⌃⇧⌘4 or files copied in Finder, or **Add Files** to pick them.

Each file is copied into the session's folder where Claude runs, in `.gannin/attachments/`, which is never committed. Files can be up to 25 MB; folders can't be attached. Names are tidied so they're safe to use in a shell, and one that's taken gets a number.

A spinner shows while a file is copied. If it can't be copied (the server isn't reachable, say), a warning shows on it, with the reason in its tooltip, and **Try Again** in its menu. A file dropped before the session has started is copied once it has, and one marked **Not copied** (say, after Gannin quit mid-copy) is copied again when the session next starts, or with Try Again.

## Sending them

Click an attachment to add it to your next prompt. Its thumbnail appears above the box under the terminal (an image's preview, a document's first page, or the file's icon); click its × to leave it out. **Send** sends what you typed, with the attachments' paths for Claude to read, or just the paths if you typed nothing.

Each attachment says **Not sent** until a prompt with it goes, then **Sent**. If you gave Claude a file another way, such as typing its path in the terminal, use **Mark as Sent** in its menu.

## An attachment's menu

- **Add to Prompt** or **Remove from Prompt**.
- **Copy Path**: the path as Claude sees it, to type into the terminal yourself.
- **Mark as Sent** or **Mark as Not Sent**.
- **Remove**: takes it off the list and deletes it from the session's folder.

Attachments last as long as the session. Forgetting or finishing it removes them, here and where Claude runs.
