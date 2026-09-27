import SwiftUI

/// Working days and hours, in each person's own time: the org's, or a
/// person's own pattern (part time, or different hours on some days). The
/// work log shades the days off, and the punchcards count what falls outside.
struct WorkWeek: Codable, Hashable {
    /// Hours of one day, `[start, end)`.
    struct Hours: Codable, Hashable {
        var start: Int
        var end: Int
    }

    /// `Calendar` weekdays, 1 for Sunday to 7 for Saturday.
    var days: Set<Int> = [2, 3, 4, 5, 6]
    /// Hours of the day, `[startHour, endHour)`.
    var startHour = 9
    var endHour = 17
    /// Days whose hours differ from `startHour` to `endHour`, by weekday.
    var dayHours: [Int: Hours]?
    /// Where the org's bank holidays come from; people can have their own.
    var holidays: BankHolidayRegion?

    func hours(on weekday: Int) -> Hours {
        dayHours?[weekday] ?? Hours(start: startHour, end: endHour)
    }

    /// Hours worked in a week, for comparing a pattern with the org's.
    var weeklyHours: Int {
        days.map { hours(on: $0).end - hours(on: $0).start }.reduce(0, +)
    }

    /// Monday first, the order the app shows weeks in.
    static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    func isWorkingDay(_ date: Date, in calendar: Calendar = .current) -> Bool {
        days.contains(calendar.component(.weekday, from: date))
    }

    /// Whether the moment falls inside working days and hours.
    func isWorkingTime(weekday: Int, hour: Int) -> Bool {
        let hours = hours(on: weekday)
        return days.contains(weekday) && hour >= hours.start && hour < hours.end
    }

    /// "Mon - Thu, 09:00 - 17:00" or, when days differ, each day's hours.
    var summary: String {
        let ordered = Self.weekdays.filter(days.contains)
        guard !ordered.isEmpty else { return "No working days" }
        let distinct = Set(ordered.map(hours(on:)))
        if distinct.count == 1, let hours = distinct.first {
            let isRun = zip(ordered, ordered.dropFirst()).allSatisfy { pair in
                (Self.weekdays.firstIndex(of: pair.1) ?? 0) - (Self.weekdays.firstIndex(of: pair.0) ?? 0) == 1
            }
            let dayText = isRun && ordered.count > 2
                ? "\(Self.name(ordered[0])) - \(Self.name(ordered[ordered.count - 1]))"
                : ordered.map(Self.name).joined(separator: ", ")
            return "\(dayText), \(Self.hourLabel(hours.start)) - \(Self.hourLabel(hours.end))"
        }
        return ordered.map { "\(Self.name($0)) \(hours(on: $0).start)-\(hours(on: $0).end)" }.joined(separator: ", ")
    }

    static func name(_ weekday: Int) -> String {
        Calendar.current.shortWeekdaySymbols[(weekday - 1) % 7]
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}

/// Settings: which days and hours count as working time.
struct WorkWeekSection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    var body: some View {
        let week = configs.config(for: org).week
        Section {
            LabeledContent("Working days") {
                HStack(spacing: 10) {
                    ForEach(WorkWeek.weekdays, id: \.self) { weekday in
                        Toggle(WorkWeek.name(weekday), isOn: dayBinding(weekday))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            Picker("Day starts", selection: hourBinding(\.startHour)) {
                ForEach(0..<24, id: \.self) { Text(WorkWeek.hourLabel($0)).tag($0) }
            }
            Picker("Day ends", selection: hourBinding(\.endHour)) {
                ForEach((week.startHour + 1)...24, id: \.self) { Text(WorkWeek.hourLabel($0)).tag($0) }
            }
            BankHolidayRegionPicker(title: "Bank holidays", noneLabel: "None", selection: Binding {
                configs.config(for: org).week.holidays
            } set: { region in
                change { $0.holidays = region }
            })
            if week != WorkWeek(holidays: week.holidays) {
                Button("Reset to Monday to Friday, 09:00 - 17:00") {
                    configs.update(org) { $0.workWeek = week.holidays.map { WorkWeek(holidays: $0) } }
                }
            }
        } header: {
            Text("Working week")
        } footer: {
            Text("Hours are in each person's own time, taken from their commits. Bank holidays come from date.nager.at (only the country and year are sent), and anyone can have their own in their Time off. The work log shades days off; the punchcards show what falls outside these hours.")
                .foregroundStyle(.secondary)
        }
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding {
            configs.config(for: org).week.days.contains(weekday)
        } set: { on in
            change { week in
                if on { week.days.insert(weekday) } else { week.days.remove(weekday) }
            }
        }
    }

    private func hourBinding(_ keyPath: WritableKeyPath<WorkWeek, Int>) -> Binding<Int> {
        Binding {
            configs.config(for: org).week[keyPath: keyPath]
        } set: { hour in
            change { week in
                week[keyPath: keyPath] = hour
                if week.endHour <= week.startHour { week.endHour = min(24, week.startHour + 1) }
            }
        }
    }

    private func change(_ edit: (inout WorkWeek) -> Void) {
        configs.update(org) { config in
            var week = config.week
            edit(&week)
            config.workWeek = week == WorkWeek() ? nil : week
        }
    }
}
