# iOS remote control: what to test

Everything on this branch except the Swift-free parts (the docs build and its settings check) was
written without a Swift toolchain, so **none of it has been compiled or run**. This is the list of
what to check, in the order that finds problems fastest. It is the checklist for plan task T10
(`plans/2026-10-13-ios-remote-control.md`).

Mark each box as it passes. Anything that fails goes back to the branch as a fix, not a note.

## 0. What is and isn't built

Built: the wire package, the Mac host and connection logic, the intent handler, the session mirror,
paired phones, Settings › Remote, the iPhone app, pinned mutual TLS (`PinnedTLS`, `DeviceIdentity`),
the pairing exchange (`PairingResponder`, `PairingInitiator`, `PairingClient`, `PairingConnection`),
the Mac's "Pair <phone>?" confirmation (`PairingConfirmation`), docs, CI steps.

Checked on macOS by `swift test --package-path Packages/GanninRemote`, which makes identities in the
login keychain and runs real TLS handshakes and pairing exchanges over localhost, and by the Mac
tests (the Mac's pairing connection). **Not checked on a device:** anything iOS-specific (the iOS
keychain path in `DeviceIdentity`, the phone's accessibility class, Local Network), and all of
sections 6 and 7.

Not built: Add by address, a test for `RemoteSessionMirror`, and a unit-test target for `GanninPhone`.

## 1. Order of work after pulling

1. `git checkout claude/gannin-ios-remote-control-62bu3u && git pull`
2. `swift test --package-path Packages/GanninRemote` (section 2). This is the fastest compile.
3. `xcodegen generate`, then build the Mac app (section 3).
4. Build the iPhone app for the simulator (section 4).
5. `xcodebuild test -project Gannin.xcodeproj -scheme Gannin -destination 'platform=macOS' -skipPackagePluginValidation` (section 5).
6. Docs (section 8).
7. Sections 6 to 9 once TLS exists.

CI (`ci.yml`) now runs steps 2 to 5 and the docs job, so a green run covers them. Read the failures
anyway: the likely trouble is below.

## 2. Package: `Packages/GanninRemote`

- [ ] `swift test` compiles under Swift 6 language mode with no warnings treated as errors.
- [ ] All tests pass. They cover:
  - framing: round trip of every `ClientMessage` and `ServerMessage`, byte-at-a-time reads, two frames
    in one read, a hostile 4 GB length refused without buffering, an over-256 KB message refused on
    encode, a `v: 99` frame reported as `unsupportedVersion`, an unknown message at `v: 1` as
    `malformed`, garbage as `malformed`
  - intents: `invalidReason` for empty or oversize prompts, empty answers, choice below 1, mode `other`;
    `answersPrompt` true only for answer, choose, deny
  - command truncation at a character boundary (2-byte characters, so an odd cut would split one)
  - diff: changed, new and removed sessions; no change gives none
  - rate limiter: 2 in 10 seconds, and the window sliding
  - pairing: secret length and randomness, 200 code round trips, all-0xFF and all-zero secrets, typed
    codes in lower case with spaces, wrong length, characters outside the alphabet (`1`, `0`, `I`, `O`),
    non-zero padding bits; window works once, not after expiry, a second `consume` is nil
  - proofs (Apple only): verifies for the same fields; fails for another secret, role, Mac key, phone
    key, nonce or an empty proof; moving bytes between fields changes the proof
  - invite: hex, URL round trip including a name with an apostrophe and spaces, foreign scheme, wrong
    host, missing fields
  - phone state: snapshot, change, removal, ordering, lock grace period, every refusal explained
- [ ] Check that **Linux** isn't needed: only the proof tests are under `#if canImport(CryptoKit)`.
  Everything else should also pass with `swift test` on Linux if you try it.
- [ ] Look at the encoded JSON of one message by hand (`String(decoding: payload, as: UTF8.self)`).
  Enums with labelled cases encode as `{"choose":{"number":2}}`; a case with no values as
  `{"deny":{}}`. If a future change breaks that shape, an old phone breaks: bump `RemoteProtocol.version`.

## 3. Mac app compiles

Most likely compile problems, in order of suspicion:

- [ ] `Gannin/Remote/RemoteControl.swift`: `SessionStore` conforming to `RemoteSessionControl`. The
  protocol is `@MainActor`; the store's methods used (`answer`, `approvePermission`, `interrupt`,
  `submit`, `switchMode`, `sendKeys`, `confirmApproval`, `permissionChoices`, `autoUnavailable`,
  `isClaudeRunning`) must all be reachable from an extension in another file (none is `private`).
