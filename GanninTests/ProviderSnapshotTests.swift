import Foundation
import Testing
@testable import Gannin

/// What Claude Code is started with, kept byte for byte as it was before the
/// provider abstraction (andrew-waters/gannin#492): each script and settings
/// file is compared with its copy in `Snapshots/`. A missing copy is
/// written and the test fails, so a new one is looked at before it's kept.
@Suite(.serialized)
struct ProviderSnapshotTests {
    private static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Snapshots", directoryHint: .isDirectory)
    private static let root = #""$HOME"/'Code/acme/harness'"#
    private static let directory = #""$HOME"/.gannin/sessions/abc"#

    /// The same text every time, wherever the tests run: the home folder
    /// stands in for this Mac's.
    private func check(_ text: String, _ name: String) throws {
        let normal = text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/"), with: "~HOME")
        let url = Self.folder.appending(path: "\(name).txt")
        guard let kept = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try normal.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("Wrote \(name).txt; check it and run again.")
            return
        }
        #expect(normal == kept, "\(name) changed")
    }

    /// The model and sandboxing as the snapshots were taken, put back after.
    private func withDefaults(model: String?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [SessionStore.modelKey, SandboxCredentials.enabledKey]
        let kept = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }
        defaults.set(model, forKey: SessionStore.modelKey)
        defaults.set(false, forKey: SandboxCredentials.enabledKey)
        try body()
    }

    /// In the harness, or with `inHarness` false one repo's worktree as
    /// sessions were before it.
    private func session(inHarness: Bool = true, _ change: (inout CodeSession) -> Void = { _ in }) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_1", number: 12, title: "Fix the thing's \"edge\"", repo: "acme/api", url: URL(string: "https://github.com/acme/api/issues/12")!)
        var session = CodeSession(
            id: UUID(uuidString: "3F9A2C1D-0000-4000-8000-000000000012")!, issue: issue, repo: inHarness ? "acme/harness" : "acme/api", branch: "12-fix-the-thing",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), harnessRepo: inHarness ? "acme/harness" : nil, harnessPath: inHarness ? "~/Code/acme/harness" : nil
        )
        change(&session)
        return session
    }

    private var sessions: [(String, CodeSession)] {
        let pr = PullRequestReference(org: "acme", id: "PR_1", number: 7, title: "Tidy", repo: "acme/api", url: URL(string: "https://github.com/acme/api/pull/7")!)
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .code, name: "Tidy dependencies")
        routine.limit = .draftPR
        return [
            ("work", session()),
            ("work-instructions", session { $0.instructions = "Follow the team's rules." }),
            ("helper", session { $0.parentID = UUID(uuidString: "3F9A2C1D-0000-4000-8000-000000000001")!; $0.role = "Tests"; $0.prompt = "Write the tests." }),
            ("review", session {
                $0.isReviewer = true
                $0.reviewOf = pr
                $0.role = "Review"
                $0.prompt = SessionStore.pullRequestReviewPrompt(pr, branch: SessionStore.reviewBranch(pr))
            }),
            ("ask", session { $0.ask = AskInfo(title: "Who's busy?", slug: "2026-10-08-3f9a2c1d", message: "Who's busy?"); $0.prompt = "Read the context." }),
            ("quick-change", session { $0.quickChange = QuickChangeInfo(note: "Nudge it", attachments: ["a.png"], hasIssue: false) }),
            ("routine", session { $0.routineRun = RoutineRunInfo(routine: routine, run: UUID()) }),
            ("server", session { $0.connect = "ssh -t devbox" }),
            ("repo", session(inHarness: false)),
        ]
    }

    @Test(arguments: [nil, "claude-opus-5-5"])
    func startScripts(model: String?) throws {
        try withDefaults(model: model) {
            for (name, session) in sessions {
                try check(SessionScript.start(session, root: Self.root, directory: Self.directory), "start-\(name)\(model == nil ? "" : "-model")")
            }
        }
    }

    @Test func sandboxScripts() throws {
        try withDefaults(model: nil) {
            let sandboxed = session { $0.sandbox = SandboxPlacement.containerName(for: $0.id) }
            try check(SessionScript.start(sandboxed, root: Self.root, directory: Self.directory), "start-sandbox")
            try check(SandboxLaunch.innerScript(sandboxed), "sandbox-inner")
            try check(SandboxLaunch.hostSteps(sandboxed, folder: ".worktrees/12-fix-the-thing", cpus: 3, memoryGB: 6), "sandbox-host")
        }
    }

    @Test func settings() throws {
        try check(AgentProviders.claudeCode.settings(directory: Self.directory, isRemote: true), "settings-plain")
        try check(AgentProviders.claudeCode.settings(directory: Self.directory, isRemote: true, allowing: ["/x/ready-for-review"], rules: "rules-hook", sandboxed: true), "settings-full")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
