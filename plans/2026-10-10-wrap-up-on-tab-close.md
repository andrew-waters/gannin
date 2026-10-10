---
type: plan
status: In review
summary: Closing the tab of a running issue session in the Claude Code window asks first whether to wrap it up, showing its PRs, what isn't pushed and its plans and requirements to tick off, then leaves it running, ends it or finishes it.
issues: [andrew-waters/gannin#146]
domains: [sessions]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Wrap up a session when its tab closes

## Context

Closing a tab in the Claude Code window only took it out of the tab bar (`SessionStore.closeTab`):
claude kept running in its terminal, which the store holds, and the worktrees, branch and harness
record were left as they were; + opened it again. Nothing prompted the user to end the session or
bring its plans and requirements up to date, so items met during it stayed unticked. Finish Session
(worktrees removed, `session.json` marked finished) is only offered once every PR is merged or the
session has gone stale.

## Decisions

- **Which tabs ask:** an issue's own session or a quick change's (`canPairReview`: not a helper,
  review, plan or Ask; drafts aren't sessions), while claude or one of its helpers runs, with the
  setting on. Anything else closes as before. The tab's ✕, its context menu's Close Tab and ⌘W ask;
  Close Other Tabs doesn't, as asking about each in turn would wear. ⌘W closes the window only once
  the last tab has gone.
- **Finalising** is the existing Finish Session, offered only when it is today (every PR merged),
  with its confirmation, since removing worktrees can lose unpushed work. Opening a PR is left to
  claude in the session.
- **Ticking items:** by hand, with Ask Claude to Tick Them Off pasting a prompt for claude to tick
  what its work met and commit it. Gannin doesn't guess.
- **Saving ticks:** one harness commit through `HarnessStore.commit`, applied to each file at the
  head and matched by the item's words (and which of the same words it is), so lines moved since
  don't matter. The button naming the harness is the confirmation, as in the other harness editors.
- **Quitting** already asks (`QuitGuard`), and closing the window leaves sessions running, so
  neither changes.
- **A setting**, Settings > General > Agent, Ask to wrap up when closing a session's tab
  (`sessionsWrapUpOnClose`, on), also turned off from the sheet's Don't ask again.

## Tasks

- [x] `SessionStore.requestClose`, `wrappingUp`, `asksToWrapUp` and `endAndClose`
- [x] `HarnessChecklist`: read a document's items and tick them by their words
- [x] `WrapUpSessionSheet`: session state, PRs, unpushed worktrees, plans and requirements with
      ticks, commit, Ask Claude, Leave Running, End Session, Finish Session, Cancel
- [x] The tab's ✕, Close Tab and ⌘W go through `requestClose`; the window shows the sheet
- [x] The setting in Settings > General > Agent
- [x] Tests (`WrapUpTests`) and CLAUDE.md
