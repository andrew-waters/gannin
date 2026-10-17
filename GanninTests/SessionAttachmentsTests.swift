import Foundation
import Testing
@testable import Gannin

/// Files attached on a session's panel: their names, where claude finds
/// them and the prompt that sends them.
struct SessionAttachmentsTests {
    private func session(harness: Bool, connect: String? = nil) -> CodeSession {
        let reference = IssueReference(org: "acme", id: "I_7", number: 7, title: "Fix the thing", repo: "acme/app",
                                       url: URL(string: "https://github.com/acme/app/issues/7")!)
        return CodeSession(
            id: UUID(), issue: reference, repo: harness ? "acme/harness" : "acme/app", branch: "7-fix-the-thing", createdAt: .now,
            connect: connect, harnessRepo: harness ? "acme/harness" : nil, harnessPath: harness ? "~/Code/acme/harness" : nil
        )
    }

    @Test func namesSkipThoseAlreadyTaken() {
        let names = SessionStore.attachmentNames(["Screen Shot.png", "notes.pdf"], existing: ["screen-shot.png", "before.png"])
        #expect(names == ["Screen-Shot-2.png", "notes.pdf"])
    }

    @Test func pathIsFromWhereClaudeRuns() {
        #expect(SessionStore.attachmentPath("a.png", in: session(harness: true)) == ".worktrees/7-fix-the-thing/.gannin/attachments/a.png")
        #expect(SessionStore.attachmentPath("a.png", in: session(harness: false)) == ".gannin/attachments/a.png")
    }

    @Test func promptAddsThePaths() {
        #expect(SessionStore.attachmentPrompt("  Why is this red? ", paths: []) == "Why is this red?")
        #expect(SessionStore.attachmentPrompt("Why is this red?", paths: ["a.png", "b.pdf"]) == "Why is this red?\n\nAttached: `a.png`, `b.pdf`")
        #expect(SessionStore.attachmentPrompt(" ", paths: ["a.png"]) == "Have a look at this file: `a.png`.")
        #expect(SessionStore.attachmentPrompt("", paths: []).isEmpty)
    }

    @Test func uploadWritesIntoTheSessionFolderOnItsBox() {
        let script = SessionStore.attachmentUploadScript("it's.png", in: session(harness: true, connect: "ssh -t devbox"))
        #expect(script.hasPrefix(#"w="$HOME"/'Code/acme/harness/.worktrees/7-fix-the-thing'"#))
        #expect(script.contains(#"cat > "$d"/'.it'\''s.png.part' && mv "$d"/'.it'\''s.png.part' "$d"/'it'\''s.png'"#))
    }

    @Test func uploadNeverMakesTheSessionFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "attachments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var session = session(harness: true)
        session.harnessPath = folder.path
        let script = SessionStore.attachmentUploadScript("a.png", in: session)
        let missing = Shell.run(script, .local, input: Data("png".utf8))
        #expect(!missing.ok)
        #expect(missing.error == SessionStore.attachmentWaiting)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let worktree = folder.appending(path: ".worktrees/7-fix-the-thing")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        #expect(Shell.run(script, .local, input: Data("png".utf8)).ok)
        #expect(try String(contentsOf: worktree.appending(path: ".gannin/attachments/a.png"), encoding: .utf8) == "png")
    }

    @Test func oldSessionsDecodeWithoutAttachments() throws {
        let data = try JSONEncoder().encode(session(harness: true))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["attachments"] = [["name": 3]]
        let decoded = try JSONDecoder().decode(CodeSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.attachments == nil)
    }
}
