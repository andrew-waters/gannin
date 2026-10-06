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

- **The GitHub release here** has everything: `Gannin-<version>.dmg`, its `.sha256`, the same
  DMG as `Gannin.dmg`, and `appcast.xml`. The appcast's enclosure is the release's
  `Gannin-<version>.dmg`, and the site's Download for Mac button is
  `releases/latest/download/Gannin.dmg`, so every download, by hand or by Sparkle, counts in
  the release's download numbers (which Delivery › Releases reads).
- **gannin.ai** is this repo's GitHub Pages site, deployed by `pages.yml`: `site/` plus the
  latest release's `appcast.xml`, so `https://gannin.ai/appcast.xml` is always the newest. It
  deploys on every push to `main` that touches `site/`, and a release starts it once the
  release is up, so the appcast never points at a file that isn't there.

## Secrets

Set on this repo (Settings › Secrets and variables › Actions), or with `gh secret set`:

| Secret | What it is |
| ------ | ---------- |
| `DEVELOPER_ID_CERTIFICATE_P12` | The Developer ID Application certificate and key, exported as .p12, base64 encoded (`base64 -i cert.p12`). The same one Orchard uses. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Its export password. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | An App Store Connect API key (Users and Access › Integrations › App Store Connect API, Admin role): its ID, the issuer ID and the .p8's contents. xcodebuild signs the Developer ID export with it, and notarytool notarises with it. |
| `SPARKLE_PRIVATE_KEY` | The update signing key, kept in the login keychain under the account `gannin` (`generate_keys --account gannin -x key.txt` exports it). Its public half is `SUPublicEDKey` in `Gannin/Info.plist`. |

## Before the first release

- **DNS.** gannin.ai is on Cloudflare. In its DNS, add for the apex `gannin.ai`:
  - `A` records to `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and `185.199.111.153`
  - `AAAA` records to `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153` and
    `2606:50c0:8003::153`
  - a `CNAME` for `www` to `andrew-waters.github.io`

  all **DNS only** (grey cloud) until GitHub has issued the certificate and Enforce HTTPS is
  on in this repo's Pages settings (Settings › Pages, with GitHub Actions as the source and
  `gannin.ai` as the custom domain). Proxying through Cloudflare after that is fine with SSL
  set to Full (strict). For a verified domain, add the `TXT` record GitHub shows under your
  account's Settings › Pages › Verified domains.

## Moving from gannin-site

gannin.ai used to be served from a separate public repo, andrew-waters/gannin-site, while this
one was private: `publish-site.yml` mirrored `site/` there and releases pushed the DMGs to its
`downloads` branch (andrew-waters/gannin#25). To move over:

1. Attach `Gannin.dmg` and an `appcast.xml` to the latest release. The appcast is gannin-site's
   with only the enclosure URL changed to the release's DMG, which is the same file, so its
   signature and length still hold.
2. In this repo's Settings › Pages, pick GitHub Actions as the source, and run `pages.yml`.
3. Remove `gannin.ai` from gannin-site's Pages, then set it here and turn on Enforce HTTPS once
   the certificate is issued. DNS doesn't change: both repos are this account's Pages.
4. Check `https://gannin.ai/appcast.xml` and the Download for Mac button.
5. Delete the `SITE_DEPLOY_KEY` secret here and the deploy key on gannin-site, and archive
   gannin-site.

## The bundle ID

Gannin was `dev.andon.getgannin` before it was `dev.andon.gannin`. On the first launch under
the new ID, `BundleMove` copies the old preferences, the old Application Support folder and
the GitHub token (the keychain may ask once). The store (`UserData/Gannin.store`) is where it
was. Nothing old is deleted. Gannin no longer uses iCloud: what you enter stays on the device,
and what the team shares lives in the org's harness.
