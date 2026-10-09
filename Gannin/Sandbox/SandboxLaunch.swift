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
        let issueFolder = SessionScript.quoted(SessionStore.directory(for: session.parentID ?? session.id).resolvingSymlinksInPath().path)
        let harnessRepo = session.harnessRepo ?? session.repo
        let repos = cloneRepos(session).filter { $0.lowercased() != harnessRepo.lowercased() }
        let labelArguments = labels.map { "--label \(SandboxRuntime.quoted($0))" }.joined(separator: " ")
        let tag = #"$(sed -n 's/^image=//p' "$images" | tail -n1)"#
        return """
            sandbox_failed() {
              printf 'failed: %s' "$1" > "$session/sandbox" 2>/dev/null
              fail "$1"
            }
            printf starting > "$session/sandbox"
            c=$(command -v container 2>/dev/null || true)
            [ -n "$c" ] || c=/usr/local/bin/container
            [ -x "$c" ] || sandbox_failed "Apple container isn't installed on this Mac. Set it up in Gannin's Settings, under Sandbox, or start this issue on the Mac."
            if ! "$c" system status --format json 2>/dev/null | grep -q '"status":"running"'; then
              note "Starting Apple container"
              "$c" system start --disable-kernel-install --timeout 60 >/dev/null 2>&1 || sandbox_failed "Apple container's service won't start. Check Gannin's Settings, under Sandbox."
            fi
            [ -f "$session/secrets.env" ] || sandbox_failed "Gannin had no credentials to hand this sandbox. Check Settings, under Sandbox, and the org's GitHub token under Harness, then Restart."

            # Clones the sandbox can see: those already in projects/ and the issue's.
            for repo in \(repos.map(SandboxRuntime.quoted).joined(separator: " ")); do
              clone="$harness/projects/${repo##*/}"
              [ -e "$clone/.git" ] && continue
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
              [ -d "$h/.git" ] && args+=(--mount "type=bind,source=$h/.git,target=$h/.git")
              args+=(--tmpfs "$h/.worktrees" --mount "type=bind,source=$f,target=$f")
              if [ -d "$h/projects" ]; then
                args+=(--tmpfs "$h/projects")
                while IFS= read -r g; do args+=(--mount "type=bind,source=$g,target=$g"); done < <(find "$h/projects" -mindepth 2 -maxdepth 3 -name .git -type d)
              fi
              args+=(--mount "type=bind,source=$si,target=$si" --mount "type=bind,source=$si/claude-home,target=\(claudeHome)")
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

    /// What runs inside: the credentials Gannin left read and the file
    /// removed, the signing key written outside every mount, git's identity
    /// and signing set, then claude in the harness. `$1` is the session's
    /// folder and `$2` the harness, at their real paths.
    static func innerScript(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        return """
            # Written by Gannin for \(session.issue.reference). Runs inside its sandbox.
            session=$1
            harness=$2
            id=\(SessionScript.quoted(session.claudeID))
            folder="$harness"/\(SessionScript.quoted(folder))

            \(SessionScript.functions)

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
            unset GANNIN_GIT_NAME GANNIN_GIT_EMAIL
            cd "$harness" || fail "The harness isn't mounted."

            \(SessionScript.claudeSteps(session, settings: #""$folder/.gannin/"# + SessionScript.settingsName(session) + #"""#, shellNote: "This shell is in the sandbox, in the harness"))
            """
    }

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
        var claude: (kind: SandboxCredentials.ClaudeKind, value: String)
        var gitHubToken: String
        var signingKey: String
        var gitName: String
        var gitEmail: String
    }

    /// What's missing for the session's org, or the credentials.
    static func credentials(org: String) -> Result<Credentials, SandboxRuntime.Failure> {
        let kind = SandboxCredentials.claudeKind
        var missing: [String] = []
        let claude = SandboxCredentials.claudeCredential(kind)
        if claude == nil { missing.append("a Claude \(kind.name.lowercased())") }
        let token = SandboxCredentials.gitHubToken(org: org)
        if token == nil { missing.append("a GitHub token for \(org)") }
        let key = SandboxCredentials.signingKey
        if key == nil { missing.append("a signing key") }
        let identity = gitIdentity()
        if identity.name.isEmpty || identity.email.isEmpty { missing.append("your git name and email (git config --global user.name and user.email)") }
        guard let claude, let token, let key, missing.isEmpty else {
            return .failure(SandboxRuntime.Failure(message: "The sandbox needs \(missing.joined(separator: ", ")).", output: ""))
        }
        return .success(Credentials(claude: (kind, claude), gitHubToken: token, signingKey: key, gitName: identity.name, gitEmail: identity.email))
    }

    /// `secrets.env`: shell assignments the inner script reads and removes.
    static func secretsFile(_ credentials: Credentials) -> String {
        let values = [
            (credentials.claude.kind.environmentName, credentials.claude.value),
            ("GH_TOKEN", credentials.gitHubToken),
            ("GANNIN_SIGNING_KEY", Data(credentials.signingKey.utf8).base64EncodedString()),
            ("GANNIN_GIT_NAME", credentials.gitName),
            ("GANNIN_GIT_EMAIL", credentials.gitEmail),
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

    // MARK: claude-home

    /// Claude Code's config in a fresh `claude-home`: onboarding done and the
    /// harness trusted, so a new sandbox doesn't stop at first-run prompts,
    /// and an API key already approved. Nothing comes from the user's own
    /// `~/.claude`. Left alone once there.
    static func seedClaudeHome(_ home: URL, harness: String, apiKey: String?) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appending(path: ".claude.json")
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        try? Data(claudeConfig(harness: harness, apiKey: apiKey).utf8).write(to: config)
    }

    static func claudeConfig(harness: String, apiKey: String?) -> String {
        var object: [String: Any] = [
            "hasCompletedOnboarding": true,
            "theme": "dark",
            "projects": [harness: ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true]],
        ]
        if let apiKey { object["customApiKeyResponses"] = ["approved": [String(apiKey.suffix(20))], "rejected": [String]()] }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
