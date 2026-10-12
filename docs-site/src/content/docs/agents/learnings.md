---
title: Learnings
description: Keep the rules and reasons people give in review, so the next review applies them.
sidebar:
  order: 12
---

A learning is a rule and the reason behind it, from a review, kept in your project's [harness](/docs/concepts/projects-and-harnesses/) so everyone's reviews and sessions use it. They live in `learnings/`, grouped by repo, and show under Harness › Learnings.

Each has a repo, a scope (the whole repo, folders, files or lines), the rule, the reason, where it came from, and a status of active or retired. Only active ones are used.

## Saving one

Save as Learning (a lightbulb) is on comments in issue and PR drawers, and on the review threads in a session's PRs pane. It opens an editor. Nothing is committed until you say so, and each save is one file.

A review can also suggest learnings from explanations people gave in the PR. They're listed in the review's Learnings row, each with Save as Learning.

## How reviews use them

A review's prompt lists the active learnings for the PR's repo. Work on This briefs a session with those for the issue's and its linked PRs' repos.

In a review tab, the Learnings row lists those covering the diff, those applied and those suggested. The diff shows them in place: file and folder ones at the top, line ones at their line, with the lines marked. A learning the reviewer applied shows as a card on its line, with Challenge and Edit Learning.

Challenge sends your objection to the reviewer, who looks again. Edit Learning (also on a learning's own page) changes the rule or retires it.
