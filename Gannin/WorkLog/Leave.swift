import SwiftUI

/// The org's holiday allowance: when the leave year starts, the days a
/// full-time person gets, and whether part-timers get a share of it.
/// Allowances are in working days, bank holidays on top.
struct LeavePolicy: Codable, Hashable {
    /// 1 for January to 12 for December.
    var yearStartMonth = 1
    var allowance: Double = 25
    /// Scales the org's allowance by working days a week, for people with a
    /// pattern of their own.
    var proRataPartTime = true
}

/// One leave year, `[start, end)`.
struct LeaveYear: Hashable {
    let start: Date
    let end: Date

    /// The leave year containing `date`.
    init(containing date: Date, startMonth: Int, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = (parts.month ?? 1) >= startMonth ? (parts.year ?? 0) : (parts.year ?? 0) - 1
        start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)) ?? date
        end = calendar.date(byAdding: .year, value: 1, to: start) ?? date
    }

    /// The year it starts in, which keys carried-over days.
    var key: String { String(Calendar.current.component(.year, from: start)) }

    /// "2026", or "2026/27" when it doesn't start in January.
    var label: String {
        let calendar = Calendar.current
        let first = calendar.component(.year, from: start)
        guard calendar.component(.month, from: start) != 1 else { return String(first) }
        return "\(first)/\(String(format: "%02d", (first + 1) % 100))"
    }

    var range: String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
        return "\(start.formatted(.dateTime.day().month(.abbreviated).year())) - \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    func moved(by years: Int) -> LeaveYear {
        LeaveYear(containing: Calendar.current.date(byAdding: .year, value: years, to: start) ?? start, startMonth: Calendar.current.component(.month, from: start))
    }

    var years: ClosedRange<Int> {
        let calendar = Calendar.current
        let first = calendar.component(.year, from: start)
        return first...calendar.component(.year, from: calendar.date(byAdding: .day, value: -1, to: end) ?? end)
    }
}

/// A person's allowance for a leave year and what they've used of it.
struct LeaveSummary {
    /// The full-year allowance before any pro-rating: theirs, or the org's.
    let base: Double
    /// Their working days a week over the org's, when part time counts.
    let partTime: Double?
    /// Share of the leave year they're employed, when less than all of it.
    let employed: Double?
    let carriedOver: Double
    /// Pro-rated and rounded up to a half day, plus carried over.
    let allowance: Double
    let taken: Double
    let booked: Double
    let sickDays: Double
    /// Separate stretches of sickness in the year.
    let sickSpells: Int

    var remaining: Double { allowance - taken - booked }

    /// How the allowance was reached, for the tooltip.
    var explanation: String {
        var steps = ["\(Self.number(base)) days a year"]
        if let partTime { steps.append("× \(Self.number(partTime)) part time") }
        if let employed { steps.append("× \(Int((employed * 100).rounded()))% of the year employed") }
        var text = steps.joined(separator: " ")
        if partTime != nil || employed != nil { text += ", rounded up to a half day" }
        if carriedOver != 0 { text += ", \(carriedOver > 0 ? "+" : "")\(Self.number(carriedOver)) carried over" }
        return text + " = \(Self.number(allowance))"
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    init(dates: PersonDates, policy: LeavePolicy, orgWeek: WorkWeek, working: WorkingCalendar, year: LeaveYear, today: Date = .now) {
        let calendar = Calendar.current
        base = dates.allowance ?? policy.allowance

        // Part time only scales the org's allowance; one set for the person
        // is already theirs.
        if dates.allowance == nil, policy.proRataPartTime, let own = dates.workWeek, !orgWeek.days.isEmpty, own.days.count != orgWeek.days.count {
            partTime = Double(own.days.count) / Double(orgWeek.days.count)
        } else {
            partTime = nil
        }

        let from = max(year.start, dates.startDate.map { calendar.startOfDay(for: $0) } ?? year.start)
        let to = min(year.end, dates.endDate.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? year.end)
        let yearDays = Double(calendar.dateComponents([.day], from: year.start, to: year.end).day ?? 365)
        let employedDays = Double(max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0))
        employed = employedDays < yearDays ? employedDays / yearDays : nil

        carriedOver = dates.carryOver?[year.key] ?? 0
        let scaled = base * (partTime ?? 1) * (employed ?? 1)
        let rounded = partTime == nil && employed == nil ? scaled : (scaled * 2).rounded(.up) / 2
        allowance = rounded + carriedOver

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) ?? today
        let past = dates.daysOff(from: year.start, to: min(tomorrow, year.end), working: working)
        let future = tomorrow < year.end ? dates.daysOff(from: max(tomorrow, year.start), to: year.end, working: working) : [:]
        taken = past[.holiday] ?? 0
        booked = future[.holiday] ?? 0
        sickDays = (past[.sick] ?? 0) + (future[.sick] ?? 0)
        sickSpells = dates.absences.filter { absence in
            guard absence.kind == .sick else { return false }
            let (start, end) = absence.interval(calendar: calendar)
            return start < year.end && end > year.start
        }.count
    }
}

