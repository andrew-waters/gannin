import Foundation
import Testing
@testable import Gannin

/// A review waits on its author once what it said has been posted, whether as comments, requested changes or an approval.
struct AwaitsAuthorTests {
    private func store() -> SessionStore {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AwaitsAuthorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "AwaitsAuthorTests-\(UUID().uuidString)")!)
    }

    private func session(posted event: String?, resultAt: Date? = nil, postedAt: Date = Date(timeIntervalSince1970: 200)) -> CodeSession {
        let url = URL(string: "https://github.com/acme/harness/pull/7")!
        var session = CodeSession(
            id: UUID(), issue: IssueReference(org: "acme", id: "I_1", number: 7, title: "Plan", repo: "acme/harness", url: url),
            repo: "acme/harness", branch: "review", createdAt: .now
        )
        session.reviewOf = PullRequestReference(org: "acme", id: "PR_1", number: 7, title: "Plan", repo: "acme/harness", url: url)
        var draft = ReviewDraft()
        draft.resultAt = resultAt
        if let event {
            draft.posted = url
            draft.postedAt = postedAt
            draft.postedEvent = event
        }
        session.reviewDraft = draft
        return session
    }

    @Test func postedCommentsAndRequestedChangesAwaitTheAuthor() {
        let store = store()
        #expect(store.awaitsAuthor(session(posted: "COMMENT")))
        #expect(store.awaitsAuthor(session(posted: "REQUEST_CHANGES")))
    }

    @Test func anApprovalAwaitsTheAuthorToo() {
        #expect(store().awaitsAuthor(session(posted: "APPROVE")))
    }

    @Test func anUnpostedReviewDoesNot() {
        #expect(!store().awaitsAuthor(session(posted: nil)))
    }

    /// A new round's result that isn't posted yet puts it back with the reviews still to post.
    @Test func aNewerResultThanThePostDoesNot() {
        let newer = session(posted: "COMMENT", resultAt: Date(timeIntervalSince1970: 300))
        #expect(!store().awaitsAuthor(newer))
    }

    @Test func theLiveDraftWinsOverTheSavedOne() {
        let store = store()
        let saved = session(posted: "COMMENT")
        store.reviewDrafts[saved.id] = ReviewDraft()
        #expect(!store.awaitsAuthor(saved))
    }
}
