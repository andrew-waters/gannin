import Foundation
import Testing
@testable import Gannin

/// The scheduler's decisions: what runs, what was missed, what was skipped
/// while paused, and how many queued issues a window may start.
struct RoutineSchedulerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private let everyDay: RoutineSchedule.WorkingDays = { _ in true }

    private func routine(_ schedule: RoutineSchedule, kind: RoutineKind = .report, created: Date? = nil) -> Routine {
        Routine.new(org: "acme", harnessRepo: "acme/harness", kind: kind, schedule: schedule, now: created ?? date(2026, 1, 1))
    }

    @Test func runsATimeJustPassed() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 9, 59, 50), now: date(2026, 10, 9, 10, 0, 5), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init(due: date(2026, 10, 9, 10)))
        // Nothing due between ticks.
        let quiet = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 10, 0, 5), now: date(2026, 10, 9, 10, 0, 20), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(quiet == .init())
    }

    @Test func timesWhileClosedOrAsleepAreMissed() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        // Closed from 18:30 to 09:10 the next morning.
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 18, 30), now: date(2026, 10, 10, 9, 10), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan.due == nil)
        #expect(plan.missed.count == 15)
        #expect(plan.missed.first == date(2026, 10, 9, 19))
        #expect(plan.missed.last == date(2026, 10, 10, 9))
        // Back within the grace of the last one: it runs, the rest are missed.
        let back = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 18, 30), now: date(2026, 10, 10, 9, 1), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(back.due == date(2026, 10, 10, 9))
        #expect(back.missed.count == 14)
    }

    @Test func pausedTimesAreSkipped() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 9, 59), now: date(2026, 10, 9, 10, 0, 10), paused: true, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init(skipped: [date(2026, 10, 9, 10)]))
    }

    @Test func nothingFromBeforeItWasMadeOrWhileOff() {
        let made = date(2026, 10, 9, 9, 30)
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)), created: made)
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 8), now: date(2026, 10, 9, 9, 35), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init())
        var off = hourly
        off.isEnabled = false
        #expect(RoutineScheduler.plan(off, since: date(2026, 10, 9, 9, 59), now: date(2026, 10, 9, 10, 0, 10), paused: false, calendar: calendar, isWorkingDay: everyDay) == .init())
    }

    @Test func windowsHaveNoTimesButFreeSlots() {
        var window = routine(.window(RoutineWindow(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 8), days: nil)), kind: .issueQueue)
        window.concurrency = 2
        let evening = date(2026, 10, 9, 19)
        #expect(RoutineScheduler.plan(window, since: date(2026, 10, 9, 17, 59), now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == .init())
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 2)
        #expect(RoutineScheduler.freeSlots(window, active: 1, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 1)
        #expect(RoutineScheduler.freeSlots(window, active: 3, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 0)
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: evening, paused: true, calendar: calendar, isWorkingDay: everyDay) == 0)
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: date(2026, 10, 9, 12), paused: false, calendar: calendar, isWorkingDay: everyDay) == 0)
    }

    @Test func checkRecordsGapsAndStarts() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoutineSchedulerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = RoutineStore(directory: folder)
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        store.save(hourly)
        store.checked(at: date(2026, 10, 9, 6, 30))
        let scheduler = RoutineScheduler(store: store)
        var started: [UUID] = []
        scheduler.start = { routine, _, _ in
            started.append(routine.id)
            return .started(session: UUID())
        }
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 30))
        #expect(started == [hourly.id])
        let runs = store.runs(for: hourly.id)
        #expect(runs.count == 2)
        #expect(runs.first?.outcome == .running)
        #expect(runs.first?.session != nil)
        #expect(runs.last?.outcome == .missed)
        #expect(runs.last?.count == 3)

        // A queue window drains one at a time up to its limit, taking each off.
        var window = routine(.window(RoutineWindow(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17), days: Set(1...7))), kind: .issueQueue)
        window.concurrency = 2
        store.save(window)
        for number in 1...3 {
            store.enqueue(IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                                         url: URL(string: "https://github.com/acme/app/issues/\(number)")!))
        }
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 45))
        #expect(store.runs(for: window.id).compactMap(\.issue?.number).sorted() == [1, 2])
        #expect(store.queue(for: "acme").map(\.issue.number) == [3])
    }
}
