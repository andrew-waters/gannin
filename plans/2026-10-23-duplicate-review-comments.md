---
type: plan
status: In Review
summary: Leave out findings a follow-up review would repeat, checking body findings against earlier reviews, allowing a few lines' leeway and counting the viewer's own outdated comments.
issues: [andrew-waters/gannin#467]
domains: [sessions, reviews]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Avoid duplicate review comments on follow-up reviews

## Context

Gannin doesn't keep its own list of what it sent: before posting, `ReviewedPullRequest.comments(for:draft:)`
compares findings with the PR's review comments on GitHub, which also covers posts from elsewhere. A
follow-up review got past it three ways: findings that go in the body were never checked (and its new
summary means `PostedReview.repeated` doesn't match), a finding had to be on exactly the commented line,
and outdated comments never counted, so a point raised before a push went up again after it.

## Decisions

- Keep GitHub as the record. Fetch every submitted review with the comments and check body findings
  against the lines of their bodies that name the finding's path.
- A comment within three lines on the same side covers an inline finding; one anywhere in the file
  covers a body finding.
- Count only the viewer's outdated comments, at any line: they were sent, while someone else's may be
  about code that has changed.

## Tasks

- [x] `earlierReviews` and `viewer` on `ReviewedPullRequest`, fetched leniently with the comments;
      `GitHubAPI.reviews` shared with `myReviews`
- [x] Match body findings, line leeway and own outdated comments in `comments(for:draft:)`
- [x] Post Review re-fetches reviews with comments and lists what was left out and why
- [x] Tests in `ReviewDuplicateCommentTests`
- [x] Docs (Reviews, Auto review), rule, CHANGELOG
