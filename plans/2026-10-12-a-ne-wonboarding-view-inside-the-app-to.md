---
type: plan
status: in-progress
summary: "A view in Gannin that walks a new engineer through the project's key product and decision documents in the harness, possibly with a new ADR document type."
issues: [andrew-waters/gannin#279, andrew-waters/gannin#280, andrew-waters/gannin#281, andrew-waters/gannin#282, andrew-waters/gannin#283, andrew-waters/gannin#284, andrew-waters/gannin#285, andrew-waters/gannin#286]
touches: [andrew-waters/gannin]
owner: andrew-waters
agreed_by: [andrew-waters]
agreed_at: 2026-10-12
requirement: requirements/a-ne-wonboarding-view-inside-the-app-to.md
---

# Onboarding to the harness

A view in Gannin that walks a new engineer through the project's key product and decision documents in the harness, possibly with a new ADR document type.

## Requirement

In full in [requirements/a-ne-wonboarding-view-inside-the-app-to.md](../requirements/a-ne-wonboarding-view-inside-the-app-to.md).

**Problem:** A new engineer on a project can see what was built from the code, but not why. The reasons and decisions behind it are spread across many plans and requirements in the harness, and they don't know which matter or what order to read them in.

**Goal:** A new engineer can open one page for their project, find the area they'll work on, and read the decisions, requirements and plans that explain why it is the way it is, in a sensible order, without someone talking them through it.

**Who it's for:** Engineers new to a project (or to an area of it), and the team members who write the decisions they'll read.

**Scope:**

1. A new decision record (ADR) kind in the harness: a decisions/ folder, front matter type decision, with context, decision, alternatives and consequences, and a status (proposed, accepted, superseded).
2. An onboarding view that maps the project's requirements, decisions and plans by area, so a new engineer starts with the part they'll work on.
3. Areas and documents are picked automatically from front matter: accepted decisions first, then requirements, then plans, newest first, with superseded and rejected decisions folded away. A document marked key (front matter key: true) is lifted to the top of its area.
4. Decisions are written by hand (New under Harness, with Draft with Claude as other kinds have), and Suggest Decisions has Claude read the existing plans and propose ADRs for the decisions worth keeping, each reviewed and committed by a person.
5. Documents opened from the map are marked read on this Mac only, with a count read per area.
6. The map is a Harness › Onboarding row in the sidebar, for the window's project, beside a new Harness › Decisions row.
7. Docs: a new user docs page for Onboarding and Decisions, and updates to Concepts › Projects and harnesses, Get started › Create a harness and Concepts › Where things are kept.

**Out of scope:**

- Shared or reported reading progress: read marks never leave this Mac.
- Timeline or linear course views; the map by area is the one layout.
- A curated onboarding guide file kept by hand.
- Planning sessions' Agree writing ADRs (a later addition).
- Onboarding beyond the harness: repos, people, rituals, setting up a machine.

**Acceptance criteria:**

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

**Decisions:**

- What does a new engineer struggle with today? **Can't find the why: decisions and reasons are spread across plans and requirements, with no sense of which matter or in what order.**
- Where should decisions live? **A new ADR kind in the harness (decisions/, type decision), with status and supersession, listed under Harness like the other kinds.**
- What shape should the onboarding view take? **A map by area: documents grouped by domain or area of the code.**
- How are documents picked and ordered within an area? **Automatically from front matter (decisions, then requirements, then plans, newest first, superseded folded away), with key: true to pin a document to the top.**
- How do ADRs get filled when the kind is new? **Hand-written with Draft with Claude, plus Suggest Decisions: Claude proposes ADRs from existing plans, each reviewed and committed by a person. Planning's Agree does not write them (yet).**
- Should the view track what's been read? **Read marks on this Mac only, with a count per area. Not shared.**
- Where does the onboarding map live? **A Harness › Onboarding row in the sidebar, for the window's project.**
- Should old finished plans fold under Older? **No. Plans always show; only superseded and rejected decisions fold.**
- Are the requirements right? **Approved (R1 to R10).**

## Design

**Decisions as a harness kind.** Add `HarnessKind.decisions` (`decisions/`, type `decision`, a scale icon) following refines' footprint: path and type parsing, `parserVersion` bump, `HarnessAuthoring` guidance, `HarnessNewDocumentSheet` using `HarnessDocumentEditor` with the folder's `_template.md` (falling back to a built-in one), and the skeleton and tour in `HarnessCreate.swift` / `HarnessOnboarding.swift`. Front matter: `status` (proposed, accepted, rejected, superseded), `superseded_by` (a path), `plans` (where it came from), `domains`, `key`. The sidebar row, Harness page, palette and session briefs pick it up as a kind. A superseded decision's page links to its successor (R9).

**Suggest Decisions.** A sheet on the Decisions page in `DraftIssuesSheet`'s shape: `ClaudeRunner` reads the plans of the area picked first (a domain, or All), skipping those a decision already cites in `plans`, a batch at a time, returns JSON drafts (title, context, decision, alternatives, consequences, domains, source plan), each editable and ticked; Commit writes the ticked ones in one `HarnessStore.commit`.

**Onboarding map.** A new sidebar item first under Harness (`SidebarItem` case, page title, scene storage), an `OnboardingMap` built from the window's project's combined index: standard decisions, requirements and plans grouped under each of its `domains` (else its module folder, Other last; read once, ticked everywhere), ordered key, decisions, requirements, plans, newest first, superseded and rejected decisions under Older. Each area is a section with its read count; rows open the drawer as other harness rows do, and opening marks them read.

**Read marks.** `HarnessReadMarks` in `UserDefaults`, per harness repo, each read document's path with the blob SHA it had when read, as `PaletteRecents` keeps its IDs; a different SHA in the index shows Updated since you read it. Never committed.

**Docs.** A new `docs-site/src/content/docs/harness/onboarding-and-decisions.md`, plus the three existing pages.

**Areas it touches:**

- `andrew-waters/gannin` `Gannin/Harness/HarnessModels.swift#L51`: HarnessKind lists the document kinds (plans, requirements, findings, skills, prompts, learnings, research, refines). There is no ADR kind, and this harness has no STANDARDS.md or plans/_template.md.
- `andrew-waters/gannin` `Gannin/Harness/HarnessModels.swift#L182`: HarnessDocument.area is the first front matter domain, else the module folder. In this harness most dated plans have domains (sessions, delivery, harness and so on), but 9 have none, so an area map needs a fallback group.
- `andrew-waters/gannin` `Gannin/Views/MainView.swift#L1314-L1324`: Harness rows are ForEach(HarnessKind.allCases) tagged SidebarItem.harnessKind. Onboarding isn't a kind, so it needs its own SidebarItem or WorkloadTab case placed first in the Harness section, with its scene storage and PageTitles entry.
- `andrew-waters/gannin` `Gannin/Harness/HarnessViews.swift`: The Harness page: filter bar over front matter fields and a StatsTable of documents. Decisions get this for free once they're a kind; the map is a new view reading the same combined index.
- `andrew-waters/gannin` `Gannin/Harness/HarnessCreate.swift#L99-L190`: HarnessSkeleton holds STANDARDS.md, each folder's README and _template.md; HarnessOnboarding.swift's HarnessTour lists folders. Both get decisions/.

**Patterns to follow:**

- `andrew-waters/gannin` `Gannin/Harness/HarnessModels.swift#L50-L134`: A new kind is a HarnessKind case: rawValue, systemImage, singular (front matter type), and a folder in init(path:). Refines (andrew-waters/gannin#135) was the last added and is the template to follow. Bump HarnessDocument.parserVersion (now 9) so cached indexes pick up decisions/.
- `andrew-waters/gannin` `Gannin/Harness/HarnessEditors.swift#L1-L36`: HarnessNewDocumentSheet switches on kind; requirements and findings use HarnessDocumentEditor with the folder's _template.md and DraftWithClaudeSection, which a decision can reuse.
- `andrew-waters/gannin` `Gannin/Planning/DraftIssues.swift`: DraftIssuesSheet: ClaudeRunner reads a harness document and returns JSON drafts to edit, untick and confirm before writing. Suggest Decisions follows the same shape, ending in one HarnessStore.commit.
- `andrew-waters/gannin` `Gannin/Harness/HarnessAuthoring.swift#L70`: Per-kind authoring guidance and required front matter fields (refines: agreed). Decisions need an entry: status and superseded_by.
- `andrew-waters/gannin` `Gannin/Palette/PaletteItems.swift#L237-L252`: PaletteRecents keeps IDs in UserDefaults on this Mac. Read marks can be kept the same way, per harness repo, by document path.

**Risks:**

- `andrew-waters/gannin` `STANDARDS.md`: Harnesses made before this (including andrew-waters/gannin itself, which has no STANDARDS.md or plans/_template.md) won't have decisions/ or its template. The editor must fall back to Gannin's built-in template, and this harness needs its own decisions/ README and template added.
- `andrew-waters/gannin` `plans/`: Suggest Decisions over every plan is large (30+ plans here). Sending them all to one claude -p call may be slow or overflow; it should go a batch at a time, or by area, and skip plans already cited by a decision.
- `andrew-waters/gannin` `Gannin/Harness/HarnessModels.swift#L182`: Grouping by the first domain hides a document from its other domains; a document with [sessions, harness] only shows under sessions unless it's listed in each.

**Decisions:**

- Show a document with several domains under each, or only the first? **Under every domain it names; read marks are per document, so reading it once ticks it everywhere.**
- Does a changed document go back to unread? **No. It stays read and shows Updated since you read it (by blob SHA) until opened again.**
- How does Suggest Decisions go through many plans? **Pick an area (or All) first; Claude reads that area's uncited plans in batches.**
- Is the design right? **Approved.**

## Tasks

1. [andrew-waters/gannin#280](https://github.com/andrew-waters/gannin/issues/280) Add Decisions as a harness kind (satisfies R1, R2, R9)
2. [andrew-waters/gannin#281](https://github.com/andrew-waters/gannin/issues/281) New Decision with a template and Draft with Claude (satisfies R3)
3. [andrew-waters/gannin#282](https://github.com/andrew-waters/gannin/issues/282) Decisions folder in Create Harness and the tour (satisfies R5)
4. [andrew-waters/gannin#283](https://github.com/andrew-waters/gannin/issues/283) Suggest Decisions from plans (satisfies R4)
5. [andrew-waters/gannin#284](https://github.com/andrew-waters/gannin/issues/284) Harness › Onboarding map (satisfies R6, R7)
6. [andrew-waters/gannin#285](https://github.com/andrew-waters/gannin/issues/285) Read marks on the Onboarding map (satisfies R8, R11)
7. [andrew-waters/gannin#286](https://github.com/andrew-waters/gannin/issues/286) Docs for Onboarding and Decisions (satisfies R10)

**Decisions:**

- Are the tasks right? **Approved (seven tasks, all in andrew-waters/gannin).**
