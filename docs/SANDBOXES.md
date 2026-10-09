# Sandboxed sessions

When you click Work on This, Claude Code normally runs on your Mac as you. It can read and change
anything you can: other repos, `~/.ssh`, your keychain, cloud credentials. Usually that's fine. But a
bad prompt, instructions hidden in an issue or a dependency, or a mistaken command can reach well
beyond the issue, and that matters most when a session runs Unattended.

With sandboxing on, Gannin runs each issue's Claude Code in its own small Linux VM, made with Apple's
`container`. The VM sees only this:

- the issue's folder in the harness (`.worktrees/<branch>/`), where Claude makes its worktrees;
- the git history of the shared clones in `projects/` (not their checked-out files);
- the harness itself, read-only;
- the session's own folder, where Gannin reads its state.

It doesn't see your home folder, your SSH keys, your keychain, other repos' checkouts or other
sessions. It gets three credentials, all chosen by you: Claude's own login (or an API key), a
GitHub token for the org, and a signing key for its commits.

## What you need

- A Mac with Apple Silicon on macOS 26 or later.
- Apple's `container`. Gannin can install it for you.
- Your git name and email set (`git config --global user.name` and `user.email`). Sandboxed commits
  carry them.

## Setting it up

All of this is in Gannin's Settings, under General.

1. **Claude in a sandbox.** Choose how Claude signs in there:
   - *Sign in with Claude*: nothing to set up here. The first sandboxed session asks you to sign
     in, in its terminal, through Anthropic's own sign-in: open the link it shows, sign in with your
     Claude account, and paste the code back. Claude keeps that login in a folder your sandboxes
     share, so the next ones are signed in already. Gannin never sees or stores it. Sign Out of
     Claude in Sandboxes removes it.
   - *API key*: paste a key from the Claude Console. It's billed to the API and kept in your
     keychain.

   Your own Claude login on this Mac never goes in. Sign in with your own account or key, and
   never share one between people. A subscription's sessions all draw on its usage limits, and
   Pro and Max are for personal use: for a team's work, use Team or Enterprise seats or an API key.
2. **Commit signing.** Click Make a Signing Key (or paste a key of your own without a passphrase).
   Then click Add to GitHub. It copies the public key and opens GitHub's New SSH key page: paste
   it, set *Key type* to **Signing Key**, and save. Commits made in a sandbox then show as Verified.
3. **GitHub for each org.** In the org's Settings, under Harness, click Create One on GitHub. GitHub
   opens with a fine-grained token filled in for the org: contents, pull requests and issues (write)
   and actions (read). Pick the repos it may reach, create it, and paste it back into Gannin.
   Changing workflow files needs Workflows as well.
4. **Turn on "Run Work on This sessions in a sandbox".** If anything is missing, Gannin says what.
   Turning it on gets this Mac ready:
   - installs or updates Apple `container` after asking (macOS asks for your password once);
   - starts its service;
   - sets a Linux kernel;
   - builds Gannin's base image.

   The image build takes a few minutes the first time and about 3.6 GB.

Below that you can set how many CPUs and how much memory each sandbox gets.

## Working with it

- Work on This asks where to run the session: **A sandbox** (the default) or **This Mac**. The
  session's panel says which, and whether its sandbox is starting, running, stopped or failed (with
  why).
- Everything else works as it does on your Mac: Changes, the composer, Attended and Unattended,
  questions, pull requests, and the second agent's review. A session's helpers, such as the
  reviewer, run in the same sandbox.
- The sandbox stops when its sessions' Claude Code exits or you quit Gannin, and starts again when
  you open the session. Finish Session removes it.
- Claude can't clone a new repo the Mac would see. Gannin clones the issue's repos into `projects/`
  before the sandbox starts. If Claude needs another, clone it into `projects/` yourself and restart
  the session.

### Repos that only build on a Mac

A sandbox is Linux, so Xcode projects and other Mac-only builds can't run there. In the org's
Settings, under Repositories, tick **Needs the Mac** for those repos. Their sessions start on your
Mac and say why.

### A repo's own image

Gannin's base image has Claude Code, git, gh, Node 22, Python and the usual build tools. If a repo
needs more, add `.gannin/sandbox/<repo>.Containerfile` to the harness, starting with
`FROM gannin-base`:

```dockerfile
FROM gannin-base
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
```

It's built the first time a session for that repo starts, and built again only when the file or the
base image changes.

## Sessions on a server

If Settings has a Connect with command, sessions run on that server. When the server is a Mac with
Apple Silicon and Apple `container`, they're sandboxed there in the same way. Settings, under Remote
machines, shows what Gannin finds there:

- **Set Up** starts the service, sets a kernel and builds the base image.
- **Install** or **Update** opens a terminal on the server, where `sudo` asks for that Mac's
  password. Gannin never sees it.

A server that isn't a Mac, or has no `container`, is named in the session with how to fix it.

## Turning it off

Turning sandboxing off asks whether to remove the sandboxes and images Gannin made (only those, by
their `dev.andon.gannin` label), or to keep them for next time. New sessions then run on your Mac.
Sessions already in a sandbox stay in one, because their conversation is there. Opening one starts
its sandbox again, and builds the base image again if you removed it. Finish them to be done with
sandboxes entirely. Sessions started before you turned sandboxing on stay on your Mac for the same
reason, and say so.

## What it doesn't protect

- **The network is open.** A sandbox can reach the internet, and services on your Mac that listen
  on all interfaces. Keep that in mind for local databases and dev servers.
- **Its credentials are inside.** Claude can use the GitHub token on the repos you gave it, and
  commit with the sandbox's key, but not with anything else.
- **Its repos' git is read-only, bar what commits and worktrees need.** The sandbox can commit,
  fetch and make worktrees in the issue's repos, but can't change their git config or hooks. That
  stops it from making git on your Mac run something. A few things don't work in there: branches
  can't be deleted, no upstream is recorded (push with `git push origin HEAD`), and a rebase or
  pull prints a harmless error about `packed-refs.lock`.
- **It can move branches.** A sandbox can update any branch in the issue's repos, the default
  branch's local copy included, though nothing it can push without your token's say. Other
  sessions' worktrees are read-only to it, except ones made on your Mac after its sandbox started,
  until it next starts.
- **Its worktrees are its own.** A sandbox can still change what's in the issue's folder, including
  a worktree's `.git` file, or put a repo inside a worktree. Before Gannin runs git in those
  folders (the Changes pane, Finish, opening a file in your editor, Work › Repositories), it checks
  them, switches hooks and submodules off, and names anything it doesn't trust instead of running
  it. Your own terminal doesn't check, so look before running git in an issue's worktrees yourself.
- **Apple `container` versions:** Gannin is tested with one version and works with a range. A newer
  version runs, with a note that it hasn't been tested.
