import SwiftUI

/// The Punchcards page's content: when each person works, as a week
/// of hours (Monday first) with a dot per hour sized by activity, in their
/// own time zone. The org's working hours are shaded, so late nights,
/// weekends and short days stand out. Merges are left out, because merge
/// queues and auto-merge land them whenever CI finishes.
struct PunchcardContent: View {
    @Environment(PeopleDatesStore.self) private var peopleDates

    let org: String
    let pullRequests: [WorkLogPullRequest]
    let columns: [WorkLogGrid.Column]
    let people: [Person]
    /// Each person's working days, bank holidays included.
    let calendars: [String: WorkingCalendar]
    let week: WorkWeek

    /// On a one-day page, that day's row (Monday is 0); nil for the week.
    private var singleDay: Int? {
        guard columns.count == 1, let start = columns.first?.start else { return nil }
        return WorkWeek.weekdays.firstIndex(of: Calendar.current.component(.weekday, from: start))
    }

    var body: some View {
        let cards = Punchcard.cards(pullRequests: pullRequests, people: people, from: columns.first?.start ?? .now, to: columns.last?.end ?? .now, calendars: calendars, week: week)
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(cards, id: \.person.login) { card in
                    let from = columns.first?.start ?? .now
                    let to = columns.last?.end ?? .now
                    let dates = peopleDates.dates(for: card.person.login, in: org)
                    PunchcardCard(
                        card: card,
                        week: calendars[card.person.login]?.week ?? week,
                        day: singleDay,
                        timeOff: dates.daysOff(from: from, to: to, working: calendars[card.person.login] ?? WorkingCalendar(week: week)),
                        activeWhileOff: card.activeDays.filter { if case .absent = dates.status(on: $0) { true } else { false } }.count
                    )
                    .personDatesMenu(card.person, org: org)
                }
            }
            Text("Times are in each person's time zone: the one set in their Time off, else commits count at the time on the author's clock and everything else in their usual offset. Shaded hours are their working pattern, or the org's working week from Settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Model

/// One person's activity by weekday and hour, in their own time.
struct Punchcard {
    struct Slot: Hashable {
        /// Index into `WorkWeek.weekdays`, so 0 is Monday.
        let day: Int
        let hour: Int
    }

    let person: Person
    /// Their usual UTC offset, from their commits; nil when they have none.
    let utcOffset: Int?
    /// Their time zone when set by hand, which wins over their commits.
    let timeZone: TimeZone?
    let counts: [Slot: [WorkLogEvent.Kind: Int]]
    let total: Int
    let outOfHours: Int
    /// Days off (by the working week) with any activity.
    let daysOffWorked: Int
    /// Median first and last activity of the day, in minutes after midnight.
    let usualSpan: (start: Int, end: Int)?
    /// Days with any activity, by the viewer's calendar, to check against
    /// recorded time off.
    let activeDays: Set<Date>

    var busiest: Int { counts.values.map { $0.values.reduce(0, +) }.max() ?? 0 }

    func count(_ slot: Slot) -> Int { counts[slot]?.values.reduce(0, +) ?? 0 }

    var zoneLabel: String {
        if let timeZone {
            return timeZone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? timeZone.identifier
        }
        guard let utcOffset else { return "Your time zone" }
        guard utcOffset != 0 else { return "UTC" }
        let minutes = abs(utcOffset) / 60
        let sign = utcOffset < 0 ? "-" : "+"
        return minutes % 60 == 0 ? "UTC\(sign)\(minutes / 60)" : String(format: "UTC%@%d:%02d", sign, minutes / 60, minutes % 60)
    }

    static func cards(pullRequests: [WorkLogPullRequest], people: [Person], from: Date, to: Date, calendars: [String: WorkingCalendar], week: WorkWeek) -> [Punchcard] {
        let events = pullRequests.flatMap(\.events).filter { $0.kind != .merged }
        // Everyone's usual offset comes from all their stored commits, not
        // just this page's, so a quiet fortnight still has one.
        var offsets: [String: [Int: Int]] = [:]
        for event in events {
            if let offset = event.utcOffset { offsets[event.login, default: [:]][offset, default: 0] += 1 }
        }
        let inRange = Dictionary(grouping: events.filter { $0.at >= from && $0.at < to }, by: \.login)
        return people.map { person in
            let usual = offsets[person.login]?.max { $0.value < $1.value }?.key
            return Punchcard(person: person, events: inRange[person.login] ?? [], usualOffset: usual, working: calendars[person.login] ?? WorkingCalendar(week: week))
        }
    }

    /// Bank holidays count as days off, by the person's own calendar day.
    init(person: Person, events: [WorkLogEvent], usualOffset: Int?, working: WorkingCalendar) {
        let week = working.week
        self.person = person
        utcOffset = usualOffset
        timeZone = working.timeZone
        var fixed = Calendar(identifier: .gregorian)
        if let zone = working.timeZone { fixed.timeZone = zone }
        var calendars: [Int: Calendar] = [:]
        func calendar(_ offset: Int?) -> Calendar {
            if working.timeZone != nil { return fixed }
            let offset = offset ?? usualOffset ?? TimeZone.current.secondsFromGMT()
            if let calendar = calendars[offset] { return calendar }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .current
            calendars[offset] = calendar
            return calendar
        }

        var counts: [Slot: [WorkLogEvent.Kind: Int]] = [:]
        var outOfHours = 0
        // Minutes after midnight of each event, by local day.
        var days: [DateComponents: (weekday: Int, minutes: [Int], isHoliday: Bool)] = [:]
        for event in events {
            let calendar = calendar(event.utcOffset)
            let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: event.at)
            guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute,
                  let day = WorkWeek.weekdays.firstIndex(of: weekday) else { continue }
            counts[Slot(day: day, hour: hour), default: [:]][event.kind, default: 0] += 1
            let key = DateComponents(year: parts.year, month: parts.month, day: parts.day)
            let isHoliday = working.holidays[WorkingCalendar.key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)] != nil
            if isHoliday || !week.isWorkingTime(weekday: weekday, hour: hour) { outOfHours += 1 }
            days[key, default: (weekday: weekday, minutes: [], isHoliday: isHoliday)].minutes.append(hour * 60 + minute)
        }
        self.counts = counts
        activeDays = Set(events.map { Calendar.current.startOfDay(for: $0.at) })
        total = events.count
        self.outOfHours = outOfHours
        daysOffWorked = days.values.filter { $0.isHoliday || !week.days.contains($0.weekday) }.count

        // Working days only, so a stray Sunday commit doesn't skew it.
        let workingDays = days.values.filter { !$0.isHoliday && week.days.contains($0.weekday) }
        if workingDays.count >= 3 {
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            usualSpan = (median(workingDays.map { $0.minutes.min() ?? 0 }), median(workingDays.map { $0.minutes.max() ?? 0 }))
        } else {
            usualSpan = nil
        }
    }
}

