import Foundation
import Testing
@testable import Gannin

/// The sessions window's tabs are one stored order, shown as active work
/// then reviews.
@MainActor
struct SessionTabGroupsTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "SessionTabGroupsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private let suite = "SessionTabGroupsTests-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func store() -> SessionStore {
        SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60), defaults: defaults)
    }

    private func clean() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }

    private func pullRequest(_ number: Int) -> PullRequestReference {
        PullRequestReference(org: "acme", id: "PR_\(number)", number: number, title: "PR \(number)", repo: "acme/app",
                             url: URL(string: "https://github.com/acme/app/pull/\(number)")!)
    }

    private func issue(_ number: Int) -> IssueReference {
        IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                       url: URL(string: "https://github.com/acme/app/issues/\(number)")!)
    }

    private func work(_ number: Int, parent: UUID? = nil) -> CodeSession {
        var session = CodeSession(id: UUID(), issue: issue(number), repo: "acme/harness", branch: "b\(number)", createdAt: .now,
                                  harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness")
        session.parentID = parent
        return session
    }

    private func review(_ number: Int, parent: UUID? = nil) -> CodeSession {
        var session = work(number, parent: parent)
        session.reviewOf = pullRequest(number)
        return session
    }

    private func open(_ sessions: [CodeSession], in store: SessionStore) {
        for session in sessions {
            store.add(session)
            store.reveal(session.id)
        }
    }

    @Test func partitionKeepsRelativeOrderOnAMixedList() {
        defer { clean() }
        let live = store()
        let sessions = (1...6).map { work($0) }
        for session in sessions { live.add(session); live.addTab(session.id, after: nil) }
        // Reviews 2, 4 and 6 are work tabs that became reviews in place, so
        // the stored list is mixed.
        for index in [1, 3, 5] { live.update(sessions[index].id) { $0.reviewOf = pullRequest(index) } }
        #expect(live.tabs == sessions.map(\.id))
        #expect(live.tabGroups.work == [0, 2, 4].map { sessions[$0].id })
        #expect(live.tabGroups.reviews == [1, 3, 5].map { sessions[$0].id })
        #expect(live.displayedTabs == [0, 2, 4, 1, 3, 5].map { sessions[$0].id })
    }

    @Test func workReplacingAMissingDraftWhileReviewSelectedStaysInWork() {
        defer { clean() }
        let live = store()
        let (w1, r1, w2) = (work(1), review(2), work(3))
        open([w1, r1], in: live)
        live.add(w2)
        live.replaceDraft(UUID(), with: w2.id)
        #expect(live.tabs == [w1.id, w2.id, r1.id])
    }

    @Test func reviewHelperStaysInItsOwnersGroup() {
        defer { clean() }
        let live = store()
        let owner = work(1)
        let helper = review(2, parent: owner.id)
        open([owner], in: live)
        live.add(helper)
        live.reveal(helper.id)
        #expect(live.tabs == [owner.id])
        #expect(live.tabGroups.work == [owner.id])
        #expect(live.tabGroups.reviews.isEmpty)
    }

    @Test func reviewOpenedWhileWorkIsSelectedLandsAtEndOfReviews() {
        defer { clean() }
        let live = store()
        let (w1, r1, w2, r2) = (work(1), review(2), work(3), review(4))
        open([w1, r1, w2], in: live)
        live.reveal(w1.id)
        live.add(r2)
        live.reveal(r2.id)
        #expect(live.tabs == [w1.id, w2.id, r1.id, r2.id])
    }

    @Test func workOpenedWhileReviewIsSelectedLandsAtEndOfWork() {
        defer { clean() }
        let live = store()
        let (w1, r1, w2, w3) = (work(1), review(2), work(3), work(4))
        open([w1, w2, r1], in: live)
        live.reveal(r1.id)
        live.add(w3)
        live.reveal(w3.id)
        #expect(live.tabs == [w1, w2, w3, r1].map(\.id))
    }

    @Test func tabOpenedAfterSelectedTabInSameGroup() {
        defer { clean() }
        let live = store()
        let (w1, w2, w3) = (work(1), work(2), work(3))
        open([w1, w2], in: live)
        live.reveal(w1.id)
        live.add(w3)
        live.reveal(w3.id)
        #expect(live.tabs == [w1.id, w3.id, w2.id])
    }

    @Test func crossGroupMoveLeavesTabsUnchanged() {
        defer { clean() }
        let live = store()
        let (w1, w2, r1) = (work(1), work(2), review(3))
        open([w1, w2, r1], in: live)
        let before = live.tabs
        live.moveTab(w1.id, to: r1.id)
        live.moveTab(r1.id, to: w1.id)
        #expect(live.tabs == before)
        live.moveTab(w1.id, to: w2.id)
        #expect(live.tabs == [w2.id, w1.id, r1.id])
    }

    @Test func nextAndPreviousCrossTheDivider() {
        defer { clean() }
        let live = store()
        let (w1, r1, w2) = (work(1), review(2), work(3))
        open([w1, r1, w2], in: live)
        live.selectedTab = w2.id
        live.selectTab(offset: 1)
        #expect(live.selectedTab == r1.id)
        live.selectTab(offset: 1)
        #expect(live.selectedTab == w1.id)
        live.selectTab(offset: -1)
        #expect(live.selectedTab == r1.id)
    }

    @Test func mixedFlatListRestoresGrouped() {
        defer { clean() }
        let first = store()
        let (w1, r1, w2, r2) = (work(1), review(2), work(3), review(4))
        for session in [w1, r1, w2, r2] { first.add(session) }
        defaults.set([r1, w1, r2, w2].map(\.id.uuidString), forKey: SessionStore.tabsKey)
        #expect(store().tabs == [w1.id, w2.id, r1.id, r2.id])
    }

    @Test func openingShowsTheReviewerOnlyWhileItIsAsking() {
        defer { clean() }
        let live = store()
        let owner = work(1)
        var reviewer = work(1, parent: owner.id)
        reviewer.isReviewer = true
        var tester = work(1, parent: owner.id)
        tester.role = "Tests"
        live.add(owner)
        #expect(live.opening(owner.id) { _ in true } == owner.id)
        live.add(tester)
        #expect(live.opening(owner.id) { _ in true } == owner.id)
        live.add(reviewer)
        #expect(live.opening(owner.id) { _ in false } == owner.id)
        #expect(live.opening(owner.id) { $0.id == reviewer.id } == reviewer.id)
    }

    @Test func revealingTheOwnerShowsItsAskingReviewerButAHelperIdIsKept() {
        defer { clean() }
        let live = store()
        let owner = work(1)
        var reviewer = work(1, parent: owner.id)
        reviewer.isReviewer = true
        live.add(owner)
        live.add(reviewer)
        // Nothing is running, so nothing is asking: the owner shows.
        live.reveal(owner.id)
        #expect(live.selectedTab == owner.id)
        live.reveal(reviewer.id)
        #expect(live.selectedTab == reviewer.id)
    }
}
