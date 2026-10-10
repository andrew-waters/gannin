import Foundation
import Testing
@testable import Gannin

/// Routine schedules: the pickers' kinds, cron expressions and the next
/// times each gives.
struct RoutineScheduleTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // Friday 9 October 2026, 10:30.
    private var now: Date { date(2026, 10, 9, 10, 30) }

    private var weekdays: RoutineSchedule.WorkingDays {
        { [calendar] in !calendar.isDateInWeekend($0) }
    }

    @Test func everyNMinutesFromItsAnchor() {
        let schedule = RoutineSchedule.every(minutes: 45, anchor: date(2026, 10, 9))
        #expect(schedule.nextTimes(after: now, count: 3, calendar: calendar) == [date(2026, 10, 9, 11, 15), date(2026, 10, 9, 12, 0), date(2026, 10, 9, 12, 45)])
        // Never the time itself.
        #expect(schedule.nextTimes(after: date(2026, 10, 9, 11, 15), count: 1, calendar: calendar) == [date(2026, 10, 9, 12, 0)])
        // Before the anchor, the anchor first.
        #expect(schedule.nextTimes(after: date(2026, 10, 8), count: 1, calendar: calendar) == [date(2026, 10, 9)])
    }

    @Test func dailyWorkingDaysAndWeekly() {
        let nine = TimeOfDay(hour: 9)
        #expect(RoutineSchedule.daily(nine).nextTimes(after: now, count: 2, calendar: calendar) == [date(2026, 10, 10, 9), date(2026, 10, 11, 9)])
        // Friday after nine: Monday, then Tuesday.
        #expect(RoutineSchedule.workingDays(nine).nextTimes(after: now, count: 2, calendar: calendar, isWorkingDay: weekdays) == [date(2026, 10, 12, 9), date(2026, 10, 13, 9)])
        // A bank holiday on Monday is skipped.
        let holiday = date(2026, 10, 12)
        let less: RoutineSchedule.WorkingDays = { [calendar] day in !calendar.isDateInWeekend(day) && !calendar.isDate(day, inSameDayAs: holiday) }
        #expect(RoutineSchedule.workingDays(nine).nextTimes(after: now, count: 1, calendar: calendar, isWorkingDay: less) == [date(2026, 10, 13, 9)])
        // Wednesdays (4) at 14:30.
        #expect(RoutineSchedule.weekly(weekday: 4, TimeOfDay(hour: 14, minute: 30)).nextTimes(after: now, count: 2, calendar: calendar)
            == [date(2026, 10, 14, 14, 30), date(2026, 10, 21, 14, 30)])
    }

    @Test func onceRunsOnlyBeforeItsTime() {
        let at = date(2026, 10, 9, 18)
        #expect(RoutineSchedule.once(at).nextTimes(after: now, count: 5, calendar: calendar) == [at])
        #expect(RoutineSchedule.once(at).nextTimes(after: at, count: 5, calendar: calendar).isEmpty)
        #expect(RoutineSchedule.once(now).problem(now: now) == "That time has passed.")
    }

    @Test func timesThrough() {
        let schedule = RoutineSchedule.every(minutes: 60, anchor: date(2026, 10, 9))
        let times = schedule.times(after: date(2026, 10, 9, 1, 30), through: date(2026, 10, 9, 5), calendar: calendar)
        #expect(times == [date(2026, 10, 9, 2), date(2026, 10, 9, 3), date(2026, 10, 9, 4), date(2026, 10, 9, 5)])
        // More than one batch.
        let minutely = RoutineSchedule.every(minutes: 1, anchor: date(2026, 10, 9))
        #expect(minutely.times(after: date(2026, 10, 9), through: date(2026, 10, 9, 5), calendar: calendar).count == 300)
        #expect(minutely.times(after: date(2026, 10, 9), through: date(2026, 10, 9, 5), limit: 7, calendar: calendar).count == 7)
    }

    @Test func windowsOpenAndCrossMidnight() {
        let evenings = RoutineSchedule.window(RoutineWindow(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 8), days: nil))
        // Friday evening opens; Saturday's doesn't, but Friday's runs on to 08:00.
        #expect(evenings.isOpen(at: date(2026, 10, 9, 19), calendar: calendar, isWorkingDay: weekdays))
        #expect(evenings.isOpen(at: date(2026, 10, 10, 7, 59), calendar: calendar, isWorkingDay: weekdays))
        #expect(!evenings.isOpen(at: date(2026, 10, 10, 8), calendar: calendar, isWorkingDay: weekdays))
        #expect(!evenings.isOpen(at: date(2026, 10, 10, 19), calendar: calendar, isWorkingDay: weekdays))
        #expect(!evenings.isOpen(at: date(2026, 10, 11, 7), calendar: calendar, isWorkingDay: weekdays))
        #expect(!evenings.isOpen(at: now, calendar: calendar, isWorkingDay: weekdays))
        // Its times are when it opens.
        #expect(evenings.nextTimes(after: now, count: 2, calendar: calendar, isWorkingDay: weekdays) == [date(2026, 10, 9, 18), date(2026, 10, 12, 18)])

        let lunch = RoutineSchedule.window(RoutineWindow(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13), days: [7]))
        #expect(lunch.isOpen(at: date(2026, 10, 10, 12, 30), calendar: calendar))
        #expect(!lunch.isOpen(at: date(2026, 10, 9, 12, 30), calendar: calendar))
        #expect(RoutineSchedule.window(RoutineWindow(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 9), days: nil)).problem() != nil)
        #expect(RoutineSchedule.window(RoutineWindow(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10), days: [])).problem() == "Pick at least one day.")
    }

    @Test func cronFields() throws {
        let expression = try CronExpression("*/15 9-17 * * mon-fri")
        #expect(expression.minutes == [0, 15, 30, 45])
        #expect(expression.hours == Set(9...17))
        #expect(expression.weekdays == [1, 2, 3, 4, 5])
        #expect(try CronExpression("5/20 0 1,15 jan,JUL 7").minutes == [5, 25, 45])
        #expect(try CronExpression("0 0 * * 7").weekdays == [0])
        #expect(try CronExpression("0-30/10 * * * *").minutes == [0, 10, 20, 30])
        #expect(try CronExpression("@daily") == CronExpression("0 0 * * *"))
    }

    @Test func cronNextTimes() throws {
        // Weekdays at 09:00 from Friday 10:30: Monday and Tuesday.
        #expect(RoutineSchedule.cron("0 9 * * 1-5").nextTimes(after: now, count: 2, calendar: calendar) == [date(2026, 10, 12, 9), date(2026, 10, 13, 9)])
        // Both day fields restricted: either runs (the 13th, or any Friday).
        #expect(try CronExpression("0 12 13 * 5").nextTimes(after: now, count: 3, calendar: calendar)
            == [date(2026, 10, 9, 12), date(2026, 10, 13, 12), date(2026, 10, 16, 12)])
        // One restricted: only it counts (the next 13th).
        #expect(try CronExpression("0 12 13 * *").nextTimes(after: now, count: 1, calendar: calendar) == [date(2026, 10, 13, 12)])
        #expect(try CronExpression("0 0 29 2 *").nextTimes(after: now, count: 1, calendar: calendar) == [date(2028, 2, 29)])
        #expect(try CronExpression("*/30 * * * *").nextTimes(after: now, count: 3, calendar: calendar)
            == [date(2026, 10, 9, 11), date(2026, 10, 9, 11, 30), date(2026, 10, 9, 12)])
    }

    @Test func invalidCronIsRefusedWithTheReason() {
        func reason(_ text: String) -> String? { RoutineSchedule.cron(text).problem(now: now) }
        #expect(reason("0 9 * *")?.contains("five fields") == true)
        #expect(reason("60 9 * * *") == "60 is out of range for the minute (0 to 59).")
        #expect(reason("0 9 * * funday") == "\"funday\" isn't a valid day of the week.")
        #expect(reason("0 17-9 * * *") == "The range 17-9 in the hour runs backwards.")
        #expect(reason("*/0 * * * *") == "\"0\" isn't a valid step for the minute.")
        #expect(reason("0 0 31 2 *") == "It never comes round in the next eight years.")
        #expect(reason("@sometimes")?.contains("@hourly") == true)
        #expect(reason("") != nil)
        #expect(reason("0 9 * * 1-5") == nil)
    }

    @Test func summaries() {
        #expect(RoutineSchedule.every(minutes: 120, anchor: now).summary == "Every 2 hours")
        #expect(RoutineSchedule.every(minutes: 15, anchor: now).summary == "Every 15 minutes")
        #expect(RoutineSchedule.workingDays(TimeOfDay(hour: 9, minute: 5)).summary == "Working days at 09:05")
        #expect(RoutineSchedule.cron("0 9 * * 1").summary == "Cron 0 9 * * 1")
        #expect(RoutineSchedule.daysLabel([2, 4]) == "\(WorkWeek.name(2)), \(WorkWeek.name(4))")
    }
}