// MARK: - Card

private struct PunchcardCard: View {
    let card: Punchcard
    let week: WorkWeek
    /// A one-day page's row; nil draws the whole week.
    let day: Int?
    /// Working days off in the range, by kind.
    let timeOff: [Absence.Kind: Double]
    /// Days off with activity anyway.
    let activeWhileOff: Int

    @State private var hovered: Punchcard.Slot?

    private static let labelWidth: CGFloat = 32
    private static let weekRowHeight: CGFloat = 15

    /// A single day's row has room to be taller.
    private var rowHeight: CGFloat { day == nil ? Self.weekRowHeight : 24 }

    /// The rows drawn: the week, or the day plus any row it spills into in
    /// the person's own time zone (a late night elsewhere is the next day).
    private var rows: [Int] {
        guard let day else { return Array(WorkWeek.weekdays.indices) }
        return Set(card.counts.keys.map(\.day)).union([day]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(url: card.person.avatarUrl, size: 22)
                Text(card.person.displayName).lineLimit(1)
                Spacer(minLength: 8)
                Text(card.zoneLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(card.timeZone != nil ? "Set in their Time off" : card.utcOffset == nil ? "No commits to tell their time zone from, so this is shown in yours" : "Their most common offset across their commits")
            }
            grid
            Text(caption)
                .font(.caption)
                .foregroundStyle(hovered == nil ? .secondary : .primary)
                .lineLimit(1)
            if !timeOff.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Absence.Kind.allCases.filter { timeOff[$0] != nil }, id: \.self) { kind in
                        let days = timeOff[kind] ?? 0
                        HStack(spacing: 4) {
                            Circle().fill(kind.color).frame(width: 7, height: 7)
                            Text("\(Absence.days(days)) \(kind.rawValue.lowercased())")
                        }
                    }
                    if activeWhileOff > 0 {
                        Text(activeWhileOff == 1 ? "active on 1 of them" : "active on \(activeWhileOff) of them")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var grid: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let cellWidth = (geometry.size.width - Self.labelWidth) / 24
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        draw(in: &context, cellWidth: cellWidth)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element) { index, day in
                        Text(WorkWeek.name(WorkWeek.weekdays[day]))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.labelWidth - 4, height: rowHeight, alignment: .leading)
                            .offset(y: CGFloat(index) * rowHeight)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let hour = Int((location.x - Self.labelWidth) / cellWidth)
                        let index = Int(location.y / rowHeight)
                        hovered = (0..<24).contains(hour) && rows.indices.contains(index) && location.x >= Self.labelWidth ? Punchcard.Slot(day: rows[index], hour: hour) : nil
                    case .ended:
                        hovered = nil
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(rows.count))
            HStack(spacing: 0) {
                Spacer().frame(width: Self.labelWidth)
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(WorkWeek.hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, cellWidth: CGFloat) {
        let busiest = Double(max(card.busiest, 1))
        for (index, day) in rows.enumerated() {
            let weekday = WorkWeek.weekdays[day]
            let y = CGFloat(index) * rowHeight
            for hour in 0..<24 {
                let rect = CGRect(x: Self.labelWidth + CGFloat(hour) * cellWidth, y: y, width: cellWidth, height: rowHeight)
                let slot = Punchcard.Slot(day: day, hour: hour)
                if week.isWorkingTime(weekday: weekday, hour: hour) {
                    context.fill(Path(rect.insetBy(dx: 0, dy: 0.5)), with: .color(.secondary.opacity(0.14)))
                }
                if slot == hovered {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(.secondary), lineWidth: 1)
                }
                let count = card.count(slot)
                guard count > 0 else { continue }
                // Area follows the count, so the radius follows its root.
                let maxRadius = min(cellWidth, rowHeight) / 2 - 1
                let radius = max(1.5, maxRadius * sqrt(Double(count) / busiest))
                let center = CGPoint(x: rect.midX, y: rect.midY)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.primary.opacity(0.75)))
            }
        }
    }

    private var caption: String {
        if let hovered {
            let weekday = WorkWeek.name(WorkWeek.weekdays[hovered.day])
            let hours = "\(weekday) \(WorkWeek.hourLabel(hovered.hour)) - \(WorkWeek.hourLabel(hovered.hour + 1))"
            let kinds = card.counts[hovered] ?? [:]
            guard !kinds.isEmpty else { return "\(hours) · nothing" }
            let parts = WorkLogEvent.Kind.allCases.compactMap { kind -> String? in
                guard let count = kinds[kind] else { return nil }
                switch kind {
                case .commit: return count == 1 ? "1 commit" : "\(count) commits"
                case .review: return count == 1 ? "1 review" : "\(count) reviews"
                case .opened: return count == 1 ? "1 PR opened" : "\(count) PRs opened"
                case .merged, .issueOpened, .comment: return nil
                }
            }
            return "\(hours) · \(parts.joined(separator: ", "))"
        }
        guard card.total > 0 else { return "No activity in this range" }
        var parts = [card.total == 1 ? "1 event" : "\(card.total) events"]
        let share = Int((Double(card.outOfHours) / Double(card.total) * 100).rounded())
        parts.append("\(share)% outside hours")
        if card.daysOffWorked > 0 {
            parts.append(card.daysOffWorked == 1 ? "1 day off worked" : "\(card.daysOffWorked) days off worked")
        }
        if let span = card.usualSpan {
            func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
            parts.append("usually \(time(span.start)) - \(time(span.end))")
        }
        return parts.joined(separator: " · ")
    }
}
