import Foundation
import Testing
@testable import Gannin

/// `Sessions.json` is written once for saves made close together, and at once
/// for a session added or removed.
@MainActor
struct SessionStoreSaveTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "SessionStoreSaveTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func store() -> SessionStore {
        SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder)
    }

    private func session(_ number: Int) -> CodeSession {
        let issue = IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                                   url: URL(string: "https://github.com/acme/app/issues/\(number)")!)
        return CodeSession(id: UUID(), issue: issue, repo: "acme/harness", branch: SessionStore.branchName(issue), createdAt: .now,
                           harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness")
    }

    private func saved() -> [CodeSession] { store().sessions.values.sorted { $0.issue.number < $1.issue.number } }

    @Test func addIsWrittenAtOnce() {
        let first = session(1)
        store().add(first)
        #expect(saved().map(\.id) == [first.id])
    }

    @Test func updatesCloseTogetherAreWrittenByFlush() {
        let live = store()
        let first = session(1)
        live.add(first)
        live.update(first.id) { $0.name = "one" }
        live.update(first.id) { $0.name = "two" }
        #expect(saved().first?.name != "two")
        live.flushSave()
        #expect(saved().first?.name == "two")
    }

    @Test func updatesAreWrittenAfterTheWindow() async throws {
        let live = store()
        let first = session(1)
        live.add(first)
        live.update(first.id) { $0.name = "later" }
        try await Task.sleep(for: .milliseconds(800))
        #expect(saved().first?.name == "later")
    }

    @Test func aFlushEndsTheWaitingWrite() async throws {
        let live = store()
        let first = session(1)
        live.add(first)
        live.update(first.id) { $0.name = "one" }
        live.flushSave()
        try await Task.sleep(for: .milliseconds(300))
        live.update(first.id) { $0.name = "two" }
        // The first update's wait would have ended by now; the second's hasn't.
        try await Task.sleep(for: .milliseconds(300))
        #expect(saved().first?.name == "one")
        try await Task.sleep(for: .milliseconds(500))
        #expect(saved().first?.name == "two")
    }
}
