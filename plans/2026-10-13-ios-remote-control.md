---
type: plan
status: In review
summary: An iPhone app talks directly to Gannin on the Mac over the local network, paired once with a code and a pinned key, to list sessions, answer questions and permission prompts, send prompts, interrupt, and switch Attended or Unattended, by calling the store's existing methods.
issues: []
domains: [sessions, remote]
touches: [andrew-waters/gannin]
owner: andrew-waters
requirements: [requirements/ios-remote-control.md]
---

# iOS remote control

## Context

Every decision v1 needs already has one entry point in `SessionStore`, because notification
quick replies drive them:

| Phone action | Existing path |
| --- | --- |
| Answer a question | `answer(_:to:)` (closes the dialog, sends one message) |
| Permission prompt choice or Deny | `approvePermission(_:for:)`, `selectChoice`, `sendKeys("\u{1B}")` |
| What to offer | `quickReplies(for:)`, `permissionChoices(for:)`, `transcripts[id].question` |
| Send a prompt | `submit(_:to:)` |
| Stop | `interrupt(_:)` |
| Attended or Unattended | `switchMode(_:to:)`, `leaveUnattended(_:)`, `autoUnavailableBoxes` |
| State | `states[id]`, `SessionState`, `attention` |

The Mac app isn't sandboxed and nothing in it listens on a network, so a listener is new but
needs no entitlement beyond the local network permission on the phone. Gannin has no server and the
requirement keeps it that way.

## Decisions

- **Transport: direct, local network only.** The Mac advertises over Bonjour (`_gannin._tcp`) and
  listens with `Network.framework` (`NWListener`) on a TLS port. The phone browses with
  `NWBrowser`. No relay, no APNs. An away-from-home path (Tailscale or another VPN) works with no
  code, since the phone then reaches the Mac's address by name; a Bonjour-less "Add by address" is
  offered for it.
