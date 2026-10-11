import Foundation
import Testing
@testable import Gannin

/// The merged-PR search the metrics backfill and top-up run.
struct MergedSearchTests {
    private let from = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-10 00:00 UTC
    private let to = Date(timeIntervalSince1970: 1_791_676_800) // 2026-10-11 00:00 UTC

    @Test func searchesWholeDaysWithoutASinceTime() {
        let query = GitHubAPI.mergedSearch(org: "acme", from: from, to: to)
        #expect(query.hasSuffix("merged:2026-10-10..2026-10-11"))
    }

    @Test func startsAtTheSinceTimeToTheEndOfTheLastDay() {
        let since = from.addingTimeInterval(10 * 3600 + 30 * 60)
        let query = GitHubAPI.mergedSearch(org: "acme", from: from, to: to, since: since)
        #expect(query.hasSuffix("merged:2026-10-10T10:30:00+00:00..2026-10-11T23:59:59+00:00"))
    }
}
