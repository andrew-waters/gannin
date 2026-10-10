import Foundation

/// Running a Work on This session's claude in its issue's Apple container
/// (andrew-waters/gannin#8, R4, R5, R6, R10, R11, R18). The start script
/// prepares the harness on the Mac as for any session, then `hostSteps`
/// starts the container with everything mounted at its Mac path, so git,
/// hooks, Changes and editors keep working, and execs `inner.sh` there,
/// which takes the credentials Gannin left in `secrets.env` and runs claude.
enum SandboxLaunch {
    /// Inside the container: claude's config, transcripts included, kept in
    /// the session's `claude-home` on the Mac.
    static let claudeHome = "/root/.claude"
    /// Where the signing key is written inside, outside every mount.
    static let signingKeyPath = "/run/gannin-signing-key"
    /// The labels on every sandbox: Gannin's own, for cleanup, and the ones
    /// Orchard reads (andrew-waters/orchard#122).
    static let labels = [
        SandboxImages.label,
        "com.orchard.sandbox=true",
        "com.orchard.sandbox.owner=dev.andon.gannin",
        "com.orchard.sandbox.network=nat",
    ]

    /// After the harness is prepared (`$session`, `$harness`, `$folder` and
    /// `$id` set, in the harness): container's service up, the issue's repos
    /// cloned so the sandbox sees them, the image built or found (its output
    /// in the terminal), the container started unless it's running, then
    /// claude run inside it.
    static func hostSteps(_ session: CodeSession, folder: String, cpus: Int = SandboxCredentials.cpus, memoryGB: Int = SandboxCredentials.memoryGB) -> String {
        let name = session.sandbox ?? SandboxPlacement.containerName(for: session.id)
        // The issue's folder, which holds its helpers': mounted whichever of
        // them starts the sandbox.
        let issueFolder = session.isRemote
            ? SessionStore.remoteIssueDirectory(for: session)
            : SessionScript.quoted(SandboxGitGuard.realPath(SessionStore.directory(for: session.parentID ?? session.id).path))
        let box = session.isRemote ? "the server" : "this Mac"
        let fixContainer = session.isRemote
            ? "Install or update it from Gannin's Settings, under Sandbox › Remote machines, or on the server from github.com/apple/container/releases."
            : "Set it up in Gannin's Settings, under Sandbox."
        let minimum = SandboxSupport.minimum
        let claudeFolder = session.isRemote ? SandboxCredentials.remoteClaudeFolder : SessionScript.quoted(SandboxCredentials.claudeFolder.path)
        let harnessRepo = session.harnessRepo ?? session.repo
        let repos = cloneRepos(session).filter { $0.lowercased() != harnessRepo.lowercased() }
        let labelArguments = labels.map { "--label \(SandboxRuntime.quoted($0))" }.joined(separator: " ")
        let tag = #"$(sed -n 's/^image=//p' "$images" | tail -n1)"#
        return """
            sandbox_failed() {
              # Its credentials go with it, not left for the next start.
              rm -f "$session/secrets.env"
              printf 'failed: %s' "$1" > "$session/sandbox" 2>/dev/null
              fail "$1"
            }
            printf starting > "$session/sandbox"
            c=$(command -v container 2>/dev/null || true)
            [ -n "$c" ] || c=/usr/local/bin/container
            [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || sandbox_failed "Sandboxes need a Mac with Apple Silicon, and \(box) isn't one. Start this issue on the Mac instead."
            [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] 2>/dev/null || sandbox_failed "Sandboxes need macOS 26 or later on \(box). Update macOS there, or start this issue on the Mac instead."
            [ -x "$c" ] || sandbox_failed "Apple container isn't installed on \(box). \(fixContainer)"
            v=$("$c" --version 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+(\\.[0-9]+)?' | head -n1)
            IFS=. read -r v1 v2 v3 <<< "$v"
            [ $(( ${v1:-0} * 1000000 + ${v2:-0} * 1000 + ${v3:-0} )) -ge \(minimum.major * 1_000_000 + minimum.minor * 1000 + minimum.patch) ] || sandbox_failed "Apple container ${v:-of an unknown version} on \(box) is older than \(minimum.description), the oldest Gannin works with. \(fixContainer)"
            if ! "$c" system status --format json 2>/dev/null | grep -q '"status":"running"'; then
              note "Starting Apple container"
              "$c" system start --disable-kernel-install --timeout 60 >/dev/null 2>&1 || sandbox_failed "Apple container's service won't start on \(box). Run container system start there to see why."
            fi
            if [ ! -e "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-$(uname -m)" ]; then
              note "Setting Apple container's Linux kernel"
              "$c" system kernel set --recommended || sandbox_failed "Apple container's Linux kernel couldn't be set on \(box)."
            fi
            [ -f "$session/secrets.env" ] || sandbox_failed "Gannin had no credentials to hand this sandbox. Check Settings, under Sandbox, and the org's GitHub token under Harness, then Restart."

            # The issue's repos' clones in projects/ (or projects/<group>/), found by
            # their origin rather than their folder's name; read, never run.
            \(findClone)
            for repo in \(repos.map(SandboxRuntime.quoted).joined(separator: " ")); do
              find_clone "$repo" >/dev/null && continue
              clone="$harness/projects/${repo##*/}"
              [ -e "$clone" ] && { warn "projects/${repo##*/} is another repo, so $repo isn't in the sandbox."; continue; }
              note "Cloning $repo into projects/"
              mkdir -p "$harness/projects"
              if command -v gh >/dev/null 2>&1; then gh repo clone "$repo" "$clone" -- --quiet || warn "Couldn't clone $repo."
              else git clone --quiet "https://github.com/$repo.git" "$clone" || warn "Couldn't clone $repo."; fi
            done

            # Mounted at their real paths, as git recorded them.
            h=$(cd "$harness" && pwd -P)
            s=$(cd "$session" && pwd -P)
            si=$(cd \(issueFolder) && pwd -P) || sandbox_failed "The issue's session folder isn't there."
            f="$h"/\(SandboxRuntime.quoted(folder))
            mkdir -p "$s/claude-home" "$si/claude-home"
            name=\(SandboxRuntime.quoted(name))
            if "$c" list --format json 2>/dev/null | grep -q "\\"id\\":\\"$name\\""; then
              note "The sandbox is running; claude starts in it"
            else
              "$c" delete --force "$name" >/dev/null 2>&1 || true
              images=$(mktemp)
              ( \(SandboxImages.baseScript(container: #""$c""#).replacingOccurrences(of: "\n", with: "\n  ")) ) || { rm -f "$images"; sandbox_failed "Gannin's base image didn't build. What container said is above."; }
              ( \(SandboxImages.repoScript(repo: session.issue.repo, harness: #""$h""#, container: #""$c""#).replacingOccurrences(of: "\n", with: "\n  ")) ) | tee "$images" || true
              image=\(tag)
              rm -f "$images"
              [ -n "$image" ] || sandbox_failed "The sandbox's image didn't build. What container said is above."
              args=(run --detach --name "$name" \(labelArguments) --cpus \(cpus) --memory \(memoryGB)G
                --mount "type=bind,source=$h,target=$h,readonly")
              # A repo's git dir, writable so commits and worktrees work, with
              # its hooks read-only; what it says is checked before git on the
              # Mac trusts it (SandboxGitGuard).
              # A repo's git dir read-only, so its config and hooks can't be
              # changed for git on the Mac to run, with only what commits,
              # fetches and worktrees write read-write inside it. FETCH_HEAD
              # goes into logs/ through a link made here, as git writes it at
              # the top. Deleting a branch still can't (packed-refs.lock).
              git_dir() {
                mkdir -p "$1/worktrees" "$1/logs"
                if [ ! -L "$1/FETCH_HEAD" ]; then
                  [ -f "$1/FETCH_HEAD" ] && mv "$1/FETCH_HEAD" "$1/logs/FETCH_HEAD"
                  ln -s logs/FETCH_HEAD "$1/FETCH_HEAD"
                fi
                args+=(--mount "type=bind,source=$1,target=$1,readonly")
                for part in objects refs logs worktrees; do args+=(--mount "type=bind,source=$1/$part,target=$1/$part"); done
                # Other sessions' and checkouts' worktrees read-only, so their
                # commondir and gitdir can't be pointed elsewhere; this issue's
                # are in its folder, and new ones it makes will be too.
                for w in "$1"/worktrees/*/; do
                  w=${w%/}
                  [ -d "$w" ] || continue
                  case "$(cat "$w/gitdir" 2>/dev/null)" in ("$f"/*) ;; (*) args+=(--mount "type=bind,source=$w,target=$w,readonly") ;; esac
                done
              }
              # The harness's own git only when it's the code repo too.
              [ -d "$h/.git" ] && [ ! -d "$h/projects" ] && git_dir "$h/.git"
              args+=(--tmpfs "$h/.worktrees" --mount "type=bind,source=$f,target=$f")
              if [ -d "$h/projects" ]; then
                args+=(--tmpfs "$h/projects")
                # Only the issue's repos, not every clone (and others' branches).
                for repo in \(repos.map(SandboxRuntime.quoted).joined(separator: " ")); do
                  g=$(find_clone "$repo") && git_dir "$g"
                done
              fi
              # Claude's config every sandbox shares (its own login among it),
              # with this issue's transcripts over its projects/.
              mkdir -p \(claudeFolder)/projects "$si/claude-home/projects"
              cf=$(cd \(claudeFolder) && pwd -P)
              args+=(--mount "type=bind,source=$si,target=$si" --mount "type=bind,source=$cf,target=\(claudeHome)" --mount "type=bind,source=$si/claude-home/projects,target=\(claudeHome)/projects")
              note "Starting the sandbox $name ($image)"
              "$c" "${args[@]}" "$image" sh -c "trap 'exit 0' TERM; sleep infinity & wait" >/dev/null || sandbox_failed "The sandbox didn't start. Run container logs $name to see why."
            fi
            printf running > "$session/sandbox"
            exec "$c" exec -it -e TERM=xterm-256color -e COLORTERM=truecolor -e LANG=C.UTF-8 -e CLAUDE_CONFIG_DIR=\(claudeHome) "$name" bash "$s/inner.sh" "$s" "$h"
            """
    }

