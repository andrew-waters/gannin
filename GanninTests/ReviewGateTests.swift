import Foundation
import Testing
@testable import Gannin

/// Whether an automatic review starts now or waits for a review window.
struct ReviewGateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let everyDay: RoutineSchedule.WorkingDays = { _ in true }

    private func window(_ start: Int, _ end: Int, atOnce: Int = 1, org: String = "acme") -> Routine {
        var routine = Routine.new(org: org, harnessRepo: "", kind: .reviewQueue,
                                  schedule: .window(RoutineWindow(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end), days: nil)))
        routine.concurrency = atOnce
        return routine
    }

    private func decide(_ windows: [Routine], at now: Date, running: Int = 0, paused: Bool = false) -> ReviewGate.Decision {
        ReviewGate.decide(now: now, windows: windows, running: running, paused: paused, calendar: calendar, isWorkingDay: everyDay)
    }

    @Test func withNoWindowsReviewsStartAsBefore() {
        #expect(decide([], at: date(2026, 10, 21, 3)) == .start(limit: AutoReview.maxRunning))
        #expect(decide([], at: date(2026, 10, 21, 3), paused: true) == .start(limit: AutoReview.maxRunning))
        var off = window(12, 13)
        off.isEnabled = false
        #expect(decide([off], at: date(2026, 10, 21, 3)) == .start(limit: AutoReview.maxRunning))
    }

    @Test func insideAWindowWithRoomItStarts() {
        let lunch = window(12, 13, atOnce: 2)
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30)) == .start(limit: 2))
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30), running: 1) == .start(limit: 2))
    }

    @Test func outsideEveryWindowItWaits() {
        let windows = [window(12, 13), window(18, 20)]
        #expect(decide(windows, at: date(2026, 10, 21, 9)) == .queue)
        #expect(decide(windows, at: date(2026, 10, 21, 13)) == .queue)
        #expect(decide(windows, at: date(2026, 10, 21, 19)) == .start(limit: 1))
    }

    @Test func aWindowPastMidnightIsOpenTheNextMorning() {
        let night = window(22, 6)
        #expect(decide([night], at: date(2026, 10, 21, 23)) == .start(limit: 1))
        #expect(decide([night], at: date(2026, 10, 22, 5, 59)) == .start(limit: 1))
        #expect(decide([night], at: date(2026, 10, 22, 6)) == .queue)
    }

    @Test func reviewsRunningInAnyOrgFillTheWindow() {
        // `running` counts every automatic review on the Mac, so another
        // org's review takes this window's only place.
        let lunch = window(12, 13)
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30), running: 1) == .queue)
        // Overlapping windows don't add up: the roomiest open one decides.
        let wide = window(11, 14, atOnce: 2)
        #expect(decide([lunch, wide], at: date(2026, 10, 21, 12, 30), running: 1) == .start(limit: 2))
        #expect(decide([lunch, wide], at: date(2026, 10, 21, 12, 30), running: 2) == .queue)
    }

    @Test func whilePausedItWaitsEvenInAWindow() {
        #expect(decide([window(12, 13)], at: date(2026, 10, 21, 12, 30), paused: true) == .queue)
    }
}
