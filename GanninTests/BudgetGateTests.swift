import Foundation
import Testing
@testable import Gannin

@MainActor
struct BudgetGateTests {
    private static let low = RateLimit(cost: 1, remaining: 0, limit: 5000, resetAt: .now.addingTimeInterval(3600))

    @Test func doesNotHoldOffWithBudgetToSpend() {
        let auth = AuthStore()
        #expect(!auth.shouldWaitForBudget())
        #expect(!auth.shouldWaitForBudget(rest: true))
    }

    @Test func waitsForTheBudgetWhenLow() {
        let auth = AuthStore()
        auth.setBudgetForTesting(rateLimit: Self.low)
        #expect(auth.shouldWaitForBudget())
    }

    @Test func waitsOutARefusalEvenWithBudgetLeft() {
        let auth = AuthStore()
        auth.setBudgetForTesting(pausedUntil: .now.addingTimeInterval(60))
        #expect(auth.shouldWaitForBudget())
    }

    @Test func forceIgnoresALowBudget() {
        let auth = AuthStore()
        auth.setBudgetForTesting(rateLimit: Self.low)
        #expect(!auth.shouldWaitForBudget(force: true))
    }

    @Test func noDataIgnoresALowBudget() {
        let auth = AuthStore()
        auth.setBudgetForTesting(rateLimit: Self.low)
        #expect(!auth.shouldWaitForBudget(hasData: false))
    }

    @Test func restCountsTheRESTBudgetOnlyWhenAsked() {
        let auth = AuthStore()
        auth.setBudgetForTesting(restRateLimit: Self.low)
        #expect(!auth.shouldWaitForBudget())
        #expect(auth.shouldWaitForBudget(rest: true))
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

    @Test func shouldFetchWaitsOutALowBudgetOnceDue() {
        let auth = AuthStore()
        auth.setBudgetForTesting(rateLimit: Self.low)
        let longAgo = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(!auth.shouldFetch(.workload, since: longAgo))
    }
}