- [ ] `Gannin/Remote/RemoteSessionMirror.swift`: `TabKind` was made internal in `SessionViews.swift`
  (it was `private`). Check nothing else named `TabKind` exists. `CodeSession.shortReference` is used
  as a fallback reference.
- [ ] `RemoteHost.swift`: `Host.current().localizedName`, `NWListener.Service`,
  `withObservationTracking`'s `onChange` being `@Sendable`, and `Task { [self] in ... }` bodies.
- [ ] `NetworkLink.swift`: `NWConnection` crossing into `Task { @MainActor in }` under Swift 6's
  Sendable checking. If it complains, wrap the connection in an `@unchecked Sendable` box.
- [ ] `RemoteSettingsView.swift`: `PairingInvite` made `@retroactive Identifiable`;
  `.confirmationDialog(_:isPresented:presenting:)`; `NSCIImageRep` for the QR code.
- [ ] `RemoteSecurity.swift`: the `nonisolated protocol` and `nonisolated struct` under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- [ ] `GanninApp.swift`: `RemoteHost(store:)` created in `init`; `.environment(remote)` on the Settings
  scene only.
- [ ] `project.yml`: the `GanninRemote` local package is a dependency of both `Gannin` and
  `GanninTests`. `xcodegen generate` should show no errors.
- [ ] Settings › Remote appears as a pane with the iPhone icon and its switch off.
- [ ] Gannin launches and nothing listens: `lsof -iTCP -sTCP:LISTEN -n -P | grep -i gannin` shows no
  new listener, and no `_gannin._tcp` service in `dns-sd -B _gannin._tcp`. No key has been made yet:
  `security find-certificate -c dev.andon.gannin.remote` finds nothing until the switch is first turned on.

## 4. iPhone app compiles

The target builds in Swift 6 language mode with main-actor default isolation, like the Mac app, so
concurrency errors will show on the first compile.

- [ ] `xcodebuild build -scheme GanninPhone -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` succeeds.
- [ ] Watch for: `@Observable` classes marked `@MainActor`; `NWBrowser.Result` handling in
  `MacBrowser`; `withCheckedContinuation` bodies touching `closeSignal`; the QR scanner's
  `nonisolated` AVFoundation delegate method using `MainActor.assumeIsolated` and its `CaptureBox`;
  the `nonisolated` seam protocols and `PhoneServices` used as an `EnvironmentKey` default; `ContentUnavailableView` inside a `List`.
- [ ] The merged Info.plist (look inside the built app) has `NSBonjourServices` = `_gannin._tcp`,
  `NSLocalNetworkUsageDescription`, `NSCameraUsageDescription`, `NSFaceIDUsageDescription`.
- [ ] No app icon is set (there is no asset catalog for the phone yet). Decide whether that blocks.
- [ ] Run it in the simulator. Expect: the lock screen, Face ID prompt (Features › Face ID in the
  simulator), then "No Macs paired". Add a Mac shows the scanner (no camera in the simulator: it
  stays blank), the Mac picker (empty) and typed code field. Pair stays disabled until a Mac is
  chosen and the code is valid.

## 5. Mac unit tests

- [ ] `RemoteIntentHandlerTests` (11 tests): a choice names its prompt and is sent; a stale or missing
  prompt id sends nothing (`promptGone`); a choice not on the screen, or with no choices drawn, is
  `invalid`; deny only on a permission prompt; answers must match the asked questions in order, be
  non-empty and fit 8 KB; unknown or stopped sessions; prompt and interrupt pass through and a failed
  submit is `notRunning`; invalid intents never reach the store; mode switches map to auto and default;
  refused under a prompt, when auto is unavailable, and when it doesn't land.
