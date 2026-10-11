---
paths:
  - "Gannin/App/**"
  - "Gannin/Views/**"
  - "Gannin/Workload/**"
---

# App shell and workload

## Windows and navigation
- Keep per-window state (org, project `workspace`, section, metrics window) in `@SceneStorage`; only shared preferences use `@AppStorage`. Each window is independent.
- Never rename a `WorkloadTab` raw value; windows saved with the old one must still decode. Change `title` instead.
- Push pages through the `selection` binding or the `navigate` action, not by mutating the path directly. Issues, PRs and harness documents go to drawers, not the path.
- Open in New Window hands state over via `WindowRequest.pending`; anything a new window must restore has to be carried there.
- Use `Platform.swift` styles; AppKit directly, no `#if os`.

## Personal accounts
- Personal logins differ from orgs in GitHub queries: use `GitHubAccounts` (`scope`, `ownerField`) rather than hard-coding `org:` or `organization(login:)`.

## Workload
- GitHub search is capped at 1000 results, so refreshes are incremental (`GitHubAPI.SnapshotPlan`); a full search is the fallback. Never assume a snapshot is complete.
- Hidden items and, with Exclude drafts, drafts are dropped in `Workload` before anything is derived, so every count follows. Do the same in new derivations.
- An assigned issue nobody has started is backlog, not load; an issue closed by the person's own PR counts once.
- Hidden keys are PR/issue node IDs; old `person:<login>` keys must keep working as org exclusions.

## Drawers
- Drawers beneath the top one must stay disabled so their shortcuts don't fire.

## Testing
- No tests cover navigation or the workload; check by hand with `scripts/relaunch.sh`, then open items in a drawer, a new tab and a new window.
