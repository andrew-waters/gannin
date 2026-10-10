---
type: plan
status: In progress
summary: Images can be attached while creating an issue in New Issue, Write Issue and Quick Change; they're committed to the project's harness and shown inline in the issue from there, confirmed with the issue by its Create button.
issues: [andrew-waters/gannin#122]
domains: [issues]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Attach images to issues created from Gannin

## Context

Creating an issue in Gannin had no way to add an image, so screenshots, mockups and diagrams were
added afterwards on github.com. GitHub's REST and GraphQL APIs have no endpoint for issue
attachments: the web editor's uploads go through the browser's session, not a token. So an image
has to be committed to a repo and linked from the issue's body as
`https://github.com/<repo>/blob/<commit>/<path>?raw=true`, which renders inline for anyone who can
read that repo, private ones included.

## Decisions

- **Committed to the project's harness**, the one covering the issue's repo
  (`OrgConfig.harness(covering:)`), under
  `attachments/issues/<owner>/<name>/<date>-<id>/<file>`, one commit per issue through
  `HarnessStore.commit` (5 MB a file). Only people who can read the harness see them, which the
  sheet says when the harness isn't the issue's repo. Links pin the commit, so they never move.
  An org with no harness can't attach images, and says so.
- **Flows**: New Issue (⌘N, issues and draft items), Write Issue (from a Prioritisation note),
  Quick Change's issue (its screenshots, off by default, since they were promised to stay with
  the session), and `skills/create-issue.md` for sessions. Draft Issues and Planning Agree stay
  text only.
- **Types and sizes**: PNG, JPEG, GIF and WebP as they are; any other image (TIFF, HEIC, a
  pasted picture) as PNG. One over 5 MB is kept as a JPEG when that fits, else refused.
- **Adding**: drop on the drop zone (`ScreenshotDropTarget`), paste (⌘V while the clipboard holds
  only pictures, or Paste), or Add Images. In New Issue each adds a placeholder
  `![name](attachment:name)` to the end of the description, which can be moved; removing the
  image removes it. Placeholders are pointed at the committed image when the issue is created, and
  an image whose placeholder was removed (or that Claude's draft dropped) goes at the end.
- **Confirmation**: the Create button names the images ("Commit 2 Images and Create Issue"), saying what happens first,
  beside a line saying where they go, who sees them and to leave out sensitive data. Nothing is
  written before it's pressed. Images are committed first, then the issue; when GitHub refuses
  the issue, the error says the images are committed and a retry links them rather than committing
  them again (again into the new harness when the repo has changed since).

## Tasks

- [x] `IssueImages` (`Issues/IssueImages.swift`): preparing images, paths, links, placeholders
  and the body, `IssueImageSet` (adding, pasting, picking, committing) and `IssueImagesSection`.
- [x] New Issue: the section, placeholders, the button and the commit before `createIssue`.
- [x] Write Issue: the section and the commit.
- [x] Quick Change: Add the screenshots to the issue, and keeping them when claude fills it out.
- [x] `skills/create-issue.md`: committing an image to the harness and linking it.
- [x] Tests (`IssueImagesTests`).
- [x] `CLAUDE.md`.