- [ ] `RemoteConnectionTests` (13 tests): hello on start; snapshot on subscribe; only changes after the
  snapshot and nothing before subscribing; an intent answered with its `result`; a refusal reported;
  rate limiting refuses without reaching the store; a revoked phone is disconnected on its next
  message; garbage and a hostile length close the connection; frames split across reads; `hello`
  records last seen; nothing is sent after close; closing reports once.
  - These use `await Task.yield()` fifty times to let the intent's task finish. If one is flaky, wait
    on the link receiving a frame instead.
- [ ] `PairedPhonesTests` (4 tests): found by key and persisted across a new instance; the same key
  renames; revoke removes, persists and calls `onRevoke` once; seen times only for known phones.
- [ ] The existing suites still pass (the project, `SessionViews.swift` and `GanninApp.swift` changed).

## 6. Needs a real transport (blocked on TLS)

Suggested way to unblock these before TLS is finished: a `#if DEBUG` pair of implementations of
`RemoteTransportSecurity` and `ClientTransportSecurity` using plain TCP and a fixed fingerprint, plus a
`PairingHandshake` that just adds the Mac. It must never be compiled into a release build. It lets all
of sections 6 and 7 run on a simulator and a Mac on the same network.

Connection:
- [ ] Turning the switch on starts listening and advertising; the status reads "On as <name>. 0 connected.".
- [ ] `dns-sd -B _gannin._tcp` shows the Mac; changing Name on the network re-advertises under the new name.
- [ ] The phone lists the Mac "On this network"; stopping the host makes it "Not on this network".
- [ ] Opening the Mac in the phone shows Connecting then its sessions, "Needs you" first, within a second or two.
- [ ] A session going to Needs you on the Mac shows on the phone within about a second and the phone
  gives a warning haptic if the app is open.
- [ ] Turning the switch off disconnects the phone (it shows "Disconnected from <Mac>") and removes the service.
- [ ] A ninth simultaneous connection is refused (maximum is 8).
- [ ] The phone shows Offline when the Mac sleeps, and reconnects after it wakes without a restart.
  Check the backoff (1, 2, 4 ... 30 seconds) and that it resets after a good connection.
- [ ] Switching Wi-Fi to cellular and back: offline, then reconnected.
- [ ] No heartbeat for 40 seconds (pause the Mac process with `kill -STOP`) marks the phone offline.

Decisions (this is the point of the feature):
- [ ] **Permission prompt**: the tool and full command show; Allow works (the Mac's session carries on
  and its card disappears); "Yes, and don't ask again" works; Deny works. Compare each against the Mac's
  notification buttons for the same prompt.
- [ ] A command over 4 KB shows the "longer than this" warning and is cut at a character boundary.
- [ ] **Question**: single select, multi select (answers joined with ", "), Other typed text, several
  questions in one prompt, a question with a "(Recommended)" label (the suffix is stripped). The Mac
  session receives the same message the Mac's own answer sends ("My answer to ...").
- [ ] **Stale prompt**: answer on the Mac while the phone still shows it, then tap on the phone: the
  phone says it was already answered and nothing is typed into the terminal. Repeat by tapping on the
  phone first and then the Mac.
- [ ] A stale prompt id when a new prompt has arrived with the same tool: the old tap is refused.
- [ ] A permission prompt with no tool in the transcript (a dialog): it shows "Permission", its id is
  `needs-you-<time>`, and a choice is refused if it isn't on the screen. Find which real prompts
  produce this and whether the id is stable enough.
