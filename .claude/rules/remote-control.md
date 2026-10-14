---
paths:
  - "Gannin/Remote/**"
  - "GanninPhone/**"
  - "Packages/GanninRemote/**"
---
# Remote control (iPhone)

An iPhone app that answers Claude Code sessions on this Mac over the local network (plans/2026-10-13-ios-remote-control.md, requirements/ios-remote-control.md, docs/ios-remote-control-testing.md). `Packages/GanninRemote` is the wire protocol both sides share; `Gannin/Remote/` is the Mac host; `GanninPhone/` is the app.

## Trust
- Never listen without TLS and a pinned key: a paired phone can approve commands that run as the user. `RemoteTransportSecurity` (Mac) and `ClientTransportSecurity` and `PairingHandshake` (phone) are the seams; `UnconfiguredTransportSecurity` makes `RemoteHost` refuse to start. Don't add a listener that works without them.
- Pair with the 128-bit `PairingSecret` (QR or the 26-character code), never a short code: a device relaying the exchange can guess a short code's proof offline and pair itself. `PairingWindow` spends it on one attempt in two minutes.
- Check the phone is still in `PairedPhones` on every message, not only when it connects: revoking must take effect on a connection already open.
- Never log or store the pairing secret, or the text of prompts and commands.

## Intents
- The phone sends intents (`RemoteIntent`), never terminal keys: the store owns how a choice reaches claude, so a change in claude's prompt rendering is fixed in one place.
- `RemoteIntentHandler` is the only way an intent reaches `SessionStore`, through `RemoteSessionControl`, using the methods the notification quick replies use (`answer`, `approvePermission`, `interrupt`, `submit`, `switchMode`). Add no new way of driving a terminal for the phone.
- A decision must name the prompt it answers (`RemotePrompt.id`, the question's or the tool's id). Refuse `promptGone` when it differs: otherwise a tap that arrives after the Mac answered lands on the next prompt.
- A choice must be one `permissionChoices` shows on the terminal's screen. Never offer or send a bare Allow when the choices haven't drawn.
- Refuse a mode switch under a pending prompt, as the Mac does: the keys would go to the prompt.

## Wire
- Changing a message's shape changes what an older phone or Mac can read: bump `RemoteProtocol.version`. The version is checked before the message, so the other side says "update" rather than misparsing.
- A snapshot must fit one frame (256 KB): `RemoteSessionMirror` caps sessions and text. Raise a limit only after checking the frame still fits.
- Keep the package free of app and UIKit/AppKit dependencies: it is built for macOS and iOS and tested with `swift test --package-path Packages/GanninRemote`.

## Phone app
- There is no push: iOS suspends the app soon after it leaves the screen, so "Needs you" shows only while it's open. Don't claim background alerts.
- Built in Swift 6 with main-actor default isolation, as the Mac app. Models and the security seams are `nonisolated` so they cross into `Network` callbacks.
- The app asks for Face ID or the passcode at launch and after a minute away (`AppLockPolicy`), and stays locked on a phone with no passcode.
