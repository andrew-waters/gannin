# Releasing

A release is a tag. Pushing `v1.2.0` runs `.github/workflows/release.yml`, which archives the
Mac app, signs it with Developer ID, notarises and staples it, packs it in a DMG, signs that
for Sparkle, and publishes it to gannin.ai. Gannin's copies already installed see it in their
next update check, or straight away from Gannin › Check for Updates.

```bash
git tag -a v1.2.0 -m "A headline for the release" -m "- What changed
- And what else"
git push origin v1.2.0
```

The tag's first line is the release's title and the rest its notes, on GitHub and in
Sparkle's update panel. Tags are `v<major>.<minor>.<patch>`; the app's version comes from the
tag (project.yml keeps `0.0.0`, and CI fails a pull request that changes it) and its build
number from the workflow's run, so it only goes up.

## Where things go

- **andrew-waters/gannin-site** is public and holds only what gannin.ai serves. Its Pages
  workflow deploys `main` with the `downloads` branch under `/downloads/`.
- `site/` here is the site's source. `publish-site.yml` mirrors it into gannin-site's `main`
  on every push to `main` that touches it, leaving `appcast.xml` alone.
- A release force-pushes `downloads` with the new `Gannin-<version>.dmg`, its `.sha256` and
  `Gannin.dmg` (the site's Download button), then commits `appcast.xml` to `main`, in that
  order, so the appcast never points at a file that isn't there. Only the latest DMG is
  served; every release's DMG is also attached to the GitHub release here.

## Secrets

Set on this repo (Settings › Secrets and variables › Actions), or with `gh secret set`:

| Secret | What it is |
| ------ | ---------- |
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate and key, exported as .p12, base64 encoded (`base64 -i cert.p12`). The same one Orchard uses. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Its export password. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | An App Store Connect API key (Users and Access › Integrations › App Store Connect API, Admin role): its ID, the issuer ID and the .p8's contents. xcodebuild signs the Developer ID export with it, and notarytool notarises with it. |
| `SPARKLE_PRIVATE_KEY` | The update signing key, kept in the login keychain under the account `gannin` (`generate_keys --account gannin -x key.txt` exports it). Its public half is `SUPublicEDKey` in `Gannin/Info.plist`. |
| `SITE_DEPLOY_KEY` | The private half of gannin-site's write deploy key ("Publish from andrew-waters/gannin"). |

## Before the first release

- **DNS.** gannin.ai is on Cloudflare. In its DNS, add for the apex `gannin.ai`:
  - `A` records to `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and `185.199.111.153`
  - `AAAA` records to `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153` and
    `2606:50c0:8003::153`
  - a `CNAME` for `www` to `andrew-waters.github.io`

  all **DNS only** (grey cloud) until GitHub has issued the certificate and Enforce HTTPS is
  on in gannin-site's Pages settings. Proxying through Cloudflare after that is fine with SSL
  set to Full (strict). For a verified domain, add the `TXT` record GitHub shows under your
  account's Settings › Pages › Verified domains.

## The bundle ID

Gannin was `dev.andon.getgannin` before it was `dev.andon.gannin`. On the first launch under
the new ID, `BundleMove` copies the old preferences, the old Application Support folder and
the GitHub token (the keychain may ask once). The store (`UserData/Gannin.store`) is where it
was. Nothing old is deleted. Gannin no longer uses iCloud: what you enter stays on the device,
and what the team shares lives in the org's harness.
