import Testing
@testable import Gannin

struct ReviewResultPostsSameTests {
    private func result(summary: String = "Looks fine", verdict: String? = "comment", comment: String = "Rename this", headline: String? = nil) -> SessionTranscript.ReviewResult {
        .init(summary: summary, verdict: verdict, findings: [.init(path: "A.swift", line: 3, comment: comment)], headline: headline)
    }

    @Test func fieldsOnlyGanninShowsDontCount() {
        #expect(result().postsSame(as: result(headline: "A different headline")))
    }

    @Test func aChangedSummaryVerdictOrFindingDoes() {
        #expect(!result().postsSame(as: result(summary: "Some issues")))
        #expect(!result().postsSame(as: result(verdict: "approve")))
        #expect(!result().postsSame(as: result(comment: "Rename that")))
    }
}