- [ ] "Waiting for the prompt" shows while the terminal's choices haven't drawn, then the choices appear.
- [ ] Send a message: it lands in the session as a prompt; an empty one is refused; 8 KB+ is refused.
- [ ] Interrupt asks to confirm, then Esc reaches claude.
- [ ] Mode: Unattended then Attended on a session that supports auto mode; refused with a message
  under a pending prompt; refused when `autoUnavailableBoxes` has the session's box; a switch that
  doesn't land reports "didn't change mode" and the Mac's own `modeNotes` explain why.
- [ ] 21 intents in 10 seconds: the 21st is refused as rate limited.
- [ ] Two phones at once both stay up to date; a decision from one removes the prompt on the other.

Kinds of session (each should show the right kind and reference, and be controllable):
- [ ] Work on This (Code), Quick Change with and without an issue, Plan, Review, Ask, a helper (shows
  its role), a routine run (Report, Maintenance, Scheduled), a sandboxed session, a session on a
  server (`connect` set).
- [ ] 60 or more sessions: only 60 are sent, waiting ones first; check the snapshot stays under 256 KB
  with real titles, questions and commands. If a snapshot is refused for size nothing is sent and the
  phone shows no sessions, which would be a silent failure: confirm what happens.

Pairing (after the real handshake exists):
- [ ] The QR code scans; the typed code works (lower case, spaces); a wrong code spends the window; a
  code used twice or after two minutes is refused.
- [ ] A second phone can pair; the same phone pairing again renames rather than duplicates.
- [ ] Revoke disconnects an open connection immediately and the phone can't reconnect.
- [ ] Revoking while the phone is in the middle of an intent: the result is dropped or refused, never half-applied.
- [ ] A phone paired to two Macs can switch between them; one offline doesn't affect the other.

## 7. Security

- [ ] An unpaired device (not pinned) can't read a session list or send an intent. Try `nc`/a script
  speaking the protocol without TLS and with a TLS client with an unknown key.
- [ ] A relayed pairing attempt (a device between phone and Mac) can't complete without the secret.
- [ ] The pairing secret is never logged, never stored on the Mac after use and never in the QR URL
  history (`gannin-remote://pair?c=...` is only ever shown, not opened).
