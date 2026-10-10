import Foundation
import Testing
@testable import Gannin

/// Quick changes: work started from a note and screenshots, with or without
/// an issue.
struct QuickChangeTests {
    private let id = UUID(uuidString: "3F9A2C1D-0000-0000-0000-000000000000")!

    private func session(issue: Bool, attachments: [String] = ["before.png"]) -> CodeSession {
        let reference = issue
            ? IssueReference(org: "acme", id: "I_12", number: 12, title: "Nudge the Save button up", repo: "acme/app",
                             url: URL(string: "https://github.com/acme/app/issues/12")!)
            : IssueReference(org: "acme", id: "quick-\(id.uuidString)", number: 0, title: "Nudge the Save button up", repo: "acme/app",
                             url: URL(string: "https://github.com/acme/app")!)
        let branch = issue ? SessionStore.branchName(reference) : SessionStore.quickBranchName(title: reference.title, id: id)
        var session = CodeSession(
            id: id, issue: reference, repo: "acme/harness", branch: branch, createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        session.quickChange = QuickChangeInfo(note: "The Save button sits too low on small windows.", attachments: attachments, hasIssue: issue)
        return session
    }

    @Test func branchWithoutAnIssueIsNamedForTheTitle() {
        #expect(SessionStore.quickBranchName(title: "Nudge the Save button up!", id: id) == "quick-nudge-the-save-button-up-3f9a")
        #expect(SessionStore.quickBranchName(title: "✨", id: id) == "quick-3f9a")
        let long = SessionStore.quickBranchName(title: String(repeating: "word ", count: 20), id: id)
        #expect(long.count <= "quick-".count + 32 + 5)
    }

    @Test func attachmentNamesAreSafeAndUnique() {
        let names = SessionStore.attachmentNames(["Screen Shot 1.png", "Screen Shot 1.png", "it's.jpg", "", "图.png", "notes"])
        #expect(names == ["Screen-Shot-1.png", "Screen-Shot-1-2.png", "it-s.jpg", "screenshot-4.png", "screenshot-5.png", "notes"])
    }

    @Test func withoutAnIssue() {
        let session = session(issue: false)
        #expect(session.hasNoIssue)
        #expect(session.shortReference == "Quick change")
        // The repo picked, not the harness (`repo`) it runs in.
        #expect(session.longReference == "a quick change in acme/app")
        #expect(session.issueValues["issue"] == "a quick change in acme/app")
        #expect(session.issueValues["number"] == "")
        #expect(session.issueValues["repo"] == "acme/app")
        #expect(SessionStore.harnessFolder(for: session) == "sessions/quick-nudge-the-save-button-up-3f9a")

        let brief = SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        #expect(brief.hasPrefix("# Quick change in acme/app: Nudge the Save button up"))
        #expect(!brief.contains("## Description"))
        #expect(brief.contains("## The note\n\nThe Save button sits too low on small windows."))
        #expect(brief.contains("`.worktrees/quick-nudge-the-save-button-up-3f9a/.gannin/attachments/before.png`"))
        #expect(brief.contains("Quick change, no issue."))
        #expect(brief.contains("- The change is in acme/app."))
        #expect(!brief.contains("The issue lives in"))
        #expect(brief.contains("This change's folder"))
        // No reference to close: the PR line only says where `Closes` would go.
        #expect(!brief.contains("Closes acme/"))
        #expect(!brief.contains("Closes #"))
        #expect(!brief.contains("#0"))
        #expect(brief.contains("needs no plan document"))
        #expect(!brief.contains("plans/YYYY-MM-DD"))
    }

    @Test func withAnIssue() {
        let session = session(issue: true, attachments: [])
        #expect(!session.hasNoIssue)
        #expect(session.shortReference == "#12")
        #expect(session.longReference == "acme/app#12")
        #expect(session.issueValues["number"] == "12")
        #expect(SessionStore.harnessFolder(for: session) == "sessions/app-12")

        let brief = SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: nil)
        #expect(brief.hasPrefix("# acme/app#12: Nudge the Save button up"))
        #expect(brief.contains("Gannin filed acme/app#12 from the note"))
        #expect(brief.contains("Closes acme/app#12"))
        #expect(!brief.contains("## Screenshots"))
        #expect(!brief.contains("Not loaded in Gannin yet"))
    }

    @Test func promptSkipsThePlanButStopsWhenItIsNotSmall() {
        let prompt = SessionStore.quickChangePrompt(session(issue: false))
        #expect(prompt.contains("quick change in acme/app"))
        #expect(prompt.contains("the screenshots"))
        #expect(prompt.contains("no plan document"))
        #expect(prompt.contains("stop and say so"))
        // With no issue, there's nothing to write up.
        #expect(!prompt.contains("gh issue edit"))
    }

    @Test func promptWritesUpTheIssueBeforeChangingAnything() {
        let prompt = SessionStore.quickChangePrompt(session(issue: true))
        #expect(prompt.contains("before changing anything, fill out acme/app#12"))
        #expect(prompt.contains("gh issue edit"))
        let writeUp = prompt.range(of: "fill out")!.lowerBound
        #expect(writeUp < prompt.range(of: "Then make the change")!.lowerBound)
    }

    @Test func startScriptCopiesTheScreenshots() {
        let quick = SessionScript.start(session(issue: false), root: "'/h'", directory: "'/s'")
        #expect(quick.contains(#"cp -R "$session/attachments/." "$folder/.gannin/attachments/""#))
        // Each listed screenshot is checked, so one that didn't arrive is said.
        #expect(quick.contains("for name in 'before.png'; do"))
        #expect(!SessionScript.start(session(issue: false, attachments: []), root: "'/h'", directory: "'/s'").contains("attachments"))
        var plain = session(issue: true)
        plain.quickChange = nil
        #expect(!SessionScript.start(plain, root: "'/h'", directory: "'/s'").contains("attachments"))
    }

    @Test func remoteScreenshotIsWrittenFromStandardInput() {
        let script = SessionStore.remoteAttachmentScript(directory: #""$HOME"/.gannin/sessions/x"#, name: "it's.png")
        #expect(script == #"""
            d="$HOME"/.gannin/sessions/x
            mkdir -p "$d/attachments" && cat > "$d/attachments"/'.it'\''s.png.part' && mv "$d/attachments"/'.it'\''s.png.part' "$d/attachments"/'it'\''s.png'
            """#)
        #expect(SessionStore.remoteAttachmentListScript(directory: "'/x'") == "d='/x'\nls -1 \"$d/attachments\" 2>/dev/null || true")
    }

    @Test func oldSessionsDecodeWithoutOne() throws {
        var plain = session(issue: true)
        plain.quickChange = nil
        let data = try JSONEncoder().encode(plain)
        let decoded = try JSONDecoder().decode(CodeSession.self, from: data)
        #expect(decoded.quickChange == nil)
        let quick = try JSONDecoder().decode(CodeSession.self, from: JSONEncoder().encode(session(issue: false)))
        #expect(quick.hasNoIssue)
        #expect(quick.quickChange?.attachments == ["before.png"])
    }
}
