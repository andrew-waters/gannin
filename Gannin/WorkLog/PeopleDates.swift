import Observation
import SwiftUI

/// Dates GitHub doesn't know about a person: when they started and left,
/// and days off (holiday or sick). Recorded by hand, kept in the org's
/// harness, or on this device for an org with none.
struct PersonDates: Codable, Hashable {
    var startDate: Date?
    var endDate: Date?
    var absences: [Absence] = []
    /// Their bank holidays, when not the org's.
    var holidayRegion: BankHolidayRegion?
    /// Their own working days and hours (part time, or other hours), when
    /// not the org's. Its `holidays` is unused; `holidayRegion` says that.
    var workWeek: WorkWeek?
    /// Their time zone identifier, when set by hand rather than taken from
    /// their commits.
    var timeZone: String?
    /// Their full-year holiday allowance, when not the org's.
    var allowance: Double?
    /// Days carried into a leave year, by the year it starts in.
    var carryOver: [String: Double]?

    var isEmpty: Bool {
        startDate == nil && endDate == nil && absences.isEmpty && holidayRegion == nil && workWeek == nil && timeZone == nil
            && allowance == nil && carryOver == nil
    }

    /// What the day was for them, if anything but an ordinary day.
    func status(on day: Date, calendar: Calendar = .current) -> DayStatus? {
        let day = calendar.startOfDay(for: day)
        if let startDate, day < calendar.startOfDay(for: startDate) { return .notStarted }
        if let endDate, day > calendar.startOfDay(for: endDate) { return .left }
        if let absence = absences.first(where: { $0.covers(day, calendar: calendar) }) {
            return .absent(absence.kind, absence.halfDay(calendar: calendar))
        }
        return nil
    }

    /// Days in `[from, to)` they were off, by kind, working days only (so
    /// not weekends or bank holidays); a half day counts a half.
    func daysOff(from: Date, to: Date, working: WorkingCalendar, calendar: Calendar = .current) -> [Absence.Kind: Double] {
        var counts: [Absence.Kind: Double] = [:]
        var day = calendar.startOfDay(for: from)
        while day < to {
            if working.isWorkingDay(day, calendar: calendar), case .absent(let kind, let half) = status(on: day, calendar: calendar) {
                counts[kind, default: 0] += half == nil ? 1 : 0.5
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return counts
    }

    var summary: String {
        var parts: [String] = []
        if let startDate { parts.append("Started \(startDate.formatted(date: .abbreviated, time: .omitted))") }
        if let endDate { parts.append("Left \(endDate.formatted(date: .abbreviated, time: .omitted))") }
        if let workWeek { parts.append(workWeek.summary) }
        if let timeZone { parts.append(timeZone.replacingOccurrences(of: "_", with: " ")) }
        for kind in Absence.Kind.allCases {
            let count = absences.filter { $0.kind == kind }.count
            if count > 0 { parts.append("\(count) \(kind.rawValue.lowercased()) \(count == 1 ? "entry" : "entries")") }
        }
        return parts.joined(separator: " · ")
    }
}

struct Absence: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case holiday = "Holiday"
        case sick = "Sick"

        /// Palette slots after the work log's four kinds.
        var color: Color {
            switch self {
            case .holiday: ChartPalette.violet
            case .sick: ChartPalette.red
            }
        }
    }

    /// Which half of a single day is off.
    enum HalfDay: String, Codable, CaseIterable {
        case morning = "Morning"
        case afternoon = "Afternoon"

        var short: String { self == .morning ? "AM" : "PM" }
    }

    var id = UUID()
    var kind: Kind
    /// First and last day off, both included.
    var start: Date
    var end: Date
    var note = ""
    /// Set for half a day off; only applies when `start` and `end` are the
    /// same day.
    var half: HalfDay?
    /// Requested and not yet approved; nil once booked.
    var approval: Approval?

    enum Approval: String, Codable {
        case requested
    }

    var isRequested: Bool { approval == .requested }

    /// The half day off, if this is one.
    func halfDay(calendar: Calendar = .current) -> HalfDay? {
        calendar.isDate(start, inSameDayAs: end) ? half : nil
    }

    /// Working days, counted by `PersonDates.daysOff`, as "1 day" or "2.5 days".
    static func days(_ count: Double) -> String {
        count == 1 ? "1 day" : "\(count.formatted(.number.precision(.fractionLength(0...1)))) days"
    }

