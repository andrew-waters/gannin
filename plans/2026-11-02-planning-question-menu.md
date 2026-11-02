---
type: plan
status: In Review
summary: A Question menu, shown only in the Claude Code window, lists a planning question's actions with their shortcuts (⌘1 to ⌘9 to answer), fed by the question card through a focused scene value.
issues: [andrew-waters/gannin#536]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Planning question shortcuts in the menu bar

## Approach

- [x] `PlanningQuestionMenu` (`Sessions/PlanningQuestionMenu.swift`): what the card publishes with `focusedSceneValue(\.planningQuestion)`: the style, options and actions. Compared by what the menu shows, so focus changes update it, not every redraw.
- [x] `PlanningQuestionView` publishes it; each action calls the same `pick`, highlight, `choose` and back code its keys and buttons use, so a menu item answers as the key does. The keys are unchanged.
- [x] `PlanningQuestionCommands`: a Question menu with ⌘1 to ⌘9 to answer (One at a Time), Previous, Next and Choose Highlighted (Keyboard List), Next or Send on ⌘↩, Back and Skip. Disabled when no question is up. ⌘ combinations only: a bare key as a menu equivalent is taken before a focused text field, which was the bug in #533.
- [x] The footer's Next/Send button drops its own ⌘↩ so it isn't bound twice.
- [x] `QuestionMenuVisibility` hides the menu outside the Claude Code window, as `Commands` can't be conditional.
- [x] Tests for the items each style gets.
- [ ] Check by hand with `scripts/relaunch.sh`: the menu hides in other windows, answering from it works in each style, and typing in the answer and comment boxes triggers nothing.
- [x] Docs (`keyboard-shortcuts.md`, `agents/planning.md`), CHANGELOG, and a rule in `sessions-planning.md`.
