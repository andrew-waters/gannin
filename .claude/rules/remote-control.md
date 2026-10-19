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
- Build every connection's TLS from `PinnedTLS.parameters`. Never run system trust evaluation in its place: the certificates are self-signed, so it would fail, and loosening it to pass would trust any certificate. The verify block decides on the key's fingerprint alone, and TLS 1.3 is the minimum because its CertificateVerify is what proves the peer holds that key.
- Read the peer's key for a connection with `PinnedTLS.peerFingerprint(of:)`, from that connection's TLS metadata. Never keep it from the verify block in a shared variable: the block isn't told which connection it runs for.
- An unpaired key reaches `PairingConnection` and nothing else, and only while a pairing code is on offer. Never route it into `RemoteConnection`, and never let a message state a fingerprint: each side's proof covers the fingerprint it saw in TLS, which is what defeats a relay.
- The Mac's "Pair <phone>?" confirmation has Don't Pair as its default. `PairingConnection` saves the phone before telling it pairing succeeded, so a phone that believes it is paired always is.
- Never look up this device's identity with a `kSecClassIdentity` query by label: macOS ignores the label and returns the first identity in the keychain. `DeviceIdentity` builds it from the certificate, and the certificate's common name is the label, because macOS files certificates under their common name and ignores `kSecAttrLabel`. Keychain writes in `DeviceIdentity` take a lock: the file-based keychain fails when keys are made concurrently.
- Changing a device's key unpairs every device paired to it. Never regenerate it to fix a connection problem.
- Pair with the 128-bit `PairingSecret` (QR or the 26-character code), never a short code: a device relaying the exchange can guess a short code's proof offline and pair itself. `PairingWindow` spends it on one attempt in two minutes. It is spent when the phone's proof is checked, never by a request alone: spending it on connect would let any device on the network use the code up without guessing it.
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