    /// As "1.5d", for tight labels.
    static func shortDays(_ count: Double) -> String {
        "\(count.formatted(.number.precision(.fractionLength(0...1))))d"
    }

    func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }

    /// `[start, end)` as moments, for drawing across a timeline; a half day
    /// is midnight to midday or midday to midnight.
    func interval(calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(self.end, self.start))) ?? start
        guard let half = halfDay(calendar: calendar),
              let midday = calendar.date(byAdding: .hour, value: 12, to: start) else { return (start, end) }
        return half == .morning ? (start, midday) : (midday, end)
    }

    var label: String {
        var base = halfDay().map { "\(kind.rawValue) \($0.short)" } ?? kind.rawValue
        if isRequested { base += " (requested)" }
        return note.isEmpty ? base : "\(base): \(note)"
    }
}

enum DayStatus: Hashable {
    case absent(Absence.Kind, Absence.HalfDay?)
    case notStarted
    case left

    var label: String {
        switch self {
        case .absent(let kind, let half): half.map { "\(kind.rawValue) \($0.short)" } ?? kind.rawValue
        case .notStarted: "Not started"
        case .left: "Left"
        }
    }
}

/// Per org, per login, in memory and written through to the synced
/// `UserDatabase`; loaded again when another device's changes arrive.
@Observable
final class PeopleDatesStore {
    private(set) var dates: [String: [String: PersonDates]]
    @ObservationIgnored private let database: UserDatabase
    /// For orgs that keep people's dates in their harness, which are read
    /// from there, and changed there once committed.
    @ObservationIgnored var team: HarnessTeamStore?

    init(database: UserDatabase) {
        self.database = database
        dates = database.loadPeople()
        database.onRemoteChange { [weak self] in
            guard let self else { return }
            let loaded = database.loadPeople()
            if loaded != dates { dates = loaded }
        }
    }

    func dates(for login: String, in org: String) -> PersonDates {
        if let team = team?.data(for: org) { return team.people[login] ?? PersonDates() }
        return dates[org]?[login] ?? PersonDates()
    }

    /// Where an org's dates are kept, in words, for the footers that say so:
    /// its home harness when it has one, else this Mac.
    func whereKept(in org: String) -> String {
        team?.keepsData(org) == true ? "kept in the org's harness, where everyone reads the same copy" : "kept only in this app on this Mac"
    }

    func all(in org: String) -> [String: PersonDates] {
        team?.data(for: org)?.people ?? dates[org] ?? [:]
    }

    func clear() {
        dates = [:]
        database.deleteAllPeople()
    }

    func update(_ login: String, in org: String, _ change: (inout PersonDates) -> Void) {
        let before = dates(for: login, in: org)
        var person = before
        change(&person)
        guard person != before else { return }
        if let team, team.keepsData(org) {
            team.stage(org: org, [TeamFile.person(login): HarnessTeamData.personFile(person)])
            return
        }
        dates[org, default: [:]][login] = person.isEmpty ? nil : person
        database.savePerson(org: org, login: login, person)
    }
}

// MARK: - Editing

/// Start and end dates and time off for one person, in a sheet.
struct PersonDatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showPerson) private var showPerson
    @AppStorage("personPart") private var personPart: PersonColumn.Part = .work
    @AppStorage("personTimeOffPart") private var timeOffPart: PersonColumn.TimeOffPart = .calendar

    let org: String
    let person: Person

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Avatar(url: person.avatarUrl, size: 26)
                Text(person.displayName).font(.title3.weight(.semibold))
                Spacer()
                if let showPerson {
                    Button {
                        // Straight to their time off, where this sheet's
                        // details also live.
                        personPart = .timeOff
                        timeOffPart = .calendar
                        showPerson(person.login)
                        dismiss()
                    } label: {
                        Label("Open Profile", systemImage: "person.crop.circle")
                    }
                    .help("Show \(person.displayName)'s time off calendar and report")
                }
            }
            .padding([.horizontal, .top], 20)
            Form {
                PersonDatesSections(org: org, person: person)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 560)
    }
}

