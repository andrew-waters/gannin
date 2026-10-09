import Foundation
import Testing
@testable import Gannin

/// Running a session's claude in its sandbox (andrew-waters/gannin#8, R4,
/// R5, R6, R10, R11, R18).
struct SandboxLaunchTests {
    private func session(sandboxed: Bool = true, pullRequests: [URL] = []) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_1", number: 12, title: "Fix the thing's \"edge\"", repo: "acme/api", url: URL(string: "https://github.com/acme/api/issues/12")!)
        let id = UUID()
        return CodeSession(
            id: id, issue: issue, repo: "acme/harness", branch: "12-fix-the-thing", createdAt: .now, pullRequests: pullRequests,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness",
            sandbox: sandboxed ? SandboxPlacement.containerName(for: id) : nil
        )
    }

    /// `bash -n` on a script: it parses.
    private func parses(_ script: String) -> Shell.Result {
        Shell.run("bash -n <<'GANNIN_SCRIPT'\n\(script)\nGANNIN_SCRIPT", .local)
    }

    @Test func everyScriptParses() {
        let sandboxed = session()
        let start = SessionScript.start(sandboxed, root: #""$HOME"/'Code/acme/harness'"#, directory: #"'/Users/me/Library/Application Support/dev.andon.gannin/Sessions/abc'"#)
        let startResult = parses(start)
        #expect(startResult.ok, "\(startResult.failure)")
        let innerResult = parses(SandboxLaunch.innerScript(sandboxed))
        #expect(innerResult.ok, "\(innerResult.failure)")
        // The host's script is as it was.
        let host = SessionScript.start(session(sandboxed: false), root: #""$HOME"/'Code/acme/harness'"#, directory: "'/tmp/x'")
        #expect(parses(host).ok)
        #expect(!host.contains("container"))
    }

    @Test func theSandboxSeesOnlyWhatItsGiven() {
        let steps = SandboxLaunch.hostSteps(session(), folder: ".worktrees/12-fix-the-thing", cpus: 3, memoryGB: 6)
        #expect(steps.contains(#"--mount "type=bind,source=$h,target=$h,readonly""#))
        #expect(steps.contains(#"--tmpfs "$h/.worktrees" --mount "type=bind,source=$f,target=$f""#))
        #expect(steps.contains(#"--tmpfs "$h/projects""#))
        #expect(steps.contains("find_clone"))
        #expect(steps.contains("target=/root/.claude"))
        #expect(steps.contains("--cpus 3 --memory 6G"))
        for label in SandboxLaunch.labels { #expect(steps.contains("--label '\(label)'")) }
        // Real paths, as git records them.
        #expect(steps.contains(#"h=$(cd "$harness" && pwd -P)"#))
        // Never the user's home, keys or keychain.
        #expect(!steps.contains("source=$HOME"))
        #expect(!steps.contains(".ssh"))
    }

    @Test func insideTheCredentialsAreTakenAndTheFileRemoved() {
        let inner = SandboxLaunch.innerScript(session())
        let read = inner.range(of: #". "$session/secrets.env""#)
        let removed = inner.range(of: #"rm -f "$session/secrets.env""#)
        let claude = inner.range(of: "claude --session-id")
        #expect(read != nil && removed != nil && claude != nil)
        if let read, let removed, let claude {
            #expect(read.upperBound < removed.lowerBound)
            #expect(removed.upperBound < claude.lowerBound)
        }
        #expect(inner.contains("git config --global commit.gpgsign true"))
        #expect(inner.contains("user.signingkey \(SandboxLaunch.signingKeyPath)"))
    }

    @Test func secretsAreQuotedForTheShell() {
        let credentials = SandboxLaunch.Credentials(
            claude: (.subscription, "sk-ant-oat01-abc"), gitHubToken: "github_pat_1", signingKey: "-----BEGIN-----\nkey\n",
            gitName: "Andy O'Brien", gitEmail: "andy@example.com"
        )
        let text = SandboxLaunch.secretsFile(credentials)
        #expect(text.contains("CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-abc'"))
        #expect(text.contains("GH_TOKEN='github_pat_1'"))
        #expect(text.contains(#"GANNIN_GIT_NAME='Andy O'\''Brien'"#))
        #expect(!text.contains("BEGIN"))
        // Read back by the shell, the values come out whole, the key's last
        // newline included (it's piped to a file, as inner.sh does).
        let result = Shell.run("set -a; \(text)set +a; printf '%s|%s|' \"$GANNIN_GIT_NAME\" \"$GH_TOKEN\"; printf %s \"$GANNIN_SIGNING_KEY\" | base64 -d", .local)
        #expect(result.output == "Andy O'Brien|github_pat_1|-----BEGIN-----\nkey\n")
    }

    @Test func secretsAreReadableOnlyByTheUser() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gannin-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try SandboxLaunch.writeSecrets("A='b'\n", to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func claudeHomeIsSeededInsideFromItsOwnHarness() throws {
        let inner = SandboxLaunch.innerScript(session())
        #expect(inner.contains(#"[ ! -f "$CLAUDE_CONFIG_DIR/.claude.json" ]"#))
        // The jq the seed runs, with the harness and an API key's tail.
        let start = try #require(inner.range(of: "jq -n"))
        let end = try #require(inner.range(of: #"> "$CLAUDE_CONFIG_DIR/.claude.json""#, range: start.upperBound..<inner.endIndex))
        let command = String(inner[start.lowerBound..<end.lowerBound])
        guard Shell.run("command -v jq", .local).ok else { return }
        let result = Shell.run("harness=/Users/me/Code/acme/harness; ANTHROPIC_API_KEY=sk-ant-api03-0123456789abcdefghijKLMNOP; \(command)", .local)
        let object = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect(object["hasCompletedOnboarding"] as? Bool == true)
        let projects = object["projects"] as? [String: [String: Bool]]
        #expect(projects?["/Users/me/Code/acme/harness"]?["hasTrustDialogAccepted"] == true)
        #expect((object["customApiKeyResponses"] as? [String: [String]])?["approved"] == ["6789abcdefghijKLMNOP"])
        let noKey = Shell.run("harness=/h; unset ANTHROPIC_API_KEY; \(command)", .local)
        #expect(!noKey.output.contains("customApiKeyResponses"))
    }

    @Test func theIssuesReposAreClonedFirst() {
        let with = session(pullRequests: [URL(string: "https://github.com/acme/web/pull/3")!, URL(string: "https://github.com/acme/api/pull/9")!])
        #expect(SandboxLaunch.cloneRepos(with) == ["acme/api", "acme/web"])
    }

    @Test func helpersShareTheIssuesSandboxAndFolder() {
        let issue = session()
        var helper = issue
        helper = CodeSession(
            id: UUID(), issue: issue.issue, repo: issue.repo, branch: issue.branch, createdAt: .now,
            harnessRepo: issue.harnessRepo, harnessPath: issue.harnessPath, parentID: issue.id, role: "Review", sandbox: issue.sandbox
        )
        SessionStore.noteFolder(of: helper)
        let folder = SessionStore.directory(for: helper.id)
        #expect(folder.path.hasPrefix(SessionStore.directory(for: issue.id).path + "/helpers/"))
        // Whoever starts the sandbox mounts the issue's folder.
        let steps = SandboxLaunch.hostSteps(helper, folder: ".worktrees/\(helper.branch)")
        let issueFolder = SandboxGitGuard.realPath(SessionStore.directory(for: issue.id).path)
        #expect(steps.contains(SessionScript.quoted(issueFolder)))
        #expect(steps.contains(#"--mount "type=bind,source=$si,target=$si""#))
        #expect(steps.contains(#"bash "$s/inner.sh" "$s" "$h""#))
        #expect(parses(SessionScript.start(helper, root: "'/h'", directory: SessionScript.quoted(folder.path))).ok)
    }

    @Test func theStartScriptReportsTheSandbox() {
        let steps = SandboxLaunch.hostSteps(session(), folder: ".worktrees/x")
        let starting = steps.range(of: #"printf starting > "$session/sandbox""#)
        let running = steps.range(of: #"printf running > "$session/sandbox""#)
        let exec = steps.range(of: #"exec "$c" exec -it"#)
        #expect(starting != nil && running != nil && exec != nil)
        if let running, let exec { #expect(running.upperBound < exec.lowerBound) }
        #expect(!steps.contains(#"|| fail ""#))
        #expect(parses(SandboxLaunch.stopScript(["gannin-a", "gannin-b"])).ok)
        #expect(parses(SandboxLaunch.deleteScript("gannin-a")).ok)
    }

    @Test func gitDirsAreReadOnlyBarWhatCommitsWrite() {
        let steps = SandboxLaunch.hostSteps(session(pullRequests: [URL(string: "https://github.com/acme/web/pull/3")!]), folder: ".worktrees/x")
        #expect(steps.contains(#"[ -d "$h/.git" ] && [ ! -d "$h/projects" ] && git_dir "$h/.git""#))
        #expect(steps.contains(#"args+=(--mount "type=bind,source=$1,target=$1,readonly")"#))
        #expect(steps.contains("for part in objects refs logs worktrees; do"))
        #expect(steps.contains("ln -s logs/FETCH_HEAD"))
        #expect(steps.contains(#"g=$(find_clone "$repo") && git_dir "$g""#))
        // A failed start takes its credentials with it.
        #expect(steps.contains(#"rm -f "$session/secrets.env""#))
        let inner = SandboxLaunch.innerScript(session())
        #expect(inner.contains("git config --global branch.autoSetupMerge false"))
    }

    @Test func clonesAreFoundByTheirOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gannin-clones-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        // projects/web is another org's; acme/web is in a group folder.
        let made = Shell.run("""
            export GIT_CONFIG_GLOBAL=/dev/null
            for p in web:https://github.com/other/web.git team/web:git@github.com:acme/web.git api:https://github.com/acme/api; do
              d=\(SessionScript.quoted(root))/projects/${p%%:*}; git init -q "$d" && git -C "$d" remote add origin "${p#*:}"
            done
            """, .local)
        #expect(made.ok)
        func find(_ repo: String) -> String {
            Shell.run("harness=\(SessionScript.quoted(root))\n\(SandboxLaunch.findClone)\nfind_clone \(repo)", .local).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let real = SandboxGitGuard.realPath(root)
        #expect(find("acme/web") == real + "/projects/team/web/.git")
        #expect(find("acme/api") == real + "/projects/api/.git")
        #expect(find("acme/missing").isEmpty)
    }

    @Test func theSandboxedBriefSaysNotToClone() {
        let brief = SessionBrief.make(session: session(), record: nil, detail: nil, parent: nil, harness: nil, goals: [])
        #expect(brief.contains("You're in a sandbox"))
        #expect(brief.contains("git push origin HEAD"))
        #expect(!brief.contains("gh repo clone"))
        let host = SessionBrief.make(session: session(sandboxed: false), record: nil, detail: nil, parent: nil, harness: nil, goals: [])
        #expect(host.contains("gh repo clone"))
    }

    @Test func sandboxStatusReads() {
        #expect(SandboxStatus("starting").state == .starting)
        #expect(SandboxStatus(nil).state == .starting)
        #expect(SandboxStatus("running\n").state == .running)
        #expect(SandboxStatus("stopped").state == .stopped)
        let failed = SandboxStatus("failed: The sandbox didn't start.")
        #expect(failed.state == .failed)
        #expect(failed.error == "The sandbox didn't start.")
    }

    @Test func onAServerTheIssuesFolderIsTheBoxs() {
        let issue = CodeSession(
            id: UUID(), issue: session().issue, repo: "acme/harness", branch: "12-x", createdAt: .now,
            connect: "ssh -t devbox", harnessRepo: "acme/harness", harnessPath: "~/acme-harness", sandbox: "gannin-x"
        )
        let helper = CodeSession(
            id: UUID(), issue: issue.issue, repo: issue.repo, branch: issue.branch, createdAt: .now, connect: issue.connect,
            harnessRepo: issue.harnessRepo, harnessPath: issue.harnessPath, parentID: issue.id, role: "Review", sandbox: issue.sandbox
        )
        #expect(SessionStore.remoteDirectory(for: issue) == #""$HOME"/.gannin/sessions/"# + issue.id.uuidString)
        #expect(SessionStore.remoteDirectory(for: helper) == #""$HOME"/.gannin/sessions/"# + issue.id.uuidString + "/helpers/" + helper.id.uuidString)
        let steps = SandboxLaunch.hostSteps(helper, folder: ".worktrees/12-x")
        #expect(steps.contains(#"si=$(cd "$HOME"/.gannin/sessions/"# + issue.id.uuidString + " && pwd -P)"))
        #expect(steps.contains("on the server"))
        #expect(parses(SessionScript.start(helper, root: #""$HOME"/'acme-harness'"#, directory: SessionStore.remoteDirectory(for: helper))).ok)
        // Secrets arrive on standard input, never in the script.
        let write = SandboxLaunch.remoteSecretsScript(directory: SessionStore.remoteDirectory(for: issue), writing: true)
        #expect(write.contains(#"( umask 077; cat > "$d/secrets.env" )"#))
        #expect(parses(write).ok)
    }

    @Test func theStartScriptChecksTheBoxFirst() {
        let steps = SandboxLaunch.hostSteps(session(), folder: ".worktrees/x")
        #expect(steps.contains(#"[ "$(uname -m)" = arm64 ]"#))
        #expect(steps.contains("macOS 26 or later"))
        let minimum = SandboxSupport.minimum
        #expect(steps.contains("-ge \(minimum.major * 1_000_000 + minimum.minor * 1000 + minimum.patch) ]"))
        #expect(steps.contains("system kernel set --recommended"))
    }

    @Test func secretsReachTheBoxOnStandardInput() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gannin-remote-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let script = SandboxLaunch.remoteSecretsScript(directory: SessionScript.quoted(folder), writing: true)
        let result = Shell.run(script, .local, input: Data("GH_TOKEN='x'\n".utf8))
        #expect(result.ok)
        #expect(try String(contentsOfFile: folder + "/secrets.env", encoding: .utf8) == "GH_TOKEN='x'\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder + "/secrets.env")[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
