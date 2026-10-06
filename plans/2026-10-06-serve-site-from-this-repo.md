---
type: plan
status: In Progress
summary: gannin.ai and its downloads move from andrew-waters/gannin-site to this repo's Pages and releases, so every download counts on the release.
issues: [andrew-waters/gannin#25]
domains: [delivery]
touches: [andrew-waters/gannin]
owner: andrew-waters
---

# Serve gannin.ai and its downloads from this repo

## Context

gannin.ai was served from a separate public repo, andrew-waters/gannin-site, while this one was
private: `publish-site.yml` mirrored `site/` there, and each release force-pushed its DMG to
gannin-site's `downloads` branch and committed `appcast.xml` to its `main`. The site's Download
button and Sparkle's enclosure pointed at `gannin.ai/downloads/`, so the release's own DMG was
hardly ever downloaded and its `downloadCount` (read by andrew-waters/gannin#24) undercounted.
This repo is public now.

## Decisions

- gannin.ai is this repo's Pages, deployed by `pages.yml` with GitHub Actions: `site/` plus the
  latest release's `appcast.xml`. The appcast is a release asset rather than a committed file,
  so releases never push to `main` and a site-only deploy always carries the newest appcast. The
  deploy fails when the latest release has no appcast, rather than publish a site that installed
  copies can't update from.
- Each release attaches `Gannin-<version>.dmg`, its `.sha256`, `Gannin.dmg` and `appcast.xml`.
  The enclosure is the versioned asset; the Download button is
  `releases/latest/download/Gannin.dmg`.
- release.yml starts `pages.yml` on `main` (`gh workflow run`) after the release is created,
  rather than calling it as a reusable workflow, so the deploy runs from the branch the
  `github-pages` environment allows and the appcast never names a DMG that isn't up yet.
- Old `gannin.ai/downloads/` links stop working: nothing in the repo or installed copies uses
  them once the appcast is rewritten.
- The `.sha256` asset counts towards a release's downloads in Gannin's totals; it's the odd one,
  so it's left in.

## Tasks

- [x] `pages.yml` deploys `site/` with the latest release's appcast; `publish-site.yml` removed
- [x] release.yml attaches `Gannin.dmg` and `appcast.xml`, points the enclosure at the release,
      drops the gannin-site push and `SITE_DEPLOY_KEY`, and deploys the site afterwards
- [x] The site's Download buttons point at the latest release's `Gannin.dmg`
- [x] docs/RELEASING.md and CLAUDE.md
- [ ] Cutover: attach `Gannin.dmg` and a rewritten `appcast.xml` to v0.0.2
- [ ] Cutover: Pages from GitHub Actions here, `pages.yml` run, custom domain moved
- [ ] Cutover: `https://gannin.ai/appcast.xml` and Download for Mac checked
- [ ] Cutover: `SITE_DEPLOY_KEY` and gannin-site's deploy key removed, gannin-site archived
