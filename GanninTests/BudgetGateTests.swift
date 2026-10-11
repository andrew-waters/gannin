import Foundation
import Testing
@testable import Gannin

@MainActor
struct BudgetGateTests {
    @Test func doesNotHoldOffWithBudgetToSpend() {
        let auth = AuthStore()
        #expect(!auth.holdsOff())
        #expect(!auth.holdsOff(rest: true))
    }

    @Test func fetchesWhatHasNeverBeenFetched() {
        #expect(AuthStore().shouldFetch(.workload, since: nil))
    }

    @Test func waitsOutAnIntervalThatHasNotPassed() {
        #expect(!AuthStore().shouldFetch(.workload, since: .now))
    }

    @Test func forceFetchesBeforeTheIntervalIsUp() {
        #expect(AuthStore().shouldFetch(.workload, since: .now, force: true))
    }

    @Test func fetchesOnceTheIntervalHasPassed() {
        let longAgo = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(AuthStore().shouldFetch(.workload, since: longAgo))
    }
}