- [ ] `PairedPhones` in `UserDefaults` (`remote.pairedPhones`) holds only fingerprints, names and dates.
- [ ] The Mac logs what a phone did without the text of prompts or commands (the plan says session,
  kind and phone name; this isn't implemented yet: decide and add).
- [ ] Face ID: asked at launch; not asked again within a minute of leaving; asked after a minute away;
  on a phone with no passcode the app stays locked with the message; cancelling Face ID leaves it locked.
- [ ] Task-switcher snapshot: the session list is visible in the app switcher thumbnail. Decide whether to blur it.
- [ ] `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for the phone's key (part of the TLS work).
- [ ] Anything that can change `remote.enabled`, the name or the phones list without the user is a
  local process already able to do worse; confirm nothing reads them from an untrusted place.

### Pinning fingerprint (check as the TLS work lands)

A reviewer researched this (see the plan's pinning decision) and ran `openssl` on a P-256 key. What
follows is what's still to be proved in this code, on a device.

- [x] The key read in the verify block via `SecTrustCopyKey(sec_trust_copy_ref(...))` exports as 65
  bytes starting `04`. A key that doesn't is refused. (macOS loopback tests.)
- [x] (Checked on macOS CryptoKit only: the SHA-256 of `derRepresentation` equalled openssl's SPKI hash for the
  same key. The iOS build is unchecked.) `P256.Signing.PublicKey(x963Representation:).derRepresentation` is 91 bytes starting
  `3059301306072a8648ce3d020106082a8648ce3d030107034200`, **on Apple's CryptoKit** (the reviewer
  confirmed it in swift-crypto's source, not in CryptoKit's, which is closed).
- [ ] SHA-256 of it equals `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256`
  for the certificate the device presents (`openssl s_client` against the live listener).
- [ ] A certificate regenerated over the same key gives the same fingerprint; a new key a different one.
- [ ] A software key and a Secure Enclave key both give a fingerprint (an SE public key is a
  `P256.Signing.PublicKey`).
- [ ] The verify block is idempotent: run twice on one connection it gives the same answer, and its
  completion is called exactly once each time, on every path, including a missing key.
- [x] A wrong key is refused and the right one accepted, on both sides, on TLS 1.3. No system trust
  evaluation runs. (macOS loopback tests, with self-signed certificates that system trust would reject.)
- [x] The Mac asks for a client certificate (`sec_protocol_options_set_peer_authentication_required(true)`);
  without it, an unpaired phone is never asked for one. Both sides set a local identity. (In the loopback
  test the Mac reads the phone's key from the connection's TLS metadata.)
- [ ] A peer that presents the right certificate but doesn't hold its private key fails the handshake
  (the reviewer couldn't confirm from Apple's source that this precedes the verify block): try a
  replayed certificate with another key.
- [x] swift-certificates isn't used: `SelfSignedCertificate` writes the DER itself and the fingerprint is the
  SPKI hash.
- [x] `sec_protocol_metadata_copy_peer_public_key` and `SecTrustCopyCertificateChain` aren't used. The verify
  block reads the key with `SecTrustCopyKey`; `PinnedTLS.peerFingerprint(of:)` reads the peer certificate from
  the connection's metadata after the handshake.
- [ ] A paired Mac whose key has changed (delete its `dev.andon.gannin.remote` key and certificate from the
  Mac's keychain, then turn Remote off and on): the phone shows "This isn't the Mac you paired with. Pair
  <name> again." and doesn't sit on "Connecting". Network.framework reports the refusal as `.waiting(.tls)`;
  `RemoteClient` handles that case.
- [ ] On iOS, `DeviceIdentity.find` finds this app's own identity. The macOS path builds it from the certificate
  (`SecIdentityCreateWithCertificate`), because a macOS `kSecClassIdentity` query ignores the label and returns
  the first identity in the keychain. The iOS path queries by label and is unverified: check it returns ours,
  and that a second launch loads the same fingerprint instead of making a new key.

## 8. Docs

- [ ] `cd docs-site && node scripts/check-settings.mjs` prints "Every Settings control is in the Settings
  reference." (it did when written; re-run after any label change).
- [ ] `cd docs-site && npm ci && npm run build` succeeds with the new `remote/iphone.md`,
  `settings/app/remote.md`, the sidebar entry in `astro.config.mjs` and the Storage order change.
- [ ] Read the pages as they render: the Remote control group appears between Ways to run sessions and
  Settings reference; Settings › Remote sits before Storage; the links work.
- [ ] The pairing steps in `remote/iphone.md` include the Mac asking you to confirm the phone. Check the
  wording matches `PairingConfirmation`.
- [ ] `CHANGELOG.md` has the Added entry under Unreleased. Move it only when the feature really ships.

## 9. Known gaps and judgement calls to review

- No push: a backgrounded phone is suspended within about 30 seconds. The docs say so. Is a local
  notification from the foreground worth adding (it can't wake the app)?
- Face ID is first-open only, as decided. Revisit if a phone left open and unlocked worries you.
- Unattended can be switched from the phone, as decided. It shows no extra confirmation.
- Phone name from `UIDevice.current.name` is generic ("iPhone") on iOS 16 and later without an
  entitlement, so a list of phones may all read the same. The name shown in Settings › Remote comes
  from pairing, not from this, but check what it ends up as.
- `RemoteSessionMirror` re-reads every session on each change (at most every 300 ms). With many
  sessions and a busy transcript that could be heavy: profile with 20 working sessions.
- `modes[id]` is read for the mode rather than the terminal's footer, so a mode changed by Shift+Tab on the
  Mac shows on the phone after the Mac's next poll (about a second).
- The service name is the Mac's name, which Bonjour suffixes (`Studio (2)`) on a clash. The phone finds a
  Mac by that name, so a rename would lose it until the phone's pairing is updated. Consider matching on fingerprint.
- Add by address (for a VPN where Bonjour doesn't cross) isn't built; the listener's port isn't shown.
- The phone has no asset catalog or app icon, no unit-test target and no TestFlight pipeline.
