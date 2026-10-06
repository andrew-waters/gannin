# andrew-waters/gannin#25: Serve gannin.ai and its downloads from this repo, so release downloads are counted

https://github.com/andrew-waters/gannin/issues/25

- State: open
- Labels: enhancement
- Opened by: @andrew-waters, 6 Oct 2026
- Assignees: @andrew-waters

## Description

## Problem

andrew-waters/gannin was private when releases were set up, so gannin.ai is served from a separate public repo, andrew-waters/gannin-site:

- `publish-site.yml` mirrors `site/` into gannin-site's `main` over a deploy key.
- `release.yml` force-pushes each DMG to gannin-site's `downloads` branch and writes `appcast.xml` there.
- The site's Download buttons and Sparkle's appcast enclosure point at `https://gannin.ai/downloads/...`.

The repo is public now, so the split isn't needed. It also hides usage: the GitHub release here has the DMG attached, but almost nobody downloads it from there, so its `downloadCount` (which #24 reads for download stats) undercounts real downloads.

## Proposal

- Serve gannin.ai from this repo's own Pages (`site/`, with its `CNAME`), deployed by a workflow here.
- Point the site's Download buttons at the latest release's asset (`https://github.com/andrew-waters/gannin/releases/latest/download/Gannin.dmg`, so the release also attaches a stable-named `Gannin.dmg`), and Sparkle's enclosure at the versioned asset, so every download is counted on the release.
- Write `appcast.xml` into what Pages deploys here (or attach it to the release and serve it from the site), keeping `https://gannin.ai/appcast.xml` working for installed copies.
- Retire `SITE_DEPLOY_KEY`, `publish-site.yml` and the gannin-site push in `release.yml`; archive gannin-site once gannin.ai is served from here. Update `docs/RELEASING.md` and CLAUDE.md's Releases section.

## Acceptance

- [ ] gannin.ai is served from andrew-waters/gannin, with DNS and HTTPS unchanged for visitors.
- [ ] Download for Mac and Sparkle updates download the DMG from this repo's GitHub releases.
- [ ] `https://gannin.ai/appcast.xml` still serves the latest appcast, so existing installs keep updating.
- [ ] Nothing pushes to andrew-waters/gannin-site any more, and it's archived.

Follows on from #24, whose download stats depend on this.

## Plans and requirements

From the team's harness repo, andrew-waters/gannin, which keeps plans, requirements and findings beside the code. Those about this issue are here in full; the rest mention it.

### Every release, with downloads and stars

Plan, in review, mentions it: `plans/2026-10-06-release-usage.md` (https://github.com/andrew-waters/gannin/blob/main/plans/2026-10-06-release-usage.md)

The Releases page lists every release of each repo, as a table, with downloads and stars per repo and downloads and stars over time at the top.

## Working here

- You're in the team's harness, andrew-waters/gannin, checked out at `~/Code/andrew-waters/gannin`. Its CLAUDE.md lists the projects and how work goes here.
- The code repos are shared clones under `projects/<name>` (some a folder further down, as `projects/<group>/<name>`), kept on their default branch. Don't work in them. This issue's folder is `.worktrees/25-serve-gannin-ai-and-its-downloads-from/`: give each repo it touches a worktree there, on the branch `25-serve-gannin-ai-and-its-downloads-from`, from the harness root:

  ```bash
  git -C projects/<name> fetch origin
  git -C projects/<name> worktree add "$PWD/.worktrees/25-serve-gannin-ai-and-its-downloads-from/<name>" -b 25-serve-gannin-ai-and-its-downloads-from origin/HEAD
  ```

  If the branch already exists, leave out `-b` and `origin/HEAD`. If a repo isn't under `projects/` yet, clone it there first with `gh repo clone <owner>/<name> projects/<name>`.
- If the harness has no `projects/` folder, it's the code repo too: the code is andrew-waters/gannin itself. Don't work in its checkout; give it one worktree in the issue's folder the same way, with `git -C . fetch origin` and `git -C . worktree add "$PWD/.worktrees/25-serve-gannin-ai-and-its-downloads-from/gannin" -b 25-serve-gannin-ai-and-its-downloads-from origin/HEAD`, and do everything there, the plan included.
- Commit in each worktree, and open a pull request per repo with `gh pr create`, putting "Closes andrew-waters/gannin#25" in its body so it links to the issue.
- A plan for this issue goes in the harness as `plans/YYYY-MM-DD-<slug>.md` from `plans/_template.md` (older harnesses keep plans in `requirements/<module>/plans/`), with `issues: [andrew-waters/gannin#25]` and a summary in its front matter as the harness's STANDARDS.md sets out, so Gannin links it to the issue. Commit and push it in the harness, and tick its checkboxes off as tasks land. When the harness is the code repo, the plan goes in its worktree and ships in the same pull request, and only if the repo keeps a `plans/` folder.
- `.worktrees/25-serve-gannin-ai-and-its-downloads-from/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` and `projects/` are kept out of the harness's git.
