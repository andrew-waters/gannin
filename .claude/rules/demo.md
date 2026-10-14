---
paths:
  - "Gannin/Demo/**"
  - "GanninDemoTests/**"
  - "scripts/capture-screenshots.sh"
---

# Demo build and screenshots

- Never reference `Gannin/Demo/` types outside `#if DEMO`: the shipped target excludes the folder.
- Keep demo-only seams in the shipped code behind `#if DEMO` or `NetworkGate.isSealed`, never a
  runtime flag a user could set: the demo mode isn't something the app offers.
- A new way to start a process (claude, git, gh, a shell) checks `NetworkGate` first, as
  `ClaudeRunner` and `Shell.run` do: a click in the demo would otherwise run claude as the user.
- Every name in the fixture must be in `DemoFixture.people`, `org` or `repos`, and avatars drawn
  locally (`DemoAvatars`): screenshots are public, and a real login or avatar would put a real
  person on them.
- Never flip the Mac's appearance to pose a shot; set the app's (`AppAppearance.apply`), so a
  failed run leaves nothing to restore.
- Pose through the app's own navigation (`NavigationRequest`, `SessionStore.reveal`), not
  accessibility identifiers or clicks, so a shot survives layout changes.

## Testing
- `GanninDemoTests` (the `Gannin Demo` scheme) covers the seal, the fixture's names and the seeded
  stores. Look at the captured shots by hand after changing a pose or the fixture.