// MARK: - Settings

/// Settings: the leave year, the allowance and part-time pro-rating.
struct LeavePolicySection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    var body: some View {
        let policy = configs.config(for: org).leavePolicy
        Section {
            Picker("Leave year starts", selection: binding(\.yearStartMonth)) {
                ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
            }
            LabeledContent("Allowance") {
                HStack(spacing: 6) {
                    TextField("Allowance", value: binding(\.allowance), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Allowance", value: binding(\.allowance), in: 0...100, step: 0.5)
                        .labelsHidden()
                    Text("days a year").foregroundStyle(.secondary)
                }
            }
            Toggle("Pro-rate for part-time patterns", isOn: binding(\.proRataPartTime))
            LabeledContent("This leave year", value: LeaveYear(containing: .now, startMonth: policy.yearStartMonth).range)
        } header: {
            Text("Holiday allowance")
        } footer: {
            Text("In working days, with bank holidays on top. Each person's is pro-rated by the share of the leave year between their start and end dates and, for their own pattern, by working days a week, then rounded up to a half day. Anyone can have their own allowance and carried-over days in their Time off.")
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LeavePolicy, Value>) -> Binding<Value> {
        Binding {
            configs.config(for: org).leavePolicy[keyPath: keyPath]
        } set: { value in
            configs.update(org) { config in
                var policy = config.leavePolicy
                policy[keyPath: keyPath] = value
                config.leave = policy == LeavePolicy() ? nil : policy
            }
        }
    }
}

// MARK: - Person

/// In a person's Time off: their allowance this leave year, their own
/// allowance if they have one, and days carried over into it.
struct PersonAllowanceSection: View {
    @Environment(PeopleDatesStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let person: Person

    var body: some View {
        let config = configs.config(for: org)
        let policy = config.leavePolicy
        let year = LeaveYear(containing: .now, startMonth: policy.yearStartMonth)
        let dates = store.dates(for: person.login, in: org)
        let working = store.workingCalendar(for: person.login, in: org, orgWeek: config.week, holidays: holidayStore, years: year.years)
        let summary = LeaveSummary(dates: dates, policy: policy, orgWeek: config.week, working: working, year: year)
        Section {
            LabeledContent("Allowance \(year.label)") {
                Text("\(LeaveSummary.number(summary.allowance)) days")
                    .monospacedDigit()
                    .help(summary.explanation)
            }
            LabeledContent("Used") {
                Text("\(LeaveSummary.number(summary.taken)) taken, \(LeaveSummary.number(summary.booked)) booked, \(LeaveSummary.number(summary.remaining)) left")
                    .monospacedDigit()
                    .foregroundStyle(summary.remaining < 0 ? .red : .primary)
            }
            Toggle("Own allowance", isOn: Binding {
                dates.allowance != nil
            } set: { on in
                store.update(person.login, in: org) { $0.allowance = on ? policy.allowance : nil }
            })
            if let own = dates.allowance {
                LabeledContent("Days a year") {
                    HStack(spacing: 6) {
                        TextField("Days a year", value: allowanceBinding(own), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Stepper("Days a year", value: allowanceBinding(own), in: 0...100, step: 0.5)
                            .labelsHidden()
                    }
                }
            }
            LabeledContent("Carried over into \(year.label)") {
                HStack(spacing: 6) {
                    TextField("Carried over", value: carryBinding(year), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Carried over", value: carryBinding(year), in: -50...50, step: 0.5)
                        .labelsHidden()
                }
            }
        } header: {
            Text("Holiday allowance")
        } footer: {
            Text(dates.allowance == nil
                 ? "The org's allowance, pro-rated for their start and end dates and working pattern. \(summary.explanation)."
                 : "Their own full-year allowance, pro-rated for their start and end dates only. \(summary.explanation).")
                .foregroundStyle(.secondary)
        }
    }

    private func allowanceBinding(_ current: Double) -> Binding<Double> {
        Binding {
            store.dates(for: person.login, in: org).allowance ?? current
        } set: { value in
            store.update(person.login, in: org) { $0.allowance = max(0, value) }
        }
    }

    private func carryBinding(_ year: LeaveYear) -> Binding<Double> {
        Binding {
            store.dates(for: person.login, in: org).carryOver?[year.key] ?? 0
        } set: { value in
            store.update(person.login, in: org) { dates in
                var carry = dates.carryOver ?? [:]
                carry[year.key] = value == 0 ? nil : value
                dates.carryOver = carry.isEmpty ? nil : carry
            }
        }
    }
}

// MARK: - Report

/// The Allowance tab of Time off: each person's holiday allowance for a
/// leave year, pro-rated, against what they've taken and booked, with their
/// sickness alongside.
struct LeaveReportView: View {
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let workload: Workload?

    /// Leave years back (negative) or on from the current one.
    @State private var offset = 0
    @State private var sort: StatsSort?
    @State private var editing: Person?

    struct Row: Identifiable {
        let person: Person
        let dates: PersonDates
        let summary: LeaveSummary

        var id: String { person.login }
    }

    var body: some View {
        let config = configs.config(for: org)
        let year = LeaveYear(containing: .now, startMonth: config.leavePolicy.yearStartMonth).moved(by: offset)
        let rows = rows(year)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        totals(rows)
                        StatsTable(
                            rows: rows,
                            columns: columns(rows),
                            sort: $sort,
                            selectedID: nil,
                            onSelect: { editing = $0.person },
                            contextMenu: { row in AnyView(Button("Dates and Time Off") { editing = row.person }) }
                        )
                        Text("Allowances are in working days, bank holidays on top, pro-rated for start and end dates and part-time patterns and rounded up to a half day. Taken is up to today; booked is after it. Click someone to edit their time off, allowance or carried-over days; the org's allowance and leave year are in Settings.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader {
                        HStack(spacing: 12) {
                            Text("Allowance")
                            Text("\(year.label) · \(year.range)")
                                .foregroundStyle(.secondary)
                                .fontWeight(.regular)
                            Spacer(minLength: 8)
                            ControlGroup {
                                Button { offset -= 1 } label: { Label("Earlier", systemImage: "chevron.left") }
                                    .help("Previous leave year")
                                Button("This Year") { offset = 0 }
                                    .disabled(offset == 0)
                                Button { offset += 1 } label: { Label("Later", systemImage: "chevron.right") }
                                    .help("Next leave year")
                            }
                            .fixedSize()
                            .font(.body)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(year.key) \(regions.hashValue)") {
            await holidayStore.load(regions, years: year.years)
        }
        .sheet(item: $editing) { person in
            PersonDatesSheet(org: org, person: person)
        }
    }

    private var people: [Person] {
        (workload?.people.map(\.person) ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var regions: Set<BankHolidayRegion> {
        let orgRegion = configs.config(for: org).week.holidays
        return Set(people.compactMap { peopleDates.region(for: $0.login, in: org, default: orgRegion) })
    }

    /// People employed at some point in the year.
    private func rows(_ year: LeaveYear) -> [Row] {
        let config = configs.config(for: org)
        return people.compactMap { person in
            let dates = peopleDates.dates(for: person.login, in: org)
            if let start = dates.startDate, start >= year.end { return nil }
            if let end = dates.endDate, end < year.start { return nil }
            let working = peopleDates.workingCalendar(for: person.login, in: org, orgWeek: config.week, holidays: holidayStore, years: year.years)
            return Row(person: person, dates: dates, summary: LeaveSummary(dates: dates, policy: config.leavePolicy, orgWeek: config.week, working: working, year: year))
        }
    }

    private func totals(_ rows: [Row]) -> some View {
        let allowance = rows.map(\.summary.allowance).reduce(0, +)
        let taken = rows.map(\.summary.taken).reduce(0, +)
        let booked = rows.map(\.summary.booked).reduce(0, +)
        let sick = rows.map(\.summary.sickDays).reduce(0, +)
        return HStack(spacing: 28) {
            total("People", "\(rows.count)")
            total("Allowance", LeaveSummary.number(allowance))
            total("Taken", LeaveSummary.number(taken))
            total("Booked", LeaveSummary.number(booked))
            total("Left", LeaveSummary.number(allowance - taken - booked))
            total("Sick days", LeaveSummary.number(sick))
            Spacer()
        }
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func columns(_ rows: [Row]) -> [StatsColumn<Row>] {
        func days(_ value: Double) -> String { LeaveSummary.number(value) }
        return [
            StatsColumn(
                id: "person", title: "Person", help: "Org members in view employed during the leave year",
                width: nil, minWidth: 200,
                sortKey: { .text($0.person.displayName.lowercased()) },
                cell: { row in
                    AnyView(HStack(spacing: 8) {
                        Avatar(url: row.person.avatarUrl, size: 22)
                        Text(row.person.displayName).lineLimit(1)
                        if let note = Self.employmentNote(row.dates) {
                            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    })
                }
            ),
            StatsColumn(
                id: "allowance", title: "Allowance", help: "Days for this leave year, pro-rated, plus carried over",
                width: 90, group: "Holiday",
                sortKey: { .number($0.summary.allowance) },
                cell: { row in
                    AnyView(HStack(spacing: 4) {
                        NumberCell(text: days(row.summary.allowance), dimmed: false)
                        if row.summary.partTime != nil || row.summary.employed != nil || row.summary.carriedOver != 0 || row.dates.allowance != nil {
                            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(row.summary.explanation))
                }
            ),
            StatsColumn(
                id: "taken", title: "Taken", help: "Holiday days up to today",
                width: 70, group: "Holiday",
                sortKey: { .number($0.summary.taken) },
                cell: { row in AnyView(NumberCell(text: days(row.summary.taken), dimmed: row.summary.taken == 0)) }
            ),
            StatsColumn(
                id: "booked", title: "Booked", help: "Holiday days booked after today",
                width: 70, group: "Holiday",
                sortKey: { .number($0.summary.booked) },
                cell: { row in AnyView(NumberCell(text: days(row.summary.booked), dimmed: row.summary.booked == 0)) }
            ),
            StatsColumn(
                id: "remaining", title: "Left", help: "Allowance less taken and booked",
                width: 150, group: "Holiday",
                sortKey: { .number($0.summary.remaining) },
                cell: { row in AnyView(AllowanceBar(summary: row.summary)) }
            ),
            StatsColumn(
                id: "sick", title: "Days", help: "Sick days in the leave year, working days only",
                width: 64, group: "Sick",
                sortKey: { .number($0.summary.sickDays) },
                cell: { row in AnyView(NumberCell(text: days(row.summary.sickDays), dimmed: row.summary.sickDays == 0)) }
            ),
            StatsColumn(
                id: "spells", title: "Spells", help: "Separate stretches of sickness in the leave year",
                width: 64, group: "Sick",
                sortKey: { .number(Double($0.summary.sickSpells)) },
                cell: { row in AnyView(NumberCell(text: "\(row.summary.sickSpells)", dimmed: row.summary.sickSpells == 0)) }
            ),
        ]
    }

    private static func employmentNote(_ dates: PersonDates) -> String? {
        if let end = dates.endDate { return "leaves \(end.formatted(.dateTime.day().month(.abbreviated).year()))" }
        if let start = dates.startDate, start > Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now {
            return "started \(start.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
        return nil
    }
}

/// Days left, with a bar of taken, booked and left against the allowance.
private struct AllowanceBar: View {
    let summary: LeaveSummary

    var body: some View {
        HStack(spacing: 8) {
            Text(LeaveSummary.number(summary.remaining))
                .monospacedDigit()
                .foregroundStyle(summary.remaining < 0 ? .red : .primary)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geometry in
                let total = max(summary.allowance, summary.taken + summary.booked, 0.01)
                let width = geometry.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(Absence.Kind.holiday.color)
                        .frame(width: width * summary.taken / total)
                    Rectangle().fill(Absence.Kind.holiday.color.opacity(0.4))
                        .frame(width: width * summary.booked / total)
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
        }
        .help("\(LeaveSummary.number(summary.taken)) taken, \(LeaveSummary.number(summary.booked)) booked, \(LeaveSummary.number(summary.remaining)) left of \(LeaveSummary.number(summary.allowance))")
    }
}

// MARK: - One person's report

/// The Report view of a person's Time off: their allowance for a leave year
/// and what they've used, holiday and sickness by month, every entry in the
/// year, and the leave years before it.
struct PersonLeaveReport: View {
    @Environment(PeopleDatesStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let person: Person

    @State private var offset = 0
    @State private var editing: Absence?

    /// Leave years shown under History, this one included.
    private static let historyYears = 4

    var body: some View {
        let config = configs.config(for: org)
        let year = LeaveYear(containing: .now, startMonth: config.leavePolicy.yearStartMonth).moved(by: offset)
        let dates = store.dates(for: person.login, in: org)
        let summary = summary(year)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 24) {
                        tiles(summary)
                        Text(summary.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        byMonth(year, dates: dates)
                        entries(year, dates: dates)
                        history(year)
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader {
                        HStack(spacing: 12) {
                            Text(year.label)
                            Text(year.range)
                                .foregroundStyle(.secondary)
                                .fontWeight(.regular)
                            Spacer(minLength: 8)
                            ControlGroup {
                                Button { offset -= 1 } label: { Label("Earlier", systemImage: "chevron.left") }
                                    .help("Previous leave year")
                                Button("This Year") { offset = 0 }
                                    .disabled(offset == 0)
                                Button { offset += 1 } label: { Label("Later", systemImage: "chevron.right") }
                                    .help("Next leave year")
                            }
                            .fixedSize()
                            .font(.body)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(year.key) \(region.hashValue)") {
            if let region {
                let first = year.moved(by: -(Self.historyYears - 1)).years.lowerBound
                await holidayStore.load([region], years: first...year.years.upperBound)
            }
        }
        .sheet(item: $editing) { absence in
            AbsenceSheet(org: org, person: person, absence: absence)
        }
    }

    private var region: BankHolidayRegion? {
        store.region(for: person.login, in: org, default: configs.config(for: org).week.holidays)
    }

    private func working(_ year: LeaveYear) -> WorkingCalendar {
        store.workingCalendar(for: person.login, in: org, orgWeek: configs.config(for: org).week, holidays: holidayStore, years: year.years)
    }

    private func summary(_ year: LeaveYear) -> LeaveSummary {
        let config = configs.config(for: org)
        return LeaveSummary(dates: store.dates(for: person.login, in: org), policy: config.leavePolicy, orgWeek: config.week, working: working(year), year: year)
    }

    // MARK: Tiles

    private func tiles(_ summary: LeaveSummary) -> some View {
        HStack(alignment: .top, spacing: 28) {
            tile("Allowance", summary.allowance)
            tile("Taken", summary.taken)
            tile("Booked", summary.booked)
            tile("Left", summary.remaining, warn: summary.remaining < 0)
            tile("Sick days", summary.sickDays)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.sickSpells)").font(.title2.weight(.semibold).monospacedDigit())
                Text(summary.sickSpells == 1 ? "Sick spell" : "Sick spells").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func tile(_ title: String, _ value: Double, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LeaveSummary.number(value))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? .red : .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: By month

    /// Working days off in each month of the leave year, holiday and sick
    /// side by side.
    private func byMonth(_ year: LeaveYear, dates: PersonDates) -> some View {
        let calendar = Calendar.current
        let working = working(year)
        let months = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: year.start) }
        let counts = months.map { month -> (Date, [Absence.Kind: Double]) in
            let end = calendar.date(byAdding: .month, value: 1, to: month) ?? month
            return (month, dates.daysOff(from: month, to: end, working: working))
        }
        let most = max(1, counts.map { $0.1.values.reduce(0, +) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("By month").font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(counts, id: \.0) { month, kinds in
                    VStack(spacing: 4) {
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            ForEach(Absence.Kind.allCases.reversed(), id: \.self) { kind in
                                if let days = kinds[kind], days > 0 {
                                    Rectangle()
                                        .fill(kind.color)
                                        .frame(height: 90 * days / most)
                                }
                            }
                        }
                        .frame(height: 90)
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(String(month.formatted(.dateTime.month(.abbreviated)).prefix(3)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help("\(month.formatted(.dateTime.month(.wide).year())): \(Absence.days(kinds[.holiday] ?? 0)) holiday, \(Absence.days(kinds[.sick] ?? 0)) sick")
                }
            }
            HStack(spacing: 14) {
                ForEach(Absence.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 10, height: 10)
                        Text(kind.rawValue)
                    }
                }
            }
            .font(.caption)
        }
    }

    // MARK: Entries

    /// Every stretch of time off in the leave year, newest first.
    private func entries(_ year: LeaveYear, dates: PersonDates) -> some View {
        let calendar = Calendar.current
        let working = working(year)
        let inYear = dates.absences.filter { absence in
            let (start, end) = absence.interval(calendar: calendar)
            return start < year.end && end > year.start
        }
        .sorted { $0.start > $1.start }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Time off in \(year.label)").font(.headline)
            if inYear.isEmpty {
                Text("None recorded.").foregroundStyle(.secondary)
            }
            ForEach(inYear) { absence in
                let (from, to) = absence.interval(calendar: calendar)
                let days = PersonDates(absences: [absence]).daysOff(from: max(from, year.start), to: min(to, year.end), working: working).values.reduce(0, +)
                HStack(spacing: 10) {
                    Circle().fill(absence.kind.color).frame(width: 8, height: 8)
                    Text(absence.kind.rawValue).frame(width: 60, alignment: .leading)
                    Text(PersonDatesSections.range(absence))
                    Text(Absence.days(days)).foregroundStyle(.secondary).monospacedDigit()
                    if !absence.note.isEmpty {
                        Text(absence.note).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if absence.start > Date.now {
                        Text("Booked").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { editing = absence }
                .contextMenu {
                    Button("Edit") { editing = absence }
                    Button("Remove", role: .destructive) {
                        store.update(person.login, in: org) { $0.absences.removeAll { $0.id == absence.id } }
                    }
                }
            }
        }
    }

    // MARK: History

    /// This leave year and the ones before it, side by side.
    private func history(_ year: LeaveYear) -> some View {
        let years = (0..<Self.historyYears).map { year.moved(by: -$0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Leave year")
                    Text("Allowance")
                    Text("Holiday")
                    Text("Left")
                    Text("Sick days")
                    Text("Spells")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(years, id: \.self) { leaveYear in
                    let summary = summary(leaveYear)
                    GridRow {
                        Text(leaveYear.label)
                        Text(LeaveSummary.number(summary.allowance)).help(summary.explanation)
                        Text(LeaveSummary.number(summary.taken + summary.booked))
                        Text(LeaveSummary.number(summary.remaining)).foregroundStyle(summary.remaining < 0 ? .red : .primary)
                        Text(LeaveSummary.number(summary.sickDays))
                        Text("\(summary.sickSpells)")
                    }
                    .monospacedDigit()
                    .opacity(isEmployed(in: leaveYear) ? 1 : 0.4)
                }
            }
        }
    }

    private func isEmployed(in year: LeaveYear) -> Bool {
        let dates = store.dates(for: person.login, in: org)
        if let start = dates.startDate, start >= year.end { return false }
        if let end = dates.endDate, end < year.start { return false }
        return true
    }
}
