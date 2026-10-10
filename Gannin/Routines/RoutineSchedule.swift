import Foundation

/// A time of day, in this Mac's time zone.
struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    var minutes: Int { hour * 60 + minute }

    /// "09:00".
    var label: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutes < rhs.minutes }

    /// The moment it falls on the day of `day`. In a daylight saving gap,
    /// the hour after.
    func on(_ day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }
}

/// When a queue drains: from `start` to `end` (running past midnight when
/// `end` is earlier), on the days it opens.
struct RoutineWindow: Codable, Hashable {
    var start: TimeOfDay
    var end: TimeOfDay
    /// `Calendar` weekdays it opens on, 1 for Sunday; nil for the org's
    /// working days, less its bank holidays.
    var days: Set<Int>?

    var crossesMidnight: Bool { end <= start }
}

/// When a routine runs. One `nextTimes(after:count:)` for every kind, so
/// the scheduler, the editor's next five and the list's next run agree.
enum RoutineSchedule: Codable, Hashable {
    /// Every `minutes` from `anchor` (the day it was set, at midnight, so
    /// hourly runs are on the hour).
    case every(minutes: Int, anchor: Date)
    case daily(TimeOfDay)
    /// The org's working days, less its bank holidays.
    case workingDays(TimeOfDay)
    /// `weekday` as `Calendar` numbers it, 1 for Sunday.
    case weekly(weekday: Int, TimeOfDay)
    /// A five-field cron expression (`CronExpression`).
    case cron(String)
    /// Once, for an issue pinned to a time.
    case once(Date)
    /// A queue's window: its times are when it opens.
    case window(RoutineWindow)

    /// Whether a day counts as a working day: the org's working week less
    /// its bank holidays (`WorkingCalendar.isWorkingDay`).
    typealias WorkingDays = (Date) -> Bool

    static let everyWeekday: WorkingDays = { Calendar.current.isDateInWeekend($0) == false }

    /// The next `count` times after `date` (never `date` itself), soonest
    /// first. Fewer when the schedule ends (a time passed) or a cron
    /// expression is invalid or matches nothing within eight years.
    func nextTimes(after date: Date, count: Int, calendar: Calendar = .current, isWorkingDay: WorkingDays = everyWeekday) -> [Date] {
        guard count > 0 else { return [] }
        switch self {
        case .every(let minutes, let anchor):
            guard minutes > 0 else { return [] }
            let step = TimeInterval(minutes * 60)
            let passed = date.timeIntervalSince(anchor)
            let first = passed < 0 ? 0 : floor(passed / step) + 1
            return (0..<count).map { anchor.addingTimeInterval((first + Double($0)) * step) }
        case .daily(let time):
            return Self.days(after: date, count: count, at: time, calendar: calendar) { _ in true }
        case .workingDays(let time):
            return Self.days(after: date, count: count, at: time, calendar: calendar, matching: isWorkingDay)
        case .weekly(let weekday, let time):
            return Self.days(after: date, count: count, at: time, calendar: calendar) { calendar.component(.weekday, from: $0) == weekday }
        case .cron(let text):
            return (try? CronExpression(text))?.nextTimes(after: date, count: count, calendar: calendar) ?? []
        case .once(let at):
            return at > date ? [at] : []
        case .window(let window):
            return Self.days(after: date, count: count, at: window.start, calendar: calendar) { day in
                window.days.map { $0.contains(calendar.component(.weekday, from: day)) } ?? isWorkingDay(day)
            }
        }
    }

    /// Every time after `start` up to and including `end`, at most `limit`
    /// (the earliest), for working out what was due or missed.
    func times(after start: Date, through end: Date, limit: Int = 10_000, calendar: Calendar = .current, isWorkingDay: WorkingDays = everyWeekday) -> [Date] {
        var times: [Date] = []
        var cursor = start
        while times.count < limit {
            let batch = nextTimes(after: cursor, count: 100, calendar: calendar, isWorkingDay: isWorkingDay)
            guard let last = batch.last else { break }
            for time in batch {
                guard time <= end, times.count < limit else { return times }
                times.append(time)
            }
            cursor = last
        }
        return times
    }

    /// Whether a queue's window is open at `date`: inside today's, or in
    /// yesterday's when it runs past midnight. Other schedules are never open.
    func isOpen(at date: Date, calendar: Calendar = .current, isWorkingDay: WorkingDays = everyWeekday) -> Bool {
        guard case .window(let window) = self else { return false }
        func opens(on day: Date) -> Bool {
            window.days.map { $0.contains(calendar.component(.weekday, from: day)) } ?? isWorkingDay(day)
        }
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if window.crossesMidnight {
            if now >= window.start.minutes, opens(on: date) { return true }
            if now < window.end.minutes, let yesterday = calendar.date(byAdding: .day, value: -1, to: date), opens(on: yesterday) { return true }
            return false
        }
        return opens(on: date) && now >= window.start.minutes && now < window.end.minutes
    }

