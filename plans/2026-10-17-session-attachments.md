---
type: plan
status: in-progress
summary: "Attach files for a session's Claude wherever it runs (andrew-waters/gannin#401): drop on the side panel or paste, copy into .gannin/attachments/ on the session's box, click to stage with the next prompt (thumbnails over the composer), and track which were sent."
issues: [andrew-waters/gannin#401]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Drag and drop files to code sessions

Dragging a file into a session's terminal only works when claude runs on this Mac. In a sandbox or on a server the path means nothing to it (andrew-waters/gannin#401).

## Decisions

- **Where it shows:** an Attachments section in the Issue pane (Session for an Ask or a helper), not a tab of its own. Drops land anywhere on the side panel, with an outline while dragging, and switch to the Issue pane.
- **How files reach claude:** the way Quick Change screenshots already do. Each file goes into `.gannin/attachments/` in the session's folder on its box: written directly on this Mac, piped over ssh on stdin for a server. A sandbox mounts the issue's folder writable, so it sees them. `.gannin/` is kept out of git in harness and plain worktrees, so attachments are never committed. A copy stays in the session's folder on this Mac, for thumbnails and to try again.
- **What "add to prompt" does:** clicking stages the attachment in the composer, which grows a strip of Quick Look thumbnails (images, a document's first page, else its icon). Send adds the paths, relative to where claude runs, to what was typed.
- **"Sent":** set when a prompt naming the attachment is submitted from the composer, with Mark as Sent / Not Sent in its menu for files given another way.
- **Paste:** a Paste button takes the clipboard's files, or its image as a PNG. An image dragged from another app with no file (a browser, Preview) is saved as a PNG too.
- **Limits:** 25 MB a file, no folders, and attachments last as long as the session. Forget and Finish delete them on the box too, best effort.
- **Names:** unique across the issue session and its helpers, which share the folder on the box, and its quick-change screenshots.
- **Before the folder exists:** the upload never makes the session's folder (the start script takes an existing one for a checkout, and a harness clone needs an empty one). It fails as Not copied and is retried when the session starts, or with Try Again.
- **Terminal:** dropping on the terminal is unchanged (a planning session's Share Documents).

## Tasks

- [x] `SessionAttachment` on `CodeSession`, decoded leniently.
- [x] Store: add (drop, pick, paste), upload to the box, stage, send, mark sent, remove (`Sessions/SessionAttachments.swift`); `attachmentNames` skips names already taken.
- [x] Attachments section in `SessionPanel`; panel-wide drop target with an overlay.
- [x] Composer strip of staged thumbnails; Send with only attachments.
- [x] Tests (`SessionAttachmentsTests`), docs page `agents/attachments.md`, Work on This page, CHANGELOG, sessions-core rule.
- [x] Pair review, three rounds: upload guards the session folder and retries on start; names shared with helpers; Not copied state with Try Again; box copies deleted on Forget; local copies written off the main actor; images dropped with no file; a drop's notices add up.
- [ ] Checked by hand on a session on this Mac, in a sandbox and on a server.
