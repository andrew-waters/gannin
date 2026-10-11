import Foundation
import Testing
@testable import Gannin

struct SessionPullRequestProbeTests {
    private func decode(_ json: String) throws -> ProbeResponse {
        try JSONDecoder().decode(ProbeResponse.self, from: Data(json.utf8))
    }

    private func pr(_ id: String, updatedAt: String = "2026-10-11T10:00:00Z", rollup: String = "SUCCESS") -> String {
        """
        {"id":"\(id)","state":"OPEN","updatedAt":"\(updatedAt)","mergeable":"MERGEABLE","reviewDecision":null,
         "commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":{"state":"\(rollup)"}}}]}}
        """
    }

    @Test func groupsSearchResultsAndLookedUpURLsBySession() throws {
        let response = try decode("""
            {"s0":{"nodes":[\(pr("A"))]},"u0_0":\(pr("B")),"s1":{"nodes":[\(pr("C"))]}}
            """)
        #expect(response.fingerprints[0]?.count == 2)
        #expect(response.fingerprints[1]?.count == 1)
    }

    @Test func aSessionWithNoPullRequestsHasNone() throws {
        let response = try decode(#"{"s0":{"nodes":[]},"s1":{"nodes":[\#(pr("C"))]}}"#)
        #expect(response.fingerprints[0] == nil || response.fingerprints[0]?.isEmpty == true)
        #expect(response.fingerprints[1]?.count == 1)
    }

    @Test func aChangeInAnyFieldChangesTheFingerprint() throws {
        let before = try decode(#"{"s0":{"nodes":[\#(pr("A"))]}}"#)
        let updated = try decode(#"{"s0":{"nodes":[\#(pr("A", updatedAt: "2026-10-11T11:00:00Z"))]}}"#)
        let failing = try decode(#"{"s0":{"nodes":[\#(pr("A", rollup: "FAILURE"))]}}"#)
        #expect(before.fingerprints[0] != updated.fingerprints[0])
        #expect(before.fingerprints[0] != failing.fingerprints[0])
        #expect(before.fingerprints[0] == (try decode(#"{"s0":{"nodes":[\#(pr("A"))]}}"#)).fingerprints[0])
    }

    @Test func aLookedUpURLThatIsNotAPullRequestIsIgnored() throws {
        let response = try decode(#"{"s0":{"nodes":[]},"u0_0":{}}"#)
        #expect(response.fingerprints[0] == nil || response.fingerprints[0]?.isEmpty == true)
    }

    // MARK: Which sessions are read in full

    private let id = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func due(
        looked: (Set<String>, Date)?, probed: [UUID: Set<String>]?, pending: Bool = false
    ) -> [UUID] {
        SessionStore.sessionsDue(
            watched: [id], lastLooks: looked.map { [id: (fingerprints: $0.0, at: $0.1)] } ?? [:],
            probed: probed, now: now, hasPendingChecks: { _ in pending }
        )
    }

    @Test func anUnchangedSessionWithinTheIntervalIsSkipped() {
        let recent = now.addingTimeInterval(-60)
        #expect(due(looked: (["a"], recent), probed: [id: ["a"]]).isEmpty)
    }

    @Test func anUnchangedSessionIsReadOnceTheIntervalHasPassed() {
        let old = now.addingTimeInterval(-SessionStore.fullLookInterval)
        #expect(due(looked: (["a"], old), probed: [id: ["a"]]) == [id])
    }

    @Test func aChangedFingerprintIsRead() {
        let recent = now.addingTimeInterval(-60)
        #expect(due(looked: (["a"], recent), probed: [id: ["b"]]) == [id])
    }

    @Test func aSessionWithNoPreviousLookIsRead() {
        #expect(due(looked: nil, probed: [id: ["a"]]) == [id])
    }

    @Test func aSessionWhosePullRequestsAllVanishedIsRead() {
        let recent = now.addingTimeInterval(-60)
        #expect(due(looked: (["a"], recent), probed: [:]) == [id])
    }

    @Test func pendingChecksAreAlwaysRead() {
        let recent = now.addingTimeInterval(-60)
        #expect(due(looked: (["a"], recent), probed: [id: ["a"]], pending: true) == [id])
    }

    @Test func aFailedProbeReadsOnlyWhatIsOldOrNew() {
        let recent = now.addingTimeInterval(-60)
        let old = now.addingTimeInterval(-SessionStore.fullLookInterval - 1)
        #expect(due(looked: (["a"], recent), probed: nil).isEmpty)
        #expect(due(looked: (["a"], old), probed: nil) == [id])
        #expect(due(looked: nil, probed: nil) == [id])
    }
}
