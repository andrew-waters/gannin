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
}
