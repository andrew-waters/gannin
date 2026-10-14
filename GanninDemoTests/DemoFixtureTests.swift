import Foundation
import Testing
@testable import Gannin_Demo

/// Everything the demo shows is from the fixture's invented list, and
/// there's enough of it that no screenshot is an empty state.
@MainActor
struct DemoFixtureTests {
    private var snapshot: OrgSnapshot { DemoFixture.snapshot }

    @Test func everyoneIsInvented() {
        var seen: Set<String> = []
        for pr in snapshot.openPullRequests {
            seen.formUnion([pr.author?.login].compactMap(\.self) + pr.assignees.map(\.login) + pr.reviewers.map(\.login)
                + pr.requestedReviewers.map(\.login) + Array((pr.reviewStates ?? [:]).keys))
        }
        for issue in snapshot.issues { seen.formUnion([issue.author?.login].compactMap(\.self) + issue.assignees.map(\.login)) }
        for pr in DemoFixture.mergedPullRequests {
            seen.formUnion([pr.author?.login].compactMap(\.self) + pr.reviews.map(\.login) + pr.reviewRequests.map(\.login))
        }
        for detail in DemoFixture.details.values { seen.formUnion(detail.recentComments.compactMap(\.author?.login)) }
        seen.formUnion(snapshot.members.map(\.login) + snapshot.teams.flatMap(\.members))
        #expect(seen.subtracting(DemoFixture.logins).isEmpty)
        #expect(DemoFixture.viewer.login == DemoFixture.people[0].login)
    }

    @Test func everyRepoIsInvented() {
        let repos = snapshot.openPullRequests.map(\.repo) + snapshot.issues.map(\.repo) + DemoFixture.mergedPullRequests.map(\.repo)
        #expect(Set(repos).isSubset(of: DemoFixture.repos))
        #expect(DemoFixture.repos.allSatisfy { $0.hasPrefix("\(DemoFixture.org)/") })
    }

    /// Drawn here, never loaded from GitHub.
    @Test func avatarsAreLocal() {
        let urls = snapshot.members.compactMap(\.avatarUrl) + [DemoFixture.organisation.avatarUrl, DemoFixture.viewer.avatarUrl].compactMap(\.self)
        #expect(!urls.isEmpty)
        #expect(urls.allSatisfy { $0.isFileURL })
    }

    @Test func enoughForEveryShot() throws {
        #expect(snapshot.openPullRequests.count >= 8)
        #expect(Set(snapshot.openPullRequests.compactMap(\.review)).count == 3)
        #expect(snapshot.issues.contains { $0.assignees.isEmpty })
        #expect(DemoFixture.mergedPullRequests.count >= 40)
        // The window and the period before it, for the PR flow's comparisons.
        let history = DemoFixture.metricsHistory
        #expect(history.coveredFrom <= Date.now.addingTimeInterval(-61 * 24 * 60 * 60))
        let detail = try #require(DemoFixture.details[DemoFixture.featured.id])
        #expect(!detail.body.isEmpty && !detail.recentComments.isEmpty)
    }

    /// The launch's seeding lands where the stores read it.
    @Test func storesLoadTheSeed() {
        let auth = AuthStore()
        #expect(OrgSnapshotCache().load(DemoFixture.org)?.openPullRequests.count == DemoFixture.openPullRequests.count)
        #expect(DetailStore(auth: auth).detail(for: DemoFixture.featured.id) != nil)
        let metrics = MetricsStore(auth: auth, activity: SyncActivity())
        metrics.loadCached(DemoFixture.org)
        #expect(metrics.history(for: DemoFixture.org)?.pullRequests.count == DemoFixture.mergedPullRequests.count)
    }
}
