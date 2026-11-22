import Foundation
import Testing
@testable import Gannin

struct ReviewResultPostsSameTests {
    private let first = SessionTranscript.Finding(path: "A.swift", line: 3, comment: "Rename this")
    private let second = SessionTranscript.Finding(path: "B.swift", line: 9, comment: "Missing test")

    private func result(summary: String = "Looks fine", verdict: String? = "comment", findings: [SessionTranscript.Finding]? = nil, headline: String? = nil) -> SessionTranscript.ReviewResult {
        .init(summary: summary, verdict: verdict, findings: findings ?? [first], headline: headline)
    }

    @Test func fieldsOnlyGanninShowsDontCount() {
        var other = result(headline: "A different headline")
        other.resolved = ["thread"]
        other.walkthrough = [.init(title: "Area", summary: nil, files: ["A.swift"])]
        #expect(result().postsSame(as: other))
    }

    @Test func aChangedSummaryOrVerdictDoes() {
        #expect(!result().postsSame(as: result(summary: "Some issues")))
        #expect(!result().postsSame(as: result(verdict: "approve")))
        #expect(!result().postsSame(as: result(verdict: nil)))
    }

    @Test func findingsAreComparedAsASetInEveryField() {
        #expect(result(findings: [first, second]).postsSame(as: result(findings: [second, first])))
        #expect(!result(findings: [first]).postsSame(as: result(findings: [first, second])))
        #expect(!result(findings: [first, second]).postsSame(as: result(findings: [first])))
        var reworded = first
        reworded.comment = "Rename that"
        #expect(!result().postsSame(as: result(findings: [reworded])))
        var graver = first
        graver.severity = "blocker"
        #expect(!result().postsSame(as: result(findings: [graver])))
        var suggested = first
        suggested.suggestion = "let x = 1"
        #expect(!result().postsSame(as: result(findings: [suggested])))
    }

    // MARK: setReviewResult

    private func store(with review: SessionTranscript.ReviewResult) -> (SessionStore, UUID, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReviewResultPostsSameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: UserDefaults(suiteName: "ReviewResultPostsSameTests-\(UUID().uuidString)")!)
        let url = URL(string: "https://github.com/acme/harness/pull/7")!
        var session = CodeSession(
            id: UUID(), issue: IssueReference(org: "acme", id: "I_1", number: 7, title: "Plan", repo: "acme/harness", url: url),
            repo: "acme/harness", branch: "review", createdAt: .now
        )
        session.reviewOf = PullRequestReference(org: "acme", id: "PR_1", number: 7, title: "Plan", repo: "acme/harness", url: url)
        session.reviewResult = review
        store.add(session)
        return (store, session.id, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func aResultThatPostsTheSameLeavesResultAtAlone() {
        let (store, id, cleanUp) = store(with: result())
        defer { cleanUp() }
        let stamped = Date(timeIntervalSince1970: 100)
        store.reviewDrafts[id] = { var draft = ReviewDraft(); draft.resultAt = stamped; return draft }()
        store.setReviewResult(result(headline: "Reworded headline"), for: id)
        #expect(store.reviewDrafts[id]?.resultAt == stamped)
        #expect(store.sessions[id]?.reviewResult?.headline == "Reworded headline")
    }

    @Test func aResultThatPostsSomethingNewStampsResultAt() {
        let (store, id, cleanUp) = store(with: result())
        defer { cleanUp() }
        let stamped = Date(timeIntervalSince1970: 100)
        store.reviewDrafts[id] = { var draft = ReviewDraft(); draft.resultAt = stamped; return draft }()
        store.setReviewResult(result(findings: [first, second]), for: id)
        #expect((store.reviewDrafts[id]?.resultAt ?? .distantPast) > stamped)
    }

    @Test func theFirstResultStampsResultAt() {
        let (store, id, cleanUp) = store(with: result())
        defer { cleanUp() }
        store.update(id) { $0.reviewResult = nil }
        store.setReviewResult(result(), for: id)
        #expect(store.reviewDrafts[id]?.resultAt != nil)
    }
}
