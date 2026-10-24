import Foundation
import Testing
@testable import Gannin

/// The provider abstraction (andrew-waters/gannin#492): what Claude Code is
/// asked with, where its transcripts are, and reading provider IDs.
struct AgentProviderTests {
    private func session(sandboxed: Bool = false) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_1", number: 12, title: "Fix", repo: "acme/api", url: URL(string: "https://github.com/acme/api/issues/12")!)
        let id = UUID(uuidString: "3F9A2C1D-0000-4000-8000-000000000012")!
        return CodeSession(
            id: id, issue: issue, repo: "acme/harness", branch: "12-fix", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness",
            sandbox: sandboxed ? SandboxPlacement.containerName(for: id) : nil
        )
    }

    @Test func askRunsClaudeWithItsOptions() {
        let plain = ClaudeCodeProvider.askScript("Hi", files: [:], folder: nil, tools: [], session: nil, model: nil, streams: false)
        #expect(plain.contains("claude '-p' '--output-format' 'text' < .gannin-prompt"))
        #expect(plain.contains(#"trap 'rm -rf "$d"' EXIT"#))

        let full = ClaudeCodeProvider.askScript(
            "Hi", files: ["a/b.md": Data("x".utf8)], folder: "gannin-draft-1", tools: ["Read", "Grep"],
            session: (id: "abc", resume: true), model: "claude-opus-5-5", streams: true
        )
        #expect(full.contains("'--output-format' 'stream-json' '--include-partial-messages' '--verbose' '--model' 'claude-opus-5-5' '--allowedTools' 'Read,Grep' '--resume' 'abc'"))
        #expect(full.contains(#"d="${TMPDIR:-/tmp}/gannin-draft-1""#))
        #expect(!full.contains("trap"))
        #expect(full.contains("> 'a/b.md'"))
    }

    @Test func transcriptsAreLookedForWhereClaudeKeepsThem() {
        let provider = AgentProviders.claudeCode
        let session = session()
        #expect(provider.remoteTranscripts(for: session, sandboxDirectory: nil) == #""$HOME"/.claude/projects/*/3f9a2c1d-0000-4000-8000-000000000012.jsonl"#)
        #expect(provider.remoteTranscripts(for: session, sandboxDirectory: "/s").hasPrefix("/s/claude-home/projects/*/3f9a2c1d-0000-4000-8000-000000000012.jsonl "))

        let home = FileManager.default.temporaryDirectory.appending(path: "gannin-transcripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "-Users-me-harness/\(session.claudeID).jsonl")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(provider.transcript(for: session, home: home)?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func providerIDsAreReadLeniently() {
        #expect(ProviderID(name: "Claude") == .claudeCode)
        #expect(ProviderID(name: " claude-code ") == .claudeCode)
        #expect(ProviderID(name: "Junie") == .junie)
        #expect(ProviderID(name: "codex") == nil)
        #expect(ProviderID(name: "") == nil)
        #expect(ExtraReviewer.junie.providerID.extraReviewer == .junie)
        #expect(!ProviderID.junie.isInteractive)
    }

    @Test func sessionsFromBeforeProvidersRunClaudeCode() throws {
        var session = session()
        session.provider = nil
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CodeSession.self, from: data)
        #expect(decoded.provider == nil)
        #expect(decoded.agent.providerID == .claudeCode)

        // A newer build's provider doesn't lose the session.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["provider"] = "codex"
        let newer = try JSONDecoder().decode(CodeSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(newer.provider == nil)
    }

    @Test func claudeReadsItsModesOffTheFooter() throws {
        let modes = try #require(AgentProviders.claudeCode.modes)
        let rule = String(repeating: "─", count: 60)
        #expect(modes.mode(fromFooter: [rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)", ""]) == .auto)
        #expect(modes.cycleKey == TerminalKeys.shiftTab)
    }
}