- **Trust: pair once, pin keys.** The Mac makes a self-signed identity at first enabling and keeps
  it in the keychain (`dev.andon.gannin.remote`). The phone makes its own. Pairing shows a 128-bit
  one-time secret on the Mac, as a QR code (carrying the Mac's key fingerprint too) and as a typed
  code of 26 characters (`ABCD-EFGH-...`). It is not a short numeric code: a device on the same
  network that relays the exchange could capture a short code's proof and guess it offline in
  moments, then pair itself. Each side then proves it knows the secret with an HMAC over both key
  fingerprints and a nonce from each (`PairingProof`), so a relayed or replayed proof is useless and
  a Mac that isn't the one displaying the code can't answer. Both pin the other's key after that,
  TLS is mutual (the Mac accepts only pinned phone keys, the phone only the pinned Mac key) and the
  secret is never needed again. The secret works for one attempt within two minutes
  (`PairingWindow`), a wrong guess spends it, and the Mac asks "Pair Alex's iPhone?" before saving.
- **Pin the public key, not the certificate.** The fingerprint is the SHA-256 of the device's public
  key (SPKI), so renewing or regenerating a self-signed certificate over the same key doesn't break any
  pairing. A new key does: a Mac with a new key needs every phone to pair again, and a reinstalled phone
  pairs again with each Mac.
  **How the fingerprint is taken** (researched by a second reviewer, which also ran `openssl` on a P-256
  key): in the verify block, read the peer's key with
  `SecTrustCopyKey(sec_trust_copy_ref(trust).takeRetainedValue())`, export it with
  `SecKeyCopyExternalRepresentation` (an X9.63 point: `04 || X || Y`, 65 bytes, not SPKI), build
  `P256.Signing.PublicKey(x963Representation:)`, and hash its `.derRepresentation`. That is a full
  SubjectPublicKeyInfo (always the 26-byte header `3059301306072a8648ce3d020106082a8648ce3d030107034200`
  then the point, 91 bytes), so its SHA-256 equals `openssl x509 -pubkey -noout | openssl pkey -pubin
  -outform der | openssl dgst -sha256` and the usual HPKP-style pin. Compute this device's own
  fingerprint the same way from its key's `publicKey.derRepresentation`, including a Secure Enclave key.
  Never hash `openssl x509 -fingerprint`, which covers the whole certificate and changes when it is
  regenerated.
  - Don't read the key with `sec_protocol_metadata_copy_peer_public_key` (its byte format is undocumented)
    or `SecTrustCopyCertificateChain` (it forces a full trust evaluation).
  - The verify block can run more than once per connection, so make it idempotent and call its
    completion exactly once each time. Never run system trust evaluation: a self-signed leaf fails it.
    Decide on the pin alone, and complete with false on any failure.
  - The Mac must call `sec_protocol_options_set_peer_authentication_required(true)` or it never asks
    for a client certificate (servers default to false), and both sides set
    `sec_protocol_options_set_local_identity`.
  - If swift-certificates is used to make certificates, don't hash `Certificate.PublicKey.subjectPublicKeyInfoBytes`:
    despite the name it is only the key bits, not the SPKI. Serialize the key with `DER.Serializer`.
  - Still unconfirmed from Apple's own source: that CryptoKit's `derRepresentation` is byte-identical to
    swift-crypto's on Apple platforms, that a custom verify block fully replaces system evaluation, and
    that the handshake always proves possession of the key before the block is trusted. Check these in
    the checklist's pinning section.
- **Unpaired connections can only pair.** The Mac accepts any phone key at the TLS layer, then holds an
  unpaired connection in a pairing-only state: the one message it accepts is the pairing proof, it gets
  one attempt, and it closes on a wrong proof or a timeout. Sessions are reachable only once the key is
  in `PairedPhones`.
- **Intents, not keys.** The wire carries `answer(question, option or text)`,
  `choose(number)`, `deny`, `prompt(text)`, `interrupt` and `setMode(attended|unattended)`. The
  Mac maps them onto the store, which owns how a choice reaches claude's terminal, so a change in
  claude's prompt rendering is fixed in one place and the phone never sends escape sequences.
- **Every decision names its prompt.** A pending prompt has an id (the `pendingTool.id` or
  `question.id`). The phone's reply carries it; `RemoteHost` compares it with the session's
  current prompt and refuses with `promptGone` when they differ, covering a prompt answered on the
  Mac meanwhile and the 250 ms optimistic-approval window.
- **State is pushed over the open connection.** The Mac sends a snapshot on connect and then
  small diffs, driven by the store's observable state (not a poll), plus a heartbeat. The phone
  keeps nothing but its list of paired Macs and their keys: no session data persists on it.
- **Shared code is a Swift package.** `GanninRemote` (new, at `Packages/GanninRemote`, local) holds
  the wire types (`Codable`, versioned, length-prefixed JSON frames), pairing, and framing, built
  for macOS and iOS. The Mac host (`Gannin/Remote/`) and the iOS app depend on it. The protocol
  has an explicit version so an old phone and a new Mac say so rather than misparse.
- **iOS app is a second target in `project.yml`**, `GanninPhone` (the shared package's module is already `GanninRemote`; bundle `dev.andon.gannin.remote`, display name Gannin Remote),
  SwiftUI, iOS 26 to match the Mac's floor. Same team, separate scheme, built by `ci.yml`
  (compile only; no TestFlight pipeline in v1).
- **Alerts without push.** A foreground phone shows a banner and haptic on a new Needs you; a
  backgrounded one is suspended by iOS within about thirty seconds and the connection drops. v1
  says so in the app and docs rather than papering over it. This is the product limit of choosing
  local-only and is the first thing Later removes.
- **Off by default.** Settings › Remote (`RemoteSettingsView`): on or off, this Mac's name on the
  network, paired phones with Revoke, and Pair a Phone. Off stops the listener and drops every
  connection.
- **Several Macs.** See the decisions below.
- **Sleeping Mac and Do Not Disturb are the user's.** A sleeping Mac is unreachable. Gannin doesn't
  hold it awake for this.

## Design

**Mac (`Gannin/Remote/`)**

- `RemoteHost`: owns the `NWListener`, mutual-TLS options, the accepted `RemoteConnection`s and the
  pairing state. Started from `GanninApp` beside `EngineerWatch` when the setting is on.
- `RemoteSessionMirror`: turns `SessionStore` into `RemoteSession` values (id, reference, title,
  kind, state, mode, `needsYou` prompt as `RemotePrompt`: `.question(items)` or
  `.permission(tool, command, choices)`, last claude message) and a diff stream. Reads only; the
  one place that knows `SessionStore`'s internals for display.
- `RemoteIntentHandler`: validates the intent against the current prompt id and calls the store
  methods in the table above, returning `ok` or a typed refusal (`promptGone`, `notRunning`,
  `autoUnavailable`, `unknownSession`). Runs on the main actor, as the store does.
- `RemotePairing` and `RemoteKeys`: the code, the exchange and the keychain items, plus the paired
  phones list (`RemotePhone`: id, name, key fingerprint, paired at, last seen), kept in the
  keychain and `UserDefaults`, never in the harness.

**Protocol (`GanninRemote`)**

- Frames: 4-byte length, then JSON `{v, id, type, body}`. Server to phone: `hello`, `snapshot`,
  `sessionChanged`, `sessionRemoved`, `result(id)`. Phone to server: `hello`, `subscribe`,
  `intent(id, session, promptID?, ...)`.
- Limits: frames up to 256 KB, text prompts up to 8 KB, a command's text in a permission prompt
  truncated at 4 KB with a flag so the phone can say it's cut off, and intents rate limited per
  connection.

**iOS (`GanninRemote` target)**

- `PairingView` (scan or type the code, Add by Address), `SessionsView` (Needs you first, then
  Working, Your turn, others; state dot and label from `SessionState.label`), `SessionView`
  (the prompt as large tappable choices; Deny always last and not the default; a prompt box;
  Interrupt behind a confirm; Attended or Unattended with the Mac's refusal text).
- A permission prompt shows the tool and the full command or file the Mac read from its
  transcript, since approving blind from a phone is the failure to avoid. When the Mac can't read
  the choices off the terminal yet, the phone shows "Waiting for the prompt" instead of a bare
  Allow, rather than guessing as the notification's fallback does.
- Local network permission explained before the system asks (`NSLocalNetworkUsageDescription`,
  `NSBonjourServices`), and a plain screen for when it's been refused.

## Security

- The listener is off by default and, when on, answers only mutual-TLS clients with a pinned key.
  An unpaired client can only run the pairing handshake, which is rate limited and closed after one
  failure.
- Approving a permission prompt runs commands as the user, so this is remote code execution for
  anyone holding a paired phone. Treat a paired phone as a logged-in Mac: Revoke is immediate, the
  phone's key lives in its keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and the
  app requires Face ID or the passcode (`LocalAuthentication`) before it sends any intent, with a
  short grace period.
- Nothing about a session leaves the phone's memory, and the Mac logs intents (session, kind,
  phone name) to its own log and the session's activity, never prompts' text.
- Open threats to review before shipping: a hostile device on the same Wi-Fi attempting to pair
  during the pairing window (mitigated by the 128-bit secret, the single attempt and the confirmation on the Mac),
  and a phone left unlocked (mitigated by the Face ID gate and Revoke).

## Tasks

- [ ] T1. Create the issue in the project and link it here and in the requirement. Satisfies: all.
- [x] T2. `Packages/GanninRemote`: wire types, framing, version negotiation, unit tests for
      encode/decode, oversize frames and unknown versions. Satisfies: HLR5, HLR6.
- [ ] T3. Pairing and keys: secret, proofs and window (done, in the package, with tests). Left:
      keychain identities, pinned mutual TLS (the `RemoteTransportSecurity` and
      `ClientTransportSecurity` seams), the pairing handshake (`PairingHandshake`), the Mac's
      "Pair Alex's iPhone?" confirmation, tests with an in-process loopback for
      success, wrong code, expired code, second attempt, revoked phone.
      Satisfies: HLR1.
- [x] T4. `RemoteSessionMirror` and the diff stream over `SessionStore` (written; the diff and
      connection are tested, the mirror itself has no test yet: it needs a real `SessionStore`
      with fixtures for each `SessionState`). Satisfies: HLR2.
- [x] T5. `RemoteIntentHandler`: answer, choose, deny, prompt, interrupt, setMode, with
      `promptGone` and the typed refusals; tests with a fake store boundary. Satisfies: HLR3,
      HLR4, HLR5.
- [x] T6. `RemoteHost` and Bonjour advertising, started from `GanninApp`; Settings › Remote with
      Pair a Phone and Revoke; `check-settings.mjs` pane map. Satisfies: HLR1, HLR6.
- [x] T7. iOS target in `project.yml`, `ci.yml` build step, pairing, a list of paired Macs with a
      switcher, and the sessions screens. Satisfies:
      HLR1, HLR2.
- [x] T8. Session screen: question and permission cards, prompt box, interrupt, mode, Face ID gate,
      reconnection. Satisfies: HLR3, HLR4.
- [x] T9. Docs page `remote/iphone.md`, Settings reference entry, CHANGELOG line, the app's
      background limitation stated. Satisfies: docs criterion.
- [ ] T10. Manual pass (`docs/ios-remote-control-testing.md` is its checklist), on a real phone and Mac: pair, approve, deny, answer, stale prompt, revoke,
      Mac sleep, Wi-Fi change.

## Verification

- Package and Mac tests run with `xcodebuild test` as `ci.yml` does; the iOS target builds in CI.
- The end-to-end pass (T10) is manual because it needs Bonjour, the local network permission and a
  device; the plan's acceptance criteria are its checklist.

## Risks

- **Prompt reading is the weak link.** `permissionChoices` reads the terminal screen. If claude's
  wording changes, the phone shows "Waiting for the prompt" and the Mac's own card has the same
  problem, so it fails visibly together instead of sending a wrong key.
- **Local Network permission on iOS** is a common support issue (refused once, never asked again);
  the app detects it and links to Settings.
- **No push** will feel like a missing feature on day one; the docs and the app say it's local
  only, and Later lifts it.
- **Protocol drift** between a Mac and a stale phone build is handled by the version field and the
  app saying which side to update.

## Not built yet

- TLS, key pinning and the pairing handshake (T3), so the host refuses to start and the phone can't
  pair. Everything else is written against their seams.
- **Add by address** for a Mac Bonjour can't see (a VPN). The listener's port is dynamic and isn't
  shown anywhere, so it needs the port in Settings › Remote and a host and port form on the phone.
- A test for `RemoteSessionMirror`, and a unit-test target for `GanninPhone`.

## Later

- Relay plus APNs for Needs you alerts and reach from anywhere, with end-to-end encrypted payloads
  (the relay sees only that a session needs attention). The `GanninRemote` frames stay the same;
  only the carrier changes.
- Approve PRs and plans from the phone (`ApprovalQueue`, `postReview`, the plan buttons), start
  Work on This and Run Now, read the activity summary, Live Activities.

## Decisions on the open questions

1. **Face ID on first open only.** The app asks for Face ID or the passcode when it opens, then
   not again until it has been in the background past a short grace period. Individual intents
   aren't gated.
2. **Unattended can be switched from the phone**, with the same refusals as on the Mac
   (`autoUnavailable`). It is the switch someone leaving their desk wants.
3. **The phone keeps a list of Macs.** Each is its own pairing (name, pinned key, last address),
   found over Bonjour or added by address; the phone shows one Mac's sessions at a time with a
   switcher, and a Mac that's unreachable shows as offline rather than disappearing. The Mac side
   already supports many phones, so only the iOS app and T3's storage change.