    /// Stops sandboxes by name, quickly: their process takes SIGTERM.
    static func stopScript(_ names: [String]) -> String {
        #"c=$(command -v container 2>/dev/null || echo /usr/local/bin/container); "$c" stop "# + names.map(SandboxRuntime.quoted).joined(separator: " ") + " >/dev/null 2>&1; true"
    }

    static func deleteScript(_ name: String) -> String {
        #"c=$(command -v container 2>/dev/null || echo /usr/local/bin/container); "$c" delete --force "# + SandboxRuntime.quoted(name) + " >/dev/null 2>&1; true"
    }

    /// Claude Code's shared config, kept past first-run prompts: onboarding
    /// done, this harness trusted (added beside others'), and an API key
    /// approved when one is passed in. Nothing comes from anyone's own
    /// `~/.claude`. Needs `$harness` and `$CLAUDE_CONFIG_DIR`.
    static let seedClaudeConfig = """
        cfg="$CLAUDE_CONFIG_DIR/.claude.json"
        [ -s "$cfg" ] || echo '{}' > "$cfg"
        jq --arg h "$harness" --arg k "${ANTHROPIC_API_KEY: -20}" \\
          '.hasCompletedOnboarding = true | .theme = (.theme // "dark")
           | .projects[$h] = ((.projects[$h] // {}) + {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true})
           | if $k == "" then . else .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) + [$k]) | unique) end' \\
          "$cfg" > "$cfg.$$" && mv "$cfg.$$" "$cfg"
        """

