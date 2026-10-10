---
type: requirement
status: in-progress
summary: "In one weekly pass, every open issue in the project has a priority in the team's own scheme: new issues get one and existing ones are re-checked and moved, with the result written back to GitHub. Success: after the weekly pass no open issue in the project is without a bucket, and the product lead does the pass in Gannin rather than on GitHub."
issues: [andrew-waters/gannin#154]
plans: [plans/2026-10-10-a-new-triage-feature-in-rituals-the-idea.md]
---

# Triage in Rituals

## Problem

Whoever owns priority (usually the product lead) sorts the backlog into the team's loose priority buckets (Now/Next/Later on a board field, labels, or similar) every week. It's slow: the issues and the signals that should shape priority (customer feedback, product metrics, health) are scattered, and each team marks priority its own way.

## Goal

In one weekly pass, every open issue in the project has a priority in the team's own scheme: new issues get one and existing ones are re-checked and moved, with the result written back to GitHub. Success: after the weekly pass no open issue in the project is without a bucket, and the product lead does the pass in Gannin rather than on GitHub.

## Who it's for

The product lead (or whoever owns priority), weekly.

## Requirements

1. Let a project define its priority scheme: ordered buckets backed by a single-select field on one board, or by labels
2. Give every open issue a priority in the team's scheme, new ones first, then re-check existing ones
3. Write chosen priorities back to GitHub, confirmed first
4. Run a live Claude Code session beside the queue (as planning does, with the user's MCP connectors and the team's skills) that suggests a bucket with reasons for each issue and can be asked to dig into one
5. Have Claude suggest a bucket for each issue, with its reasons, drawing on the issue, its activity, the harness, and the team's MCP connectors and skills (product metrics, health and observability)
6. A Triage row under Rituals for the weekly pass
7. Prioritisation's Triage list counts an issue as untriaged by the priority scheme, when one is set
8. The queue works without Claude: keys for buckets, skip, back, and write
9. With no scheme set, offer a one-click starter scheme (Now, Next, Later as labels)
10. The team's harness prompts with use: triage (and the skills they name) tell the session what to look at, picked when the session starts

## Out of scope

- Priority kept only in Gannin, never written to GitHub (later)
- Customer feedback as a source (a possible future harness feature)
- Counting how often suggestions are accepted
- Priority across projects or orgs: a scheme is per project
- Ranking within a bucket
- Gannin choosing or configuring MCP connectors: they're the user's own in Claude Code

## Acceptance criteria

- **R1** When a project's priority scheme is saved, the system shall keep its ordered buckets, each mapped to an option of a single-select field on one board or to a label, as a team file in the project's harness.
- **R2** When no scheme is set and the product lead picks the starter scheme, the system shall propose Now, Next and Later as labels, create any missing labels in the project's repos once confirmed, and save the scheme.
- **R3** The system shall list Triage under Rituals in the sidebar, with the number of the project's open issues that have no bucket.
- **R4** When reading an issue's bucket, the system shall use the scheme's field option or label on GitHub; an issue with none is untriaged, and one with labels of more than one bucket is flagged as conflicting.
- **R5** When the product lead starts a pass, the system shall queue, one at a time, the project's untriaged and conflicting open issues first, then bucketed ones with activity since the last pass (comments, linked PRs, label or field changes), with number keys to pick a bucket and arrows to skip or go back.
- **R6** When the product lead reviews the pass, the system shall list every change and, only once confirmed, write it to GitHub (adding the bucket's label and removing the others', or setting the field and adding the issue to the board if needed), updating the local issue history at once.
- **R7** When Claude Code isn't available or no session is started, the system shall let the product lead triage the whole queue without suggestions.
- **R8** When the product lead starts Triage with Claude, the system shall start a live Claude Code session in the harness with the triage prompts and skills picked at launch, the scheme and the queue's issues.
- **R9** When the session suggests a bucket for an issue, the queue shall show the suggestion with its reasons and the sources it drew on beside that issue, and one key shall accept it.
- **R10** When the product lead asks about the issue in view, the system shall send the question to the session and show its answer without leaving the queue.
- **R11** When a harness prompt says use: triage, the system shall offer it, and the skills it names, when a triage session starts, with its defaults ticked.
- **R12** When a scheme is set, Prioritisation's Triage list shall count an issue as untriaged by the scheme instead of by its workflow board Status.
- **R13** When a pass ends, Triage shall show how many of the project's open issues still have no bucket.
- **R14** When the product lead turns on Re-check all, the system shall queue every open bucketed issue after the untriaged and conflicting ones.
- **R15** When a pass's changes are written, the system shall record the pass's date in the project's triage team file, so the next pass knows what has changed since.
