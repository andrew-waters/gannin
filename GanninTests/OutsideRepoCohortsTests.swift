import Foundation
import Testing
@testable import Gannin

/// Splitting outside repos into those needing a full search and those
/// that can trust a changes-only one, so a repo a project just added
/// isn't limited to "updated since" results with no baseline to build on.
struct OutsideRepoCohortsTests {
    @Test func aBrandNewRepoNeedsAFullSearch() {
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts(["client/app"], priorFetched: [], priorUnreadable: [])
        #expect(searchable == ["client/app"])
        #expect(new == ["client/app"])
        #expect(known.isEmpty)
    }

    @Test func aPreviouslyFetchedRepoTrustsAChangesSearch() {
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts(["client/app"], priorFetched: ["client/app"], priorUnreadable: [])
        #expect(searchable == ["client/app"])
        #expect(new.isEmpty)
        #expect(known == ["client/app"])
    }

    @Test func aMixOfNewAndKnownRepos() {
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts(
            ["client/app", "other/thing"], priorFetched: ["client/app"], priorUnreadable: []
        )
        #expect(searchable == ["client/app", "other/thing"])
        #expect(new == ["other/thing"])
        #expect(known == ["client/app"])
    }

    @Test func anUnreadableRepoIsLeftOutOfSearchableEntirely() {
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts(
            ["client/app"], priorFetched: ["client/app"], priorUnreadable: ["client/app"]
        )
        #expect(searchable.isEmpty)
        #expect(new.isEmpty)
        #expect(known.isEmpty)
    }

    @Test func aCurrentlyUnreadableRepoDoesntCountAsFetchedEitherWay() {
        // client/app was fetched before but is unreadable this cycle, so
        // it's excluded entirely rather than counted as new or known;
        // other/thing, also fetched before and still readable, stays known.
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts(
            ["client/app", "other/thing"], priorFetched: ["client/app", "other/thing"], priorUnreadable: ["client/app"]
        )
        #expect(searchable == ["other/thing"])
        #expect(new.isEmpty)
        #expect(known == ["other/thing"])
    }

    @Test func onceRecoveredANewSnapshotWithNoFetchHistoryNeedsAFullSearch() {
        // outsideReposFetched self-prunes to what was searchable each
        // cycle, so a repo excluded while unreadable drops out of it; once
        // readable again, the next snapshot's priorFetched won't mention
        // it, and it's treated as new.
        let (_, new, known) = GitHubAPI.outsideRepoCohorts(["client/app"], priorFetched: [], priorUnreadable: [])
        #expect(new == ["client/app"])
        #expect(known.isEmpty)
    }

    @Test func noOutsideReposGivesEmptyCohorts() {
        let (searchable, new, known) = GitHubAPI.outsideRepoCohorts([], priorFetched: [], priorUnreadable: [])
        #expect(searchable.isEmpty)
        #expect(new.isEmpty)
        #expect(known.isEmpty)
    }
}