    /// The day's time on each matching day after `date`, up to two years on.
    private static func days(after date: Date, count: Int, at time: TimeOfDay, calendar: Calendar, matching: (Date) -> Bool) -> [Date] {
        var times: [Date] = []
        var day = calendar.startOfDay(for: date)
        for _ in 0..<730 {
            if matching(day), let moment = time.on(day, calendar: calendar), moment > date {
                times.append(moment)
                if times.count == count { break }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return times
    }

    var isWindow: Bool {
        if case .window = self { true } else { false }
    }

    /// "Every 15 minutes", "Working days at 09:00", "Cron 0 9 * * 1-5".
    var summary: String {
        switch self {
        case .every(let minutes, _):
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1 ? "Every hour" : "Every \(hours) hours"
            }
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        case .daily(let time): return "Daily at \(time.label)"
        case .workingDays(let time): return "Working days at \(time.label)"
        case .weekly(let weekday, let time): return "\(Calendar.current.weekdaySymbols[(weekday - 1) % 7])s at \(time.label)"
        case .cron(let text): return "Cron \(text)"
        case .once(let at): return at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .window(let window):
            return "\(Self.daysLabel(window.days)), \(window.start.label) to \(window.end.label)"
        }
    }

    /// "Working days", "Every day", or the days Monday first ("Mon, Wed").
    static func daysLabel(_ days: Set<Int>?) -> String {
        guard let days else { return "Working days" }
        if days.count == 7 { return "Every day" }
        return WorkWeek.weekdays.filter(days.contains).map(WorkWeek.name).joined(separator: ", ")
    }

    /// Why the schedule can't be used, if it can't: an invalid cron
    /// expression, an interval under a minute, a time already passed.
    func problem(now: Date = .now) -> String? {
        switch self {
        case .every(let minutes, _):
            return minutes < 1 ? "Run at most once a minute." : nil
        case .cron(let text):
            do {
                let expression = try CronExpression(text)
                return expression.nextTimes(after: now, count: 1).isEmpty ? "It never comes round in the next eight years." : nil
            } catch {
                return error.localizedDescription
            }
        case .once(let at):
            return at <= now ? "That time has passed." : nil
        case .window(let window):
            if window.start == window.end { return "The window opens and closes at the same time." }
            if let days = window.days, days.isEmpty { return "Pick at least one day." }
            return nil
        default:
            return nil
        }
    }
}

/// A standard five-field cron expression: minute, hour, day of the month,
/// month and day of the week, each `*`, a number, a range (`1-5`), a step
/// (`*/15`, `0-30/10`, `5/20`) or a list of those (`1,15`). Months and
/// weekdays take names (`jan`, `mon`); Sunday is 0 or 7. As cron has it,
/// when both day fields are restricted a day matching either runs. `@hourly`,
/// `@daily`, `@weekly`, `@monthly` and `@yearly` stand for theirs.
struct CronExpression: Hashable {
    struct Problem: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    /// 0 for Sunday to 6.
    let weekdays: Set<Int>
    /// Whether each day field was `*` (or a step over all of it).
    let anyDayOfMonth: Bool
    let anyWeekday: Bool

    private static let macros = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
    ]
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw Problem(reason: "Enter a cron expression, such as 0 9 * * 1-5.") }
        let expanded = Self.macros[trimmed] ?? trimmed
        if expanded.hasPrefix("@") { throw Problem(reason: "\(trimmed) isn't one of @hourly, @daily, @weekly, @monthly or @yearly.") }
        let fields = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            throw Problem(reason: "A cron expression has five fields (minute, hour, day of the month, month, day of the week); this has \(fields.count).")
        }
        minutes = try Self.field(fields[0], name: "minute", range: 0...59)
        hours = try Self.field(fields[1], name: "hour", range: 0...23)
        daysOfMonth = try Self.field(fields[2], name: "day of the month", range: 1...31)
        months = try Self.field(fields[3], name: "month", range: 1...12, names: Self.monthNames, firstName: 1)
        let weekdays = try Self.field(fields[4], name: "day of the week", range: 0...7, names: Self.dayNames, firstName: 0)
        self.weekdays = Set(weekdays.map { $0 % 7 })
        anyDayOfMonth = fields[2].hasPrefix("*")
        anyWeekday = fields[4].hasPrefix("*")
    }

    private static func field(_ text: String, name: String, range: ClosedRange<Int>, names: [String] = [], firstName: Int = 0) throws -> Set<Int> {
        func value(_ part: Substring) throws -> Int {
            if let number = Int(part) {
                guard range.contains(number) else { throw Problem(reason: "\(number) is out of range for the \(name) (\(range.lowerBound) to \(range.upperBound)).") }
                return number
            }
            if let index = names.firstIndex(of: String(part)) { return index + firstName }
            throw Problem(reason: "\"\(part)\" isn't a valid \(name).")
        }
        var values: Set<Int> = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard !item.isEmpty else { throw Problem(reason: "The \(name) has an empty item in its list.") }
            let pieces = item.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw Problem(reason: "\"\(item)\" has more than one step in the \(name).") }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { throw Problem(reason: "\"\(pieces[1])\" isn't a valid step for the \(name).") }
                step = parsed
            }
            let base = pieces[0]
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2 else { throw Problem(reason: "\"\(base)\" isn't a valid range for the \(name).") }
                lower = try value(ends[0])
                upper = try value(ends[1])
                guard lower <= upper else { throw Problem(reason: "The range \(base) in the \(name) runs backwards.") }
            } else {
                lower = try value(base)
                // `5/20` runs from 5 to the end in steps.
                upper = pieces.count == 2 ? range.upperBound : lower
            }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values
    }

    func matches(day: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
        guard let month = parts.month, months.contains(month), let dayOfMonth = parts.day, let weekday = parts.weekday else { return false }
        let byMonthDay = daysOfMonth.contains(dayOfMonth)
        let byWeekday = weekdays.contains(weekday - 1)
        if !anyDayOfMonth && !anyWeekday { return byMonthDay || byWeekday }
        return byMonthDay && byWeekday
    }

    /// The next `count` times after `date`, a day at a time for up to eight
    /// years (long enough for the 29th of February on a given weekday).
    func nextTimes(after date: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var times: [Date] = []
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 8) {
            if matches(day: day, calendar: calendar) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        guard let moment = TimeOfDay(hour: hour, minute: minute).on(day, calendar: calendar),
                              moment > date, moment > (times.last ?? .distantPast) else { continue }
                        times.append(moment)
                        if times.count == count { return times }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return times
    }
}
