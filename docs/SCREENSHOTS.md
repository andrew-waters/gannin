# Screenshots

The screenshots on gannin.ai, in the docs and in the README come from **Gannin Demo**, a build of
the app on invented data: one org (Lumen Harbor), its people, repos, PRs, issues, delivery history
and three Claude Code sessions, all made up in `Gannin/Demo/`. One script refreshes them all.

## Taking them

```bash
scripts/capture-screenshots.sh              # build Gannin Demo, then capture every shot
scripts/capture-screenshots.sh --no-build   # capture with the last build
scripts/capture-screenshots.sh workload     # only the shots named
```

Each shot is saved dark then light, as `site/assets/screens/<shot>-dark.png` and
`site/assets/screens/<shot>-light.png`. Commit them with the change that called for them: the
landing page and the docs deploy from `site/`, and the README reads them from the repo.

It's safe to run with Gannin open. The demo build has its own bundle ID
(`dev.andon.gannin.demo`), so it runs beside your Gannin and doesn't quit it or its sessions.
It makes no network requests, never reads the keychain, and keeps its files in its own folder in
Application Support (emptied each launch), so nothing of yours is shown or changed. It changes only
its own appearance, never your Mac's, and the script quits it however the run ends.

### One-time permission

`screencapture` needs **Screen Recording** for the app the script runs in (Terminal, iTerm,
Ghostty, or Gannin itself when a session runs it): System Settings › Privacy & Security › Screen
Recording. Without it the shots come out as the desktop with no window. Nothing else is needed:
the app poses itself, so there's no Accessibility or Automation permission to give.

Leave the Mac alone while it runs. Each shot is taken with the demo app in front, so its window
draws as the one in use rather than greyed; if another app keeps the focus, the run stops with an
error instead of saving a grey shot.

## Adding a screen

1. Add a case to `DemoShot` (`Gannin/Demo/DemoShot.swift`). Its raw value is the file name, `pose`
   says where it is (a sidebar item in a main window, with a drawer over it if any, or a session's
   tab) and `size` is the window's.
2. If the screen would be empty, give it data in `DemoFixture.swift` (or `DemoSessions.swift`).
   Use only names from the fixture's lists: `DemoFixtureTests` fails on any other login or repo.
3. Run `scripts/capture-screenshots.sh <shot>` and look at both files.
4. Use it: a `<picture>` in `site/index.html` or the README, or a `<figure class="screenshot">` in
   a docs page (see `docs-site/src/content/docs/guides/dashboard.md`).

The script reads the shot list from the app, so it doesn't change.

## How it works

- **The target.** `Gannin Demo` in `project.yml` compiles the app plus `Gannin/Demo/` with the
  `DEMO` condition; the shipped `Gannin` target excludes that folder, and the release workflow
  never builds the demo. CI builds it and runs `GanninDemoTests`.
- **The seal.** `NetworkGate` throws before any request in the demo build, `Keychain` reads and
  writes nothing, `AuthStore` is signed in as the fixture's viewer with no API (so fetches stop
  quietly), and `AppPaths.support` is the demo's own folder. Background work (Sparkle, review
  requests, PR watching, routines) doesn't start.
- **The data.** `DemoLaunch` empties the folder and preferences, then writes the fixture through
  the stores' own caches, so they load it as a previous launch's. Sessions are shown with a
  terminal fed their screen and no process (`SessionTerminal.replay`), and their Changes pane
  parses fixture git output.
- **Posing.** Launched with `--capture <folder>`, `DemoDirector` lists the shots in that folder,
  then poses each `<shot> <dark|light>` the script writes to `request`, in a fresh window, and
  writes the settled window's number to `posed` for `screencapture -l`.
