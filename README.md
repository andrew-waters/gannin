# Gannin

A macOS app for managing workload across your GitHub orgs. Sign in with GitHub, star the orgs
you look after, and see who is working on what: open PRs, review requests, assigned issues and
recently merged work, with PRs linked to the tickets they close.

## Running

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Gannin.xcodeproj
```

## Claude

Gannin's Claude features (Claude Code sessions, PR reviews, Ask, triage, drafting issues and
rewriting notes) run the official `claude` CLI that's installed and signed in on your Mac, or
on the server you connect to in Settings. They use your own Claude seat, as if you'd run
`claude` yourself.

- Gannin never reads, stores or forwards your Claude login, and never calls Anthropic's API
  with it.
- Claude only runs when you ask: a click, or reopening a session's tab. The background checks
  (review requests, PR checks, session state, diffs) only talk to GitHub.
- Each person uses their own seat. Don't share a Claude login, or a server account signed in
  to one, between people.
- What you share (issues, customer feedback, documents in planning sessions) goes to Claude
  under your account's terms. Use a work seat on your company's Team or Enterprise plan for
  work data.
