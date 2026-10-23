---
type: plan
status: In progress
summary: New users are guided through creating a harness or linking one they have, in one Set Up Harness sheet that opens by itself for an org with no project, can be put off and reopened, and finishes with missing starter files and the checkout.
issues: [andrew-waters/gannin#463]
domains: [harness, onboarding]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Guided harness setup

## Context

Creating a harness already had a short tour (`CreateHarnessSheet`), but nothing led a new user to
it: it was only under Org settings › Harness and Projects, the Harness page's empty state just
pointed at Settings, and linking an existing harness was a bare menu of every repo with no check
for write access, no check of what the repo held and no word on where it's checked out.

## Approach

- One sheet, `SetUpHarnessSheet`, grown from the old one: the tour, then Create a new harness or
  Link one you have, then Finish. Linking reuses Projects' write-access check
  (`GitHubAPI.writableHarnessRepo`).
- Finish lists the starter files (`HarnessSkeleton`) the harness lacks and offers one confirmed
  commit of only those, worked out again at the head it commits onto. It covers a harness someone
  made by hand and a create whose layout commit failed. Then the checkout on this Mac.
- It opens by itself once per launch for an org with no project; closing it without one puts it
  off for that org on this Mac (`HarnessSetupPrompt`). It reopens from the sidebar footer, the
  Harness and Onboarding empty states, Org settings, and Gannin › Set Up Harness, which also works
  for an org that has projects so the flow can be run again without removing anything.
- "Usable" is: linked, with the starter files, and the window's project. Boards and investments
  stay in Org settings › Projects, linked from Finish.

## Tasks

- [x] `SetUpHarnessSheet`: create or link, then Finish with starter files and the checkout
- [x] `HarnessSetupPrompt`, the window's Set Up Harness action, sidebar and empty-state buttons, Gannin › Set Up Harness
- [x] Settings › Harness and Projects open the sheet; Projects' add shares the write-access check
- [x] `HarnessSetupTests`
- [x] Docs (Set up a harness, Orgs and projects, Harness and Projects settings), rules and CHANGELOG