/// The form sections for a person's dates: a summary of their time off,
/// employment dates, and the time off itself. Used by the sheet and by the
/// Time off part of the person view.
struct PersonDatesSections: View {
    @Environment(PeopleDatesStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let person: Person

    /// Time off being added or edited in the sheet.
    @State private var draft: Absence?

    private var orgRegion: BankHolidayRegion? { configs.config(for: org).week.holidays }
    private var region: BankHolidayRegion? { store.region(for: person.login, in: org, default: orgRegion) }

    /// Their working days this year and next, bank holidays included.
    private var working: WorkingCalendar {
        let year = Calendar.current.component(.year, from: .now)
        return store.workingCalendar(for: person.login, in: org, orgWeek: configs.config(for: org).week, holidays: holidayStore, years: year...year + 1)
    }

    static func regionName(_ region: BankHolidayRegion, _ store: BankHolidayStore) -> String {
        if let subdivision = region.subdivision { return BankHolidayRegion.subdivisionName(subdivision) }
        return store.countries.first { $0.countryCode == region.country }?.name ?? region.country
    }

    var body: some View {
        let dates = store.dates(for: person.login, in: org)
        Section("Summary") {
            summaryRows(dates)
        }
        .task(id: region) {
            if let region {
                let year = Calendar.current.component(.year, from: .now)
                await holidayStore.load([region], years: year...year + 1)
            }
        }
        Section("Employment") {
            optionalDate("Start date", \.startDate, current: dates.startDate)
            optionalDate("End date", \.endDate, current: dates.endDate)
            BankHolidayRegionPicker(
                title: "Bank holidays",
                noneLabel: orgRegion.map { "The org's (\(Self.regionName($0, holidayStore)))" } ?? "None",
                selection: Binding {
                    store.dates(for: person.login, in: org).holidayRegion
                } set: { region in
                    store.update(person.login, in: org) { $0.holidayRegion = region }
                }
            )
        }
        PersonAllowanceSection(org: org, person: person)
        WorkPatternSection(org: org, person: person)
        Section {
            if dates.absences.isEmpty {
                Text("No time off recorded.").foregroundStyle(.secondary)
            }
            ForEach(dates.absences.sorted { $0.start > $1.start }) { absence in
                absenceRow(absence)
            }
            HStack {
                ForEach(Absence.Kind.allCases, id: \.self) { kind in
                    Button("Add \(kind.rawValue)") { add(kind) }
                }
            }
        } header: {
            Text("Time off")
        } footer: {
            Text("Time off is \(store.whereKept(in: org)). Days count only their working days, so weekends, days outside their pattern and bank holidays are skipped. Days off show on the work log and threads, and are counted on the punchcards.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $draft) { absence in
            AbsenceSheet(org: org, person: person, absence: absence)
        }
    }

    /// Working days off this year by kind, what's coming up, and whether
    /// they're off today.
    @ViewBuilder
    private func summaryRows(_ dates: PersonDates) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let working = working
        let yearStart = calendar.dateInterval(of: .year, for: today)?.start ?? today
        let yearEnd = calendar.dateInterval(of: .year, for: today)?.end ?? today
        let taken = dates.daysOff(from: yearStart, to: calendar.date(byAdding: .day, value: 1, to: today) ?? today, working: working)
        let booked = dates.daysOff(from: calendar.date(byAdding: .day, value: 1, to: today) ?? today, to: yearEnd, working: working)
        if let holiday = working.holiday(on: today) {
            Label("Bank holiday today (\(holiday))", systemImage: "circle.fill")
                .foregroundStyle(TimelineMark.bankHoliday)
        } else if case .absent(let kind, let half) = dates.status(on: today) {
            Label("Off \(half.map { "this \($0.rawValue.lowercased())" } ?? "today") (\(kind.rawValue.lowercased()))", systemImage: "circle.fill")
                .foregroundStyle(kind.color)
        }
        // Holiday is against the allowance, in its own section.
        LabeledContent("Sick this year") {
            let past = taken[.sick] ?? 0
            let future = booked[.sick] ?? 0
            Text(future > 0 ? "\(Absence.days(past)) taken, \(Absence.days(future)) booked" : Absence.days(past))
                .monospacedDigit()
        }
        if let next = dates.absences.filter({ $0.start > today }).min(by: { $0.start < $1.start }) {
            LabeledContent("Next time off") {
                Text("\(next.kind.rawValue), \(Self.range(next))")
            }
        }
        if let next = working.holidays.filter({ $0.key > WorkingCalendar.key(today) }).min(by: { $0.key < $1.key }),
           let date = WorkingCalendar.date(next.key) {
            LabeledContent("Next bank holiday") {
                Text("\(next.value), \(date.formatted(date: .abbreviated, time: .omitted))")
            }
        }
    }

    static func range(_ absence: Absence) -> String {
        let calendar = Calendar.current
        if calendar.isDate(absence.start, inSameDayAs: absence.end) {
            let day = absence.start.formatted(date: .abbreviated, time: .omitted)
            return absence.halfDay().map { "\(day) (\($0.rawValue.lowercased()))" } ?? day
        }
        return "\(absence.start.formatted(.dateTime.day().month(.abbreviated))) - \(absence.end.formatted(date: .abbreviated, time: .omitted))"
    }

    private func optionalDate(_ title: String, _ keyPath: WritableKeyPath<PersonDates, Date?>, current: Date?) -> some View {
        HStack {
            Toggle(title, isOn: Binding {
                current != nil
            } set: { on in
                store.update(person.login, in: org) { $0[keyPath: keyPath] = on ? Calendar.current.startOfDay(for: .now) : nil }
            })
            if let current {
                Spacer()
                DatePicker(title, selection: Binding {
                    current
                } set: { date in
                    store.update(person.login, in: org) { $0[keyPath: keyPath] = Calendar.current.startOfDay(for: date) }
                }, displayedComponents: .date)
                .labelsHidden()
            }
        }
    }

    private func absenceRow(_ absence: Absence) -> some View {
        let days = dayCount(absence)
        return HStack(spacing: 8) {
            Circle()
                .strokeBorder(absence.kind.color, lineWidth: absence.isRequested ? 1.5 : 0)
                .background(Circle().fill(absence.isRequested ? .clear : absence.kind.color))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(absence.kind.rawValue), \(Self.range(absence))")
                Text([Absence.days(days), absence.isRequested ? "Requested" : "", absence.note].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if absence.isRequested {
                Button("Approve") {
                    store.update(person.login, in: org) { dates in
                        if let index = dates.absences.firstIndex(where: { $0.id == absence.id }) { dates.absences[index].approval = nil }
                    }
                }
                .help("Book this time off")
            }
            Button("Edit") { draft = absence }
            Button {
                store.update(person.login, in: org) { $0.absences.removeAll { $0.id == absence.id } }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { draft = absence }
    }

    /// Working days the entry covers, by their calendar.
    private func dayCount(_ absence: Absence) -> Double {
        let (from, to) = absence.interval()
        let dates = PersonDates(absences: [absence])
        return dates.daysOff(from: Calendar.current.startOfDay(for: from), to: to, working: working).values.reduce(0, +)
    }

    private func add(_ kind: Absence.Kind) {
        let today = Calendar.current.startOfDay(for: .now)
        draft = Absence(kind: kind, start: today, end: today)
    }
}

/// "Dates and Time Off" in a person's context menu, opening the editor.
private struct PersonDatesMenu: ViewModifier {
    let person: Person
    let org: String

    @State private var editing = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Dates and Time Off") { editing = true }
            }
            .sheet(isPresented: $editing) {
                PersonDatesSheet(org: org, person: person)
            }
    }
}

extension View {
    func personDatesMenu(_ person: Person, org: String) -> some View {
        modifier(PersonDatesMenu(person: person, org: org))
    }
}

/// Settings: everyone with dates or time off recorded, and a way to add more.
struct PeopleDatesSection: View {
    @Environment(PeopleDatesStore.self) private var store
    let org: String
    let people: [Person]

    @State private var editing: Person?

    var body: some View {
        let recorded = people.filter { !store.dates(for: $0.login, in: org).isEmpty }
        Section {
            if recorded.isEmpty {
                Text("Nothing recorded. Right-click someone on the work log, threads or punchcards, or add them here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(recorded) { person in
                LabeledContent {
                    Button("Edit") { editing = person }
                } label: {
                    HStack(spacing: 8) {
                        Avatar(url: person.avatarUrl, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName)
                            Text(store.dates(for: person.login, in: org).summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Menu("Add Someone") {
                ForEach(people.filter { store.dates(for: $0.login, in: org).isEmpty }) { person in
                    Button(person.displayName) { editing = person }
                }
            }
            .fixedSize()
        } header: {
            Text("Dates and time off")
        } footer: {
            Text("Start and end dates, holidays and sick days, \(store.whereKept(in: org)).")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { person in
            PersonDatesSheet(org: org, person: person)
        }
    }
}

// MARK: - On timelines

/// What a timeline cell says about the person's dates: a tinted, labelled
/// background for time off, a dimmed one before they started or after they left.
struct TimelineMark: Hashable {
    let label: String
    /// The tint; nil dims the cell instead.
    let color: Color?
    /// Tints only that half of the cell (morning on the left).
    var half: Absence.HalfDay? = nil

    static let bankHoliday = ChartPalette.green
}

extension PersonDates {
    /// The mark for a cell covering `[from, to)`, a day or a week.
    func mark(from: Date, to: Date, isDay: Bool, working: WorkingCalendar, calendar: Calendar = .current) -> TimelineMark? {
        if isDay {
            let status = status(on: from, calendar: calendar)
            if status != .notStarted && status != .left, let holiday = working.holiday(on: from, calendar: calendar) {
                return TimelineMark(label: holiday, color: TimelineMark.bankHoliday)
            }
            switch status {
            case .absent(let kind, let half):
                // Weekends inside a stretch aren't time off; the day-off shading covers them.
                guard working.isWorkingDay(from, calendar: calendar) else { return nil }
                return TimelineMark(label: DayStatus.absent(kind, half).label, color: kind.color, half: half)
            case .notStarted: return TimelineMark(label: "Not started", color: nil)
            case .left: return TimelineMark(label: "Left", color: nil)
            case nil: return nil
            }
        }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: to) ?? from
        if status(on: lastDay, calendar: calendar) == .notStarted { return TimelineMark(label: "Not started", color: nil) }
        if status(on: from, calendar: calendar) == .left { return TimelineMark(label: "Left", color: nil) }
        let off = daysOff(from: from, to: to, working: working, calendar: calendar)
        var parts = Absence.Kind.allCases.compactMap { kind in off[kind].map { "\(Absence.shortDays($0)) \(kind.rawValue.lowercased())" } }
        var day = from
        var bankHolidays = 0
        while day < to {
            if working.week.isWorkingDay(day, in: calendar), working.holiday(on: day, calendar: calendar) != nil { bankHolidays += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? to
        }
        if bankHolidays > 0 { parts.append(bankHolidays == 1 ? "bank hol" : "\(bankHolidays) bank hols") }
        guard !parts.isEmpty else { return nil }
        let color = off.max(by: { $0.value < $1.value })?.key.color ?? TimelineMark.bankHoliday
        return TimelineMark(label: parts.joined(separator: ", "), color: color)
    }
}

/// A cell's background and label for a `TimelineMark`.
struct TimelineMarkView: View {
    let mark: TimelineMark

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let color = mark.color {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(color.opacity(0.16))
                        .frame(width: mark.half == nil ? geometry.size.width : geometry.size.width / 2)
                        .offset(x: mark.half == .afternoon ? geometry.size.width / 2 : 0)
                }
            } else {
                Rectangle().fill(.quaternary.opacity(0.7))
            }
            Text(mark.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(mark.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.top, 4)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Working pattern

/// A person's own working days and hours (part time, or other hours on some
/// days) and time zone, each falling back to the org's or their commits'.
struct WorkPatternSection: View {
    @Environment(PeopleDatesStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs

    let org: String
    let person: Person

    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        let orgWeek = configs.config(for: org).week
        let own = store.dates(for: person.login, in: org).workWeek
        Section {
            Toggle("Own working pattern", isOn: Binding {
                own != nil
            } set: { on in
                store.update(person.login, in: org) { dates in
                    // Starts from the org's week, each day's hours spelled out.
                    dates.workWeek = on ? Self.expanded(orgWeek) : nil
                }
            })
            if let own {
                ForEach(WorkWeek.weekdays, id: \.self) { weekday in
                    dayRow(weekday, week: own)
                }
                LabeledContent("Hours a week") {
                    let fte = orgWeek.weeklyHours > 0 ? Double(own.weeklyHours) / Double(orgWeek.weeklyHours) : 0
                    Text("\(own.weeklyHours) of \(orgWeek.weeklyHours) (\(fte.formatted(.number.precision(.fractionLength(0...2)))) FTE)")
                        .monospacedDigit()
                }
            } else {
                LabeledContent("Org's working week", value: orgWeek.summary)
            }
            Picker("Time zone", selection: Binding {
                store.dates(for: person.login, in: org).timeZone
            } set: { zone in
                store.update(person.login, in: org) { $0.timeZone = zone }
            }) {
                Text("From their commits").tag(String?.none)
                ForEach(Self.zones, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag(Optional($0)) }
            }
        } header: {
            Text("Working pattern")
        } footer: {
            Text("For part-time or other hours. Hours are in their time zone; set one when their commits don't say (or say wrongly) where they are.")
                .foregroundStyle(.secondary)
        }
    }

    private func dayRow(_ weekday: Int, week: WorkWeek) -> some View {
        let isOn = week.days.contains(weekday)
        let hours = week.hours(on: weekday)
        return HStack {
            Toggle(WorkWeek.name(weekday), isOn: Binding {
                isOn
            } set: { on in
                change { week in
                    if on { week.days.insert(weekday) } else { week.days.remove(weekday) }
                }
            })
            .checkboxToggle()
            .frame(width: 70, alignment: .leading)
            Spacer()
            if isOn {
                Picker("Starts", selection: hourBinding(weekday, start: true)) {
                    ForEach(0..<24, id: \.self) { Text(WorkWeek.hourLabel($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("to").foregroundStyle(.secondary)
                Picker("Ends", selection: hourBinding(weekday, start: false)) {
                    ForEach((hours.start + 1)...24, id: \.self) { Text(WorkWeek.hourLabel($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text("Not working").foregroundStyle(.secondary)
            }
        }
    }

    private func hourBinding(_ weekday: Int, start: Bool) -> Binding<Int> {
        Binding {
            let hours = store.dates(for: person.login, in: org).workWeek?.hours(on: weekday)
            return (start ? hours?.start : hours?.end) ?? 0
        } set: { hour in
            change { week in
                var hours = week.hours(on: weekday)
                if start { hours.start = hour } else { hours.end = hour }
                if hours.end <= hours.start { hours.end = min(24, hours.start + 1) }
                week.dayHours = (week.dayHours ?? [:]).merging([weekday: hours]) { $1 }
            }
        }
    }

    private func change(_ edit: (inout WorkWeek) -> Void) {
        store.update(person.login, in: org) { dates in
            guard var week = dates.workWeek else { return }
            edit(&week)
            dates.workWeek = week
        }
    }

    /// The org's week with every day's hours set, so days can differ.
    private static func expanded(_ week: WorkWeek) -> WorkWeek {
        var own = week
        own.holidays = nil
        own.dayHours = Dictionary(uniqueKeysWithValues: WorkWeek.weekdays.map { ($0, week.hours(on: $0)) })
        return own
    }
}

/// How long a stretch of time off is, as the editor asks it: one day (or
/// half of one), or longer with an end date.
enum AbsenceLength: String, CaseIterable {
    case fullDay = "Full day"
    case morning = "Morning"
    case afternoon = "Afternoon"
    case longer = "Longer"

    init(_ absence: Absence) {
        if !Calendar.current.isDate(absence.start, inSameDayAs: absence.end) {
            self = .longer
        } else {
            switch absence.half {
            case .morning: self = .morning
            case .afternoon: self = .afternoon
            case nil: self = .fullDay
            }
        }
    }
}

// MARK: - Adding and editing time off

/// Asks for one stretch of time off: its kind and first day, then a whole
/// day, a morning, an afternoon, or longer as a number of working days. The
/// last day is worked out from their calendar, skipping weekends, days
/// outside their pattern and bank holidays.
struct AbsenceSheet: View {
    @Environment(PeopleDatesStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore
    @Environment(\.dismiss) private var dismiss

    let org: String
    let absence: Absence
    /// People to choose between, when adding from the calendar; empty
    /// fixes it to the one given.
    let choosable: [Person]

    @State private var person: Person
    @State private var kind: Absence.Kind
    @State private var start: Date
    @State private var length: AbsenceLength
    @State private var days = 5
    @State private var note: String
    @State private var requested: Bool
    @State private var countedDays = false

    init(org: String, person: Person, absence: Absence, choosable: [Person] = []) {
        self.org = org
        self.absence = absence
        self.choosable = choosable
        _person = State(initialValue: person)
        _kind = State(initialValue: absence.kind)
        _start = State(initialValue: absence.start)
        _length = State(initialValue: AbsenceLength(absence))
        _note = State(initialValue: absence.note)
        _requested = State(initialValue: absence.isRequested)
    }

    private var isNew: Bool {
        !store.dates(for: person.login, in: org).absences.contains { $0.id == absence.id }
    }

    private var working: WorkingCalendar {
        let year = Calendar.current.component(.year, from: start)
        return store.workingCalendar(for: person.login, in: org, orgWeek: configs.config(for: org).week, holidays: holidayStore, years: year...year + 1)
    }

    /// The Nth working day from the start, the start counting if it's one.
    private var lastDay: Date {
        let calendar = Calendar.current
        let working = working
        var day = calendar.startOfDay(for: start)
        var counted = 0
        for _ in 0..<730 {
            if working.isWorkingDay(day) {
                counted += 1
                if counted == days { return day }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return day
    }

    /// The first working day after the last one.
    private var backOn: Date {
        let calendar = Calendar.current
        let working = working
        var day = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        for _ in 0..<60 where !working.isWorkingDay(day) {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add time off for \(person.displayName)" : "Edit time off for \(person.displayName)")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                if !choosable.isEmpty {
                    Picker("Person", selection: $person) {
                        ForEach(choosable) { Text($0.displayName).tag($0) }
                    }
                }
                Picker("Kind", selection: $kind) {
                    ForEach(Absence.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("First day", selection: $start, displayedComponents: .date)
                Picker("Length", selection: $length) {
                    ForEach(AbsenceLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if length == .longer {
                    LabeledContent("Working days") {
                        HStack(spacing: 6) {
                            TextField("Working days", value: $days, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Stepper("Working days", value: $days, in: 2...260)
                                .labelsHidden()
                        }
                    }
                    LabeledContent("Last day", value: lastDay.formatted(date: .complete, time: .omitted))
                    LabeledContent("Back on", value: backOn.formatted(date: .complete, time: .omitted))
                } else if !working.isWorkingDay(start) {
                    Text(working.holiday(on: start).map { "That's a bank holiday (\($0)), so it won't count." } ?? "That isn't one of their working days, so it won't count.")
                        .foregroundStyle(.orange)
                }
                TextField("Note", text: $note, prompt: Text("Optional"))
                if kind == .holiday {
                    Toggle("Requested, not yet approved", isOn: $requested)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Weekends, days outside their pattern and bank holidays are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onChange(of: days) { days = min(max(days, 2), 260) }
        .task(id: "\(Calendar.current.component(.year, from: start)) \(person.login)") {
            let orgRegion = configs.config(for: org).week.holidays
            if let region = store.region(for: person.login, in: org, default: orgRegion) {
                let year = Calendar.current.component(.year, from: start)
                await holidayStore.load([region], years: year...year + 1)
            }
            // An existing stretch opens with its length in working days,
            // once its bank holidays are loaded so they aren't counted.
            if !countedDays, AbsenceLength(absence) == .longer {
                let entry = PersonDates(absences: [absence])
                let (from, to) = absence.interval()
                days = max(2, Int(entry.daysOff(from: from, to: to, working: working).values.reduce(0, +).rounded()))
            }
            countedDays = true
        }
    }

    private func save() {
        let calendar = Calendar.current
        var saved = absence
        saved.kind = kind
        saved.start = calendar.startOfDay(for: start)
        saved.note = note.trimmingCharacters(in: .whitespaces)
        saved.approval = kind == .holiday && requested ? .requested : nil
        switch length {
        case .fullDay, .morning, .afternoon:
            saved.end = saved.start
            saved.half = length == .morning ? .morning : length == .afternoon ? .afternoon : nil
        case .longer:
            saved.end = lastDay
            saved.half = nil
        }
        store.update(person.login, in: org) { dates in
            if let index = dates.absences.firstIndex(where: { $0.id == saved.id }) {
                dates.absences[index] = saved
            } else {
                dates.absences.append(saved)
            }
        }
        dismiss()
    }
}
