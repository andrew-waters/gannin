import Foundation
import Testing
@testable import Gannin

/// The sessions window's tabs are one stored order, shown as active work
/// then reviews.
@MainActor
struct SessionTabGroupsTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "SessionTabGroupsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func store() -> SessionStore {
        SessionStore(harness: HarnessStore(auth: AuthStore()), directory: folder, saveDelay: .seconds(60))
    }

    private func clean() {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removeObject(forKey: SessionStore.tabsKey)
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
        session.reviewOf = PullRequestReference(org: "acme", id: "PR_\(number)", number: number, title: "PR \(number)", repo: "acme/app",
                                                url: URL(string: "https://github.com/acme/app/pull/\(number)")!)
        return session
    }

    private func open(_ sessions: [CodeSession], in store: SessionStore) {
        for session in sessions {
            store.add(session)
            store.reveal(session.id)
        }
    }

    @Test func partitionKeepsRelativeOrder() {
        defer { clean() }
        let live = store()
        let (w1, r1, w2, r2) = (work(1), review(2), work(3), review(4))
        for session in [w1, r1, w2, r2] { live.add(session); live.addTab(session.id, after: nil) }
        #expect(live.tabGroups.work == [w1.id, w2.id])
        #expect(live.tabGroups.reviews == [r1.id, r2.id])
        #expect(live.displayedTabs == [w1.id, w2.id, r1.id, r2.id])
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
        UserDefaults.standard.set([r1, w1, r2, w2].map(\.id.uuidString), forKey: SessionStore.tabsKey)
        #expect(store().tabs == [w1.id, w2.id, r1.id, r2.id])
    }
}
