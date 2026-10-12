---
type: requirement
status: in-progress
summary: "A new engineer can open one page for their project, find the area they'll work on, and read the decisions, requirements and plans that explain why it is the way it is, in a sensible order, without someone talking them through it."
issues: [andrew-waters/gannin#279]
plans: [plans/2026-10-12-a-ne-wonboarding-view-inside-the-app-to.md]
---

# Onboarding to the harness

## Problem

A new engineer on a project can see what was built from the code, but not why. The reasons and decisions behind it are spread across many plans and requirements in the harness, and they don't know which matter or what order to read them in.

## Goal

A new engineer can open one page for their project, find the area they'll work on, and read the decisions, requirements and plans that explain why it is the way it is, in a sensible order, without someone talking them through it.

## Who it's for

Engineers new to a project (or to an area of it), and the team members who write the decisions they'll read.

## Requirements

1. A new decision record (ADR) kind in the harness: a decisions/ folder, front matter type decision, with context, decision, alternatives and consequences, and a status (proposed, accepted, superseded).
2. An onboarding view that maps the project's requirements, decisions and plans by area, so a new engineer starts with the part they'll work on.
3. Areas and documents are picked automatically from front matter: accepted decisions first, then requirements, then plans, newest first, with superseded and rejected decisions folded away. A document marked key (front matter key: true) is lifted to the top of its area.
4. Decisions are written by hand (New under Harness, with Draft with Claude as other kinds have), and Suggest Decisions has Claude read the existing plans and propose ADRs for the decisions worth keeping, each reviewed and committed by a person.
5. Documents opened from the map are marked read on this Mac only, with a count read per area.
6. The map is a Harness › Onboarding row in the sidebar, for the window's project, beside a new Harness › Decisions row.
7. Docs: a new user docs page for Onboarding and Decisions, and updates to Concepts › Projects and harnesses, Get started › Create a harness and Concepts › Where things are kept.

## Out of scope

- Shared or reported reading progress: read marks never leave this Mac.
- Timeline or linear course views; the map by area is the one layout.
- A curated onboarding guide file kept by hand.
- Planning sessions' Agree writing ADRs (a later addition).
- Onboarding beyond the harness: repos, people, rituals, setting up a machine.

## Acceptance criteria

- **R1** When a harness has Markdown files under decisions/ (or with front matter type: decision), the system shall index them as Decisions, a harness kind of their own, with the status proposed, accepted, rejected or superseded, and a superseded_by link to the decision that replaced it.
- **R2** When the harness has decisions that follow the standard, the system shall show a Harness › Decisions row in the sidebar with their count, listing them as the other kinds are listed, and shall include them in the command palette and in session briefs as other documents are.
- **R3** When someone picks New on the Decisions page, the system shall open an editor with the decision template (context, decision, alternatives considered, consequences) and Draft with Claude, and commit one file to decisions/ only once they confirm.
- **R4** When someone picks Suggest Decisions and chooses an area (or All), the system shall have Claude read that area's plans not already cited by a decision, in batches, and propose decisions worth keeping, each naming the plan it came from; it shall commit only those the person reviews and ticks, each as its own decision file, in one commit.
- **R5** When a harness is created with Create Harness, the system shall include a decisions/ folder with a template and README, and the Harness tour shall describe it.
- **R6** When someone opens Harness › Onboarding, the system shall show the window's project's decisions, requirements and plans that follow the standard, grouped by area: a document appears under each of its domains, else under its module folder, else under Other.
- **R7** Within an area, the system shall list documents marked key: true first, then accepted and proposed decisions, then requirements, then plans, each group newest first, with superseded and rejected decisions folded under Older. Plans are never folded, whatever their status.
- **R8** When a document is opened from the Onboarding map, the system shall mark it read on this Mac, show a read tick on its row and a count read of the area's documents in the area's header; marks shall never be committed or sent anywhere.
- **R11** When a document marked read has changed since it was read (its file's SHA differs), the system shall keep it read and show Updated since you read it on its row; opening it again clears that.
- **R9** When a superseded decision is shown, the system shall link to the decision that superseded it.
- **R10** When the change ships, gannin.ai/docs shall have a page for Onboarding and Decisions, and Projects and harnesses, Create a harness and Where things are kept shall describe the decisions/ folder and read marks.

Planned in [plans/2026-10-12-a-ne-wonboarding-view-inside-the-app-to.md](../plans/2026-10-12-a-ne-wonboarding-view-inside-the-app-to.md).
