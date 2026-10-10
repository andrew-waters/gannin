import Foundation
import Testing
@testable import Gannin

/// Batching outside repos into `repo:` qualifier searches for the workload
/// snapshot (andrew-waters/gannin#173, R4, R7).
struct OutsideRepoBatchingTests {
    @Test func noReposGivesNoBatches() {
        #expect(GitHubAPI.outsideRepoBatches([]).isEmpty)
    }

    @Test func aFewReposFitInOneBatch() {
        let batches = GitHubAPI.outsideRepoBatches(["acme/api", "acme/web"])
        #expect(batches == [["acme/api", "acme/web"]])
    }

    @Test func everyBatchStaysUnderTheSearchLimit() {
        let repos = Set((1...50).map { "some-long-organisation-name/repository-number-\($0)" })
        let batches = GitHubAPI.outsideRepoBatches(repos, reserve: 100, limit: 256)
        #expect(batches.count > 1)
        for batch in batches {
            let length = batch.map { "repo:\($0)" }.joined(separator: " ").count
            #expect(length + 100 <= 256)
        }
        // Every repo is named exactly once, across all the batches.
        #expect(Set(batches.flatMap { $0 }) == repos)
        #expect(batches.flatMap { $0 }.count == repos.count)
    }

    @Test func oneRepoTooLongForTheReserveStillGetsItsOwnBatch() {
        let huge = "owner/" + String(repeating: "x", count: 200)
        let batches = GitHubAPI.outsideRepoBatches([huge], reserve: 100, limit: 256)
        #expect(batches == [[huge]])
    }

    @Test func fullSearchesAreNamedAndSuffixedPerBatch() {
        let batches = [["acme/api"], ["client/app", "client/web"]]
        let searches = GitHubAPI.outsideFullSearches(batches, since: "2026-01-01")
        #expect(searches["outside-open-prs-1"] == "repo:acme/api archived:false is:pr is:open sort:updated-desc")
        #expect(searches["outside-merged-prs-1"] == "repo:acme/api archived:false is:pr is:merged merged:>=2026-01-01 sort:updated-desc")
        #expect(searches["outside-issues-1"] == "repo:acme/api archived:false is:issue is:open sort:updated-desc")
        #expect(searches["outside-open-prs-2"] == "repo:client/app repo:client/web archived:false is:pr is:open sort:updated-desc")
        #expect(searches.count == 6)
    }

    @Test func changesSearchesAreNamedAndSuffixedPerBatch() {
        let batches = [["acme/api"]]
        let searches = GitHubAPI.outsideChangesSearches(batches, timestamp: "2026-01-01T00:00:00+00:00")
        #expect(searches["outside-changed-prs-1"] == "repo:acme/api archived:false is:pr updated:>=2026-01-01T00:00:00+00:00")
        #expect(searches["outside-changed-issues-1"] == "repo:acme/api archived:false is:issue updated:>=2026-01-01T00:00:00+00:00")
        #expect(searches.count == 2)
    }

    @Test func noBatchesGivesNoSearches() {
        #expect(GitHubAPI.outsideFullSearches([], since: "2026-01-01").isEmpty)
        #expect(GitHubAPI.outsideChangesSearches([], timestamp: "2026-01-01T00:00:00+00:00").isEmpty)
    }
}
