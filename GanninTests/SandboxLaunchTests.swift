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
        #expect(steps.contains("-name .git -type d"))
        #expect(steps.contains("target=/root/.claude"))
        #expect(steps.contains("--cpus 3 --memory 6G"))
        for label in SandboxLaunch.labels { #expect(steps.contains("--label '\(label)'")) }
        // Real paths, as git records them.
        #expect(steps.contains(#"h=$(cd "$harness" && pwd -P)"#))
        // Never the user's home, keys or keychain.
        #expect(!steps.contains("$HOME"))
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

    @Test func claudeHomeStartsPastItsPrompts() throws {
        let text = SandboxLaunch.claudeConfig(harness: "/Users/me/Code/acme/harness", apiKey: "sk-ant-api03-0123456789abcdefghijKLMNOP")
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["hasCompletedOnboarding"] as? Bool == true)
        let projects = object["projects"] as? [String: [String: Bool]]
        #expect(projects?["/Users/me/Code/acme/harness"]?["hasTrustDialogAccepted"] == true)
        let approved = (object["customApiKeyResponses"] as? [String: [String]])?["approved"]
        #expect(approved == ["0123456789abcdefghijKLMNOP".suffix(20).description])
        #expect(!SandboxLaunch.claudeConfig(harness: "/h", apiKey: nil).contains("customApiKeyResponses"))
    }

    @Test func theIssuesReposAreClonedFirst() {
        let with = session(pullRequests: [URL(string: "https://github.com/acme/web/pull/3")!, URL(string: "https://github.com/acme/api/pull/9")!])
        #expect(SandboxLaunch.cloneRepos(with) == ["acme/api", "acme/web"])
    }

    @Test func onAServerSessionsWaitForRemoteSandboxes() {
        let placement = SandboxPlacement.decide(enabled: true, repos: ["acme/api"], reposNeedingMac: [], org: "acme", hasGitHubToken: true, onServer: true)
        #expect(!placement.isSandboxed)
        #expect(placement.reason?.contains("server") == true)
    }
}
