---
type: requirement
status: draft
summary: "From an iPhone on the same network, the person running Gannin can see which Claude Code sessions are waiting on them, answer a question or a permission prompt, send a prompt, stop a session and switch it between Attended and Unattended, without going back to the Mac."
issues: []
plans: [plans/2026-10-13-ios-remote-control.md]
---

# iOS remote control

## Problem

Claude Code sessions run in terminals Gannin holds on the Mac. When one needs a decision (a
permission prompt, an AskUserQuestion) it waits until the person is back at the Mac, and the only
thing that reaches them elsewhere is a macOS notification. Unattended mode and routines reduce how
often that happens but don't remove it. Someone away from their desk for the length of a meeting
leaves agents stalled.

## Users

The one person signed in to Gannin on the Mac, with their own iPhone. No sharing between people.

## High-level requirements

- **HLR1. Pair once, trust explicitly.** The phone is paired with one Mac by a one-time secret shown on the Mac
  (a QR code, or a 26-character code to type), confirmed on both. A paired phone can be listed and revoked in Settings. An unpaired
  device can read and do nothing.
- **HLR2. See what's waiting.** The phone lists the Mac's sessions by state, with the ones that
  need a decision first, and shows what is being asked, with the context claude gave.
- **HLR3. Decide.** The phone can answer a question (its options, an Other answer), and pick a
  permission prompt's own choices including Deny, as the Mac's notification actions do.
- **HLR4. Steer.** The phone can send a prompt to a session, interrupt it, and switch it between
  Attended and Unattended, with the same refusals the Mac has (auto mode unavailable).
- **HLR5. Never act on a stale prompt.** A decision names the prompt it answers. If the prompt has
  gone (answered on the Mac, claude moved on), nothing is sent and the phone says so.
- **HLR6. Stay on the local network.** Traffic goes Mac to phone directly (same Wi-Fi, or a VPN the
  person runs). No Gannin server, account or third party sees it.

## User stories

- As someone away from my desk but on the office Wi-Fi, I open the phone app and see two sessions
  Need you, so that I can unblock them.
- As that person, I tap Allow on a `git push` prompt after reading the command, so that the session
  carries on.
- As that person, I answer a multiple-choice question from claude with the option I'd pick, or type
  my own.
- As that person, I switch a session to Unattended before leaving, and send "run the tests and
  push" to another.
- As that person, I lose my phone and remove it from Settings on the Mac, so that it can't reach
  my sessions again.

## Acceptance criteria

- [ ] A phone that has never been paired is refused on every request except the pairing handshake.
- [ ] Pairing needs the secret shown on the Mac, used within two minutes and confirmed on the Mac;
      a wrong secret spends it, so a second attempt is refused.
- [ ] Revoking a phone on the Mac closes its open connection and is checked on every request.
- [ ] The sessions list shows state, kind, reference and title, and updates within about two
      seconds of the Mac's own view while connected.
- [ ] Answering or approving from the phone has the same effect as the Mac's notification action
      for the same choice, and a decision for a prompt that has since gone is rejected with the
      reason, nothing sent to the terminal.
- [ ] Prompt, interrupt and mode changes use the Mac's existing paths (`submit`, `interrupt`,
      `switchMode`) and report their refusal.
- [ ] The phone sends intents (an answer, a choice number, Deny), never raw terminal keys.
- [ ] Nothing leaves the local network: no Gannin-operated server, no analytics.
- [ ] Docs: gannin.ai/docs gains a Remote control page and a Settings › Remote entry, and
      `check-settings.mjs` passes.

## Out of scope for v1

- Push notifications and a phone that is reachable when the app is closed (needs APNs and a relay,
  see the plan's Later).
- Reaching the Mac away from the local network or a VPN.
- Approving PRs and posting reviews, approving plans, starting sessions or routines, reading
  diffs or terminals.
- Android, iPad-specific layouts, a watch app.
