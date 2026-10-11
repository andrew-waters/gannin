import Foundation
import Testing
@testable import Gannin

struct BackgroundFetchTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func neverFetchedIsDue() {
        #expect(BackgroundFetch.isDue(lastFetched: nil, now: now))
    }

    @Test func recentFetchIsNotDue() {
        #expect(!BackgroundFetch.isDue(lastFetched: now.addingTimeInterval(-60), now: now))
    }

    @Test func fetchJustUnderTheIntervalIsDue() {
        #expect(BackgroundFetch.isDue(lastFetched: now.addingTimeInterval(-295), now: now))
    }

    @Test func fetchOlderThanTheIntervalIsDue() {
        #expect(BackgroundFetch.isDue(lastFetched: now.addingTimeInterval(-400), now: now))
    }
}
