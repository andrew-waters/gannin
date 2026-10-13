import AppKit
import Foundation
import Testing
@testable import Gannin

/// A Design and Refine session's findings in the store: deleting one takes
/// its own screenshots with it, and nothing changes once it's agreed or its
/// issue is made.
@MainActor
struct RefineFindingsStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "RefineFindingsStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    /// A store holding one session, its folder under `folder`, with two
    /// findings: the first has a screenshot of its own and one it shares
    /// with the second.
    private func store(_ change: (inout RefineInfo) -> Void = { _ in }) -> (SessionStore, CodeSession) {
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder.appending(path: "store"))
        let id = UUID()
        var session = CodeSession(
            id: id, issue: IssueReference(org: "acme", id: "refine-\(id.uuidString)", number: 0, title: "Sign-up", repo: "acme/harness",
                                          url: URL(string: "https://github.com/acme/harness")!),
            repo: "acme/harness", branch: "refine-2026-10-10-sign-up", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: folder.appending(path: "harness").path
        )
        let own = RefineInfo.Screenshot(file: "screenshot-1.png", url: "https://staging.acme.com/signup", at: .now)
        let shared = RefineInfo.Screenshot(file: "screenshot-2.png", url: "https://staging.acme.com/signup", at: .now)
        var info = RefineInfo(name: "Sign-up", slug: "2026-10-10-sign-up", url: "https://staging.acme.com/signup", repos: ["acme/app"], attendees: [])
        info.screenshots = [own, shared]
        info.findings = [
            .init(note: "The Save button sits below the fold", url: info.url, pageTitle: "Sign up", at: .now, screenshots: [own.id, shared.id]),
            .init(note: "No confirmation copy", url: info.url, pageTitle: nil, at: .now, screenshots: [shared.id]),
        ]
        change(&info)
        session.refine = info
        store.add(session)
        return (store, session)
    }

    private func refine(_ store: SessionStore, _ session: CodeSession) throws -> RefineInfo {
        try #require(store.sessions[session.id]?.refine)
    }

    @Test func deletingAFindingTakesOnlyItsOwnScreenshots() throws {
        defer { clean() }
        let (store, session) = store()
        let info = try refine(store, session)
        let files = try #require(RefineScreenshots.folder(for: session))
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for shot in info.screenshots { try Data([1]).write(to: files.appending(path: shot.file)) }

        store.removeFinding(info.findings[0].id, from: session.id)
        let after = try refine(store, session)
        #expect(after.findings.map(\.note) == ["No confirmation copy"])
        #expect(after.screenshots.map(\.file) == ["screenshot-2.png"])
        #expect(!FileManager.default.fileExists(atPath: files.appending(path: "screenshot-1.png").path))
        #expect(FileManager.default.fileExists(atPath: files.appending(path: "screenshot-2.png").path))
    }

    @Test func agreedFindingsStayAsTheyAre() throws {
        defer { clean() }
        let (store, session) = store { $0.agreed = .now }
        let before = try refine(store, session)
        store.setFindingNote("Changed", finding: before.findings[0].id, in: session.id)
        store.removeFinding(before.findings[1].id, from: session.id)
        store.moveFindings(from: [0], to: 2, in: session.id)
        #expect(store.addFinding("Too late", url: before.url, pageTitle: nil, to: session.id) == nil)
        #expect(try refine(store, session) == before)
    }

    @Test func aFindingWithItsIssueMadeStaysAsItIs() throws {
        defer { clean() }
        let (store, session) = store()
        let first = try refine(store, session).findings[0]
        store.update(session.id) {
            $0.refine?.made = [first.id.uuidString: .init(id: "I_1", reference: "acme/app#12", url: URL(string: "https://github.com/acme/app/issues/12")!)]
        }
        store.removeFinding(first.id, from: session.id)
        store.setFindingNote("Changed", finding: first.id, in: session.id)
        let after = try refine(store, session)
        #expect(after.findings.first == first)
        #expect(after.screenshots.count == 2)
    }

    @Test func aScreenshotOnANewFindingMakesOneFinding() throws {
        defer { clean() }
        let (store, session) = store { $0.findings = []; $0.screenshots = [] }
        let image = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let saved = try store.saveScreenshot(image, marks: [], replacing: nil, url: "https://staging.acme.com/signup",
                                             pageTitle: "Sign up\n  [beta]", attachTo: nil, note: "Header overlaps the logo", in: session.id)
        let info = try refine(store, session)
        #expect(info.findings.map(\.note) == ["Header overlaps the logo"])
        #expect(info.findings.first?.screenshots == [saved.id])
        #expect(info.findings.first?.pageTitle == "Sign up [beta]")
        #expect(info.screenshots.map(\.id) == [saved.id])
        let file = try #require(RefineScreenshots.url(saved, in: session))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func pageTitlesAreOneShortLine() {
        #expect(RefineInfo.pageTitle("  Sign up\n\tnow ") == "Sign up now")
        #expect(RefineInfo.pageTitle(" \n ") == nil)
        #expect(RefineInfo.pageTitle(String(repeating: "a", count: 500))?.count == 202)
    }

    @Test func onlyTranscriptsAreRead() async throws {
        defer { clean() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = folder.appending(path: "meeting.vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nThe Save button is hard to find".utf8).write(to: text)
        let image = folder.appending(path: "shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        #expect(await RefineTranscript.text(from: text)?.contains("Save button") == true)
        #expect(!RefineTranscript.accepts(image))
        #expect(await RefineTranscript.text(from: image) == nil)
    }
}