    /// `find_clone owner/name`: the real path of the repo's clone's git dir in
    /// `$harness/projects/` or a group under it, matched by its origin rather
    /// than its folder's name, read from its config without running anything.
    static let findClone = """
        find_clone() {
          local g url
          for g in "$harness"/projects/*/.git "$harness"/projects/*/*/.git; do
            [ -d "$g" ] || continue
            url=$(git config --file "$g/config" --get remote.origin.url 2>/dev/null)
            printf '%s\n' "$url" | grep -qiE "[/:]$1(\\.git)?/?$" && { (cd "$g" && pwd -P); return 0; }
          done
          return 1
        }
        """

    /// What runs inside: the credentials Gannin left read and the file
    /// removed, the signing key written outside every mount, git's identity
    /// and signing set, then claude in the harness. `$1` is the session's
    /// folder and `$2` the harness, at their real paths.
    static func innerScript(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        return """
            # Written by Gannin for \(session.longReference). Runs inside its sandbox.
            session=$1
            harness=$2
            id=\(SessionScript.quoted(session.claudeID))
            folder="$harness"/\(SessionScript.quoted(folder))

            \(SessionScript.functions)
            # Nothing stays open in here: ending the terminal is what lets Gannin
            # stop the sandbox once no session uses it.
            fail() {
              printf '\\033[31mGannin: %s\\033[0m\\n' "$1"
              printf 'failed: %s' "$1" > "$session/sandbox" 2>/dev/null
              exit 1
            }

            [ -f "$session/secrets.env" ] || fail "There are no credentials for this sandbox. Restart the session from Gannin."
            set -a
            . "$session/secrets.env"
            set +a
            rm -f "$session/secrets.env"
            ( umask 077; printf %s "$GANNIN_SIGNING_KEY" | base64 -d > \(signingKeyPath) )
            unset GANNIN_SIGNING_KEY
            git config --global user.name "$GANNIN_GIT_NAME"
            git config --global user.email "$GANNIN_GIT_EMAIL"
            git config --global user.signingkey \(signingKeyPath)
            git config --global commit.gpgsign true
            git config --global tag.gpgsign true
            # The repos' git dirs are read-only bar what commits and worktrees
            # write: no tracking written on branching, no gc or maintenance.
            git config --global branch.autoSetupMerge false
            git config --global gc.auto 0
            git config --global maintenance.auto false
            unset GANNIN_GIT_NAME GANNIN_GIT_EMAIL
            # The house rules from Settings › Sandbox, in a file of their own
            # that claude's memory in the shared config imports, so what
            # claude saved in CLAUDE.md is never touched. Written whole and
            # moved into place, as other sandboxes may be reading it.
            rules="$CLAUDE_CONFIG_DIR/\(houseRulesFile)"
            if [ -n "${GANNIN_CLAUDE_MD:-}" ] || [ -f "$rules" ]; then
              if printf %s "${GANNIN_CLAUDE_MD:-}" | base64 -d > "$rules.$$"; then
                mv "$rules.$$" "$rules"
              else
                rm -f "$rules.$$"
                note "Gannin couldn't write your house rules for Claude, so this sandbox has the ones it had before."
              fi
            fi
            if [ -n "${GANNIN_CLAUDE_MD:-}" ]; then
              memory="$CLAUDE_CONFIG_DIR/CLAUDE.md"
              grep -qxF '@\(houseRulesFile)' "$memory" 2>/dev/null \\
                || { { cat "$memory" 2>/dev/null; printf '\\n@\(houseRulesFile)\\n'; } > "$memory.$$" && mv "$memory.$$" "$memory"; }
            fi
            unset GANNIN_CLAUDE_MD
            cd "$harness" || fail "The harness isn't mounted."
            \(seedClaudeConfig)
            # One Claude credential at most: an API key, or claude's own login.
            unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
            if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
              note "Claude isn't signed in in your sandboxes yet. When it asks, choose your Claude account, open the link it shows, sign in, and paste the code back. Your other sandboxes stay signed in."
            fi

            \(SessionScript.claudeSteps(session, settings: #""$folder/.gannin/"# + SessionScript.settingsName(session) + #"""#, shellNote: "", afterExit: "note \"Claude Code has exited, so its sandbox stops once nothing else uses it. Restart the session to go on.\"\nexit 0"))
            """
    }

    /// The house rules' file in the shared config, imported by its CLAUDE.md.
    static let houseRulesFile = "gannin-house-rules.md"

    /// The repos to have cloned before the sandbox starts: the issue's and
    /// those of the PRs it has opened.
    static func cloneRepos(_ session: CodeSession) -> [String] {
        let fromPullRequests = session.pullRequests.compactMap { url -> String? in
            let parts = url.pathComponents.filter { $0 != "/" }
            return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        var seen: Set<String> = []
        return ([session.issue.repo] + fromPullRequests).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Credentials

    struct Credentials: Sendable {
        /// Nil when claude signs in inside the sandbox.
        var apiKey: String?
        var gitHubToken: String
        var signingKey: String
        var gitName: String
        var gitEmail: String
        /// The house rules, for `houseRulesFile`; empty for none.
        var claudeMemory = ""
    }

    /// What's missing for the session's org, or the credentials.
    static func credentials(org: String) -> Result<Credentials, SandboxRuntime.Failure> {
        var missing: [String] = []
        let apiKey = SandboxCredentials.claudeKind == .apiKey ? SandboxCredentials.apiKey : nil
        if SandboxCredentials.claudeKind == .apiKey, apiKey == nil { missing.append("an API key for Claude") }
        let token = SandboxCredentials.gitHubToken(org: org)
        if token == nil { missing.append("a GitHub token for \(org)") }
        let key = SandboxCredentials.signingKey
        if key == nil { missing.append("a signing key") }
        let identity = gitIdentity()
        if identity.name.isEmpty || identity.email.isEmpty { missing.append("your git name and email (git config --global user.name and user.email)") }
        guard let token, let key, missing.isEmpty else {
            return .failure(SandboxRuntime.Failure(message: "The sandbox needs \(missing.joined(separator: ", ")).", output: ""))
        }
        return .success(Credentials(apiKey: apiKey, gitHubToken: token, signingKey: key, gitName: identity.name, gitEmail: identity.email, claudeMemory: SandboxCredentials.claudeMemory))
    }

    /// `secrets.env`: shell assignments the inner script reads and removes.
    static func secretsFile(_ credentials: Credentials) -> String {
        // Only an API key is ever passed in for Claude, and only when it's
        // the choice: a subscription signs in inside.
        let values = (credentials.apiKey.map { [("ANTHROPIC_API_KEY", $0)] } ?? []) + [
            ("GH_TOKEN", credentials.gitHubToken),
            ("GANNIN_SIGNING_KEY", Data(credentials.signingKey.utf8).base64EncodedString()),
            ("GANNIN_GIT_NAME", credentials.gitName),
            ("GANNIN_GIT_EMAIL", credentials.gitEmail),
            ("GANNIN_CLAUDE_MD", Data(credentials.claudeMemory.utf8).base64EncodedString()),
        ]
        return values.map { "\($0.0)=\(SandboxRuntime.quoted($0.1))" }.joined(separator: "\n") + "\n"
    }

    /// Writes it readable only by the user, replacing any left from before.
    static func writeSecrets(_ text: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw SandboxRuntime.Failure(message: "Couldn't write the sandbox's credentials.", output: url.path)
        }
    }

    /// The user's git name and email on this Mac, for the sandbox's commits.
    static func gitIdentity() -> (name: String, email: String) {
        let result = Shell.run("git config --global --get user.name; git config --global --get user.email", .local)
        let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return (lines.first ?? "", lines.dropFirst().first ?? "")
    }

    // MARK: On a server

    /// Puts `secrets.env` in the session's folder on a server from
    /// standard input, readable only by its user, or removes one left
    /// from before when there's nothing to write.
    static func remoteSecretsScript(directory: String, writing: Bool) -> String {
        writing
            ? "d=\(directory)\nmkdir -p \"$d\" && ( umask 077; cat > \"$d/secrets.env\" )"
            : "d=\(directory)\nrm -f \"$d/secrets.env\""
    }
}
