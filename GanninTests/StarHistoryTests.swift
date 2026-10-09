import Foundation
import Testing
@testable import Gannin

/// Star histories: stargazers kept newest first without repeats, and new
/// stars counted by week or month with quiet spells as zero.
struct StarHistoryTests {
    private func day(_ text: String) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        return Calendar.metrics.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    private func star(_ login: String, _ date: String) -> Stargazer {
        Stargazer(login: login, name: nil, avatarURL: nil, company: nil, location: nil, followers: 0, starredAt: day(date))
    }

    private func add(_ stars: [Stargazer], unknown: [String] = [], to history: inout StarHistory) {
        history.add(stars.map(\.starredAt) + unknown.map(day), stargazers: stars)
    }

    @Test func addingKeepsStargazersNewestFirstAndCountsDays() {
        var history = StarHistory(days: [], newest: nil, before: 0, stargazers: [])
        add([star("a", "2026-10-01"), star("b", "2026-10-03")], to: &history)
        add([star("c", "2026-10-05"), star("b", "2026-10-04")], to: &history)
        #expect(history.stargazers.map(\.login) == ["c", "b", "a"])
        #expect(history.stargazers[1].starredAt == day("2026-10-04"))
        #expect(history.newest == day("2026-10-05"))
        #expect(history.days.count == 4)
    }

    @Test func undescribedAccountsCountButAreNotListed() {
        var history = StarHistory(days: [], newest: nil, before: 0, stargazers: [])
        add([star("a", "2026-10-01")], unknown: ["2026-10-02", "2026-10-02"], to: &history)
        #expect(history.stargazers.map(\.login) == ["a"])
        #expect(history.days.reduce(0) { $0 + $1.count } == 3)
    }

    @Test func newStarsByWeekStartOnMondayWithEmptyWeeks() {
        // Thursday 1 Oct, then Wednesday 21 Oct: the week of 12 Oct had none.
        let perDay = [
            Calendar.metrics.startOfDay(for: day("2026-10-01")): 2,
            Calendar.metrics.startOfDay(for: day("2026-10-02")): 1,
            Calendar.metrics.startOfDay(for: day("2026-10-21")): 4,
        ]
        let points = ReleaseUsage.newStars(perDay, bucket: .week)
        #expect(points.map(\.value) == [3, 0, 0, 4])
        #expect(points.first?.date == Calendar.metrics.startOfDay(for: day("2026-09-28")))
    }

    @Test func newStarsByMonth() {
        let perDay = [
            Calendar.metrics.startOfDay(for: day("2026-07-15")): 1,
            Calendar.metrics.startOfDay(for: day("2026-09-02")): 5,
        ]
        #expect(ReleaseUsage.newStars(perDay, bucket: .month).map(\.value) == [1, 0, 5])
    }
}
