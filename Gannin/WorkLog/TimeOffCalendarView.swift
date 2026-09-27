import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the time off calendar shows at once.
enum CalendarScale: String, CaseIterable {
    case year = "Year"
    case month = "Month"
    case week = "Week"

    var component: Calendar.Component {
        switch self {
        case .year: .year
        case .month: .month
        case .week: .weekOfYear
        }
    }
}

/// The Time off page under People: the calendar and the allowance report
/// as tabs.
struct TimeOffPage: View {
    enum Tab: String, CaseIterable {
        case calendar = "Calendar"
        case allowance = "Allowance"
    }

    let org: String
    let workload: Workload?

    @AppStorage("timeOffTab") private var tab: Tab = .calendar

    var body: some View {
        Group {
            switch tab {
            case .calendar: TimeOffCalendarView(org: org, workload: workload)
            case .allowance: LeaveReportView(org: org, workload: workload)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The Time off calendar: booked holidays and sick days for
/// everyone in view (or one person), by year, month or week. Only working
/// days are marked, by each person's own pattern and bank holidays.
struct TimeOffCalendarView: View {
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let workload: Workload?
    /// Just this person, from their person view; no person picker.
    var fixedPerson: Person? = nil

    @AppStorage("timeOffScale") private var scale: CalendarScale = .month
    @State private var anchor = Calendar.current.startOfDay(for: .now)
    /// One person's login, or nil for everyone.
    @State private var focus: String?
    @State private var editing: Person?
    /// Days picked by clicking (Shift-click extends), and in the week view
    /// whose row they're in.
    @State private var selectionStart: Date?
    @State private var selectionEnd: Date?
    @State private var selectionPerson: String?
    @State private var adding: NewTimeOff?
    /// Bank holiday regions left off the calendar, comma separated.
    @AppStorage("timeOffHiddenHolidayRegions") private var hiddenRegionKeys = ""

    /// Time off being added from the calendar.
    private struct NewTimeOff: Identifiable {
        let id = UUID()
        let person: Person
        let absence: Absence
        /// New time off can be for anyone; an existing entry stays theirs.
        var choosable = true
    }

    private let calendar = Calendar.metrics

    var body: some View {
        let range = range
        let entries = TimeOffEntries(people: shownPeople, org: org, from: range.start, to: range.end, dates: peopleDates, calendars: calendars(range), holidays: shownHolidays(range))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        switch scale {
                        case .year: yearView(entries)
                        case .month: fullMonthView(month: anchor, entries: entries)
                        case .week: weekView(entries, range: range)
                        }
                        legend
                    }
                    .sectionContent()
                } header: {
                    // In a person's view the calendar is one column of
                    // several, so its controls stay with it; on the Time off
                    // page they're the window's toolbar.
                    if fixedPerson != nil {
                        PinnedHeader { controls }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            if fixedPerson == nil {
                ToolbarItem {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                ToolbarItemGroup { controlItems }
            }
        }
        .task(id: "\(years(range)) \(regions.hashValue)") {
            await holidayStore.load(regions, years: years(range))
        }
        .sheet(item: $editing) { person in
            PersonDatesSheet(org: org, person: person)
        }
        .sheet(item: $adding) { new in
            AbsenceSheet(org: org, person: new.person, absence: new.absence, choosable: new.choosable ? people : [])
        }
        .onEscape { clearSelection() }
        .onChange(of: scale) { clearSelection() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Text("Time off")
            Text(title)
                .foregroundStyle(.secondary)
                .fontWeight(.regular)
            Spacer(minLength: 8)
            Group { controlItems }
                .font(.body)
        }
    }

    @ViewBuilder
    private var controlItems: some View {
                Button {
                    addTimeOff()
                } label: {
                    Label(addTitle, systemImage: "plus")
                }
                .disabled(people.isEmpty)
                .help("Click a day to pick it, Shift-click to pick a run of days")
                Menu {
                    ForEach(holidayRegions, id: \.self) { region in
                        Toggle(regionName(region), isOn: regionBinding(region))
                    }
                    Divider()
                    Button("Show All") { hiddenRegionKeys = "" }
                    Button("Show None") { hiddenRegionKeys = holidayRegions.map(Self.regionKey).joined(separator: ",") }
                } label: {
                    Label("Bank Holidays", systemImage: "flag")
                }
                .fixedSize()
                .disabled(holidayRegions.isEmpty)
                .help(holidayRegions.isEmpty ? "Set a bank holiday region in Settings > Working week" : "Which regions' bank holidays to show")
                if fixedPerson == nil {
                    Picker("Person", selection: $focus) {
                        Text("Everyone").tag(String?.none)
                        Divider()
                        ForEach(people) { Text($0.displayName).tag(Optional($0.login)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("Scale", selection: $scale) {
                    ForEach(CalendarScale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ControlGroup {
                    Button { move(-1) } label: { Label("Earlier", systemImage: "chevron.left") }
                        .help("Earlier")
                    Button("Today") { anchor = Calendar.current.startOfDay(for: .now) }
                    Button { move(1) } label: { Label("Later", systemImage: "chevron.right") }
                        .help("Later")
                }
                .fixedSize()
    }

    // MARK: Selection

    private var selectedDays: ClosedRange<Date>? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }
        return min(start, end)...max(start, end)
    }

    private func isSelected(_ day: Date, person: String? = nil) -> Bool {
        guard let range = selectedDays, range.contains(day) else { return false }
        return selectionPerson == nil || selectionPerson == person
    }

    /// Click picks a day; Shift-click extends from the first one picked, in
    /// the same row in the week view.
    private func select(_ day: Date, person: String? = nil) {
        if Self.extending, selectionStart != nil, selectionPerson == person {
            selectionEnd = day
        } else if isSelected(day, person: person), selectionStart == selectionEnd {
            clearSelection()
        } else {
            selectionStart = day
            selectionEnd = day
            selectionPerson = person
        }
    }

    /// Shift held on a Mac; on iPad a second tap in a row extends instead
    /// (see `select`), so this is only the Mac's.
    private static var extending: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    private func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
        selectionPerson = nil
    }

    private var addTitle: String {
        guard let range = selectedDays else { return "Add Time Off" }
        let days = (Calendar.current.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0) + 1
        return days == 1 ? "Add Time Off on \(range.lowerBound.formatted(.dateTime.day().month(.abbreviated)))" : "Add Time Off (\(days) days)"
    }

    /// Opens the time off sheet for the picked days (or today), for the
    /// picked row's person, the one in focus, or the first to choose from.
    private func addTimeOff(on day: Date? = nil, person login: String? = nil) {
        let today = Calendar.current.startOfDay(for: .now)
        let range = day.map { day in isSelected(day, person: login) ? selectedDays ?? day...day : day...day } ?? selectedDays ?? today...today
        let chosen = login ?? selectionPerson ?? focus
        guard let person = people.first(where: { $0.login == chosen }) ?? shownPeople.first ?? people.first else { return }
        adding = NewTimeOff(person: person, absence: Absence(kind: .holiday, start: range.lowerBound, end: range.upperBound))
    }

    private func move(_ step: Int) {
        anchor = calendar.date(byAdding: scale.component, value: step, to: anchor) ?? anchor
    }

    private var title: String {
        switch scale {
        case .year: return anchor.formatted(.dateTime.year())
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            let range = range
            let last = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            return "\(range.start.formatted(.dateTime.day().month(.abbreviated))) - \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    // MARK: Range and people

    /// `[start, end)` of the year, the month's full weeks, or the week.
    private var range: (start: Date, end: Date) {
        switch scale {
        case .year:
            let interval = calendar.dateInterval(of: .year, for: anchor)
            return (interval?.start ?? anchor, interval?.end ?? anchor)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: anchor)
            let start = calendar.startOfWeek(for: interval?.start ?? anchor)
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval?.end ?? anchor) ?? anchor
            let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfWeek(for: lastDay)) ?? anchor
            return (start, end)
        case .week:
            let start = calendar.startOfWeek(for: anchor)
            return (start, calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        }
    }

    private func years(_ range: (start: Date, end: Date)) -> ClosedRange<Int> {
        let first = calendar.component(.year, from: range.start)
        let last = calendar.component(.year, from: calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end)
        return first...max(first, last)
    }

    /// Members in view (team and exclusions applied), by name.
    private var people: [Person] {
        if let fixedPerson { return [fixedPerson] }
        return (workload?.people.map(\.person) ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var shownPeople: [Person] {
        focus.map { login in people.filter { $0.login == login } } ?? people
    }

    private var regions: Set<BankHolidayRegion> {
        let orgRegion = configs.config(for: org).week.holidays
        return Set(people.compactMap { peopleDates.region(for: $0.login, in: org, default: orgRegion) } + [orgRegion].compactMap { $0 })
    }

    /// Regions the calendar can show bank holidays for, by name: the org's
    /// and anyone's own.
    private var holidayRegions: [BankHolidayRegion] {
        regions.sorted { regionName($0).localizedCaseInsensitiveCompare(regionName($1)) == .orderedAscending }
    }

    private func regionName(_ region: BankHolidayRegion) -> String {
        PersonDatesSections.regionName(region, holidayStore)
    }

    private static func regionKey(_ region: BankHolidayRegion) -> String {
        region.subdivision ?? region.country
    }

    private var hiddenRegions: Set<String> {
        Set(hiddenRegionKeys.split(separator: ",").map(String.init))
    }

    private func regionBinding(_ region: BankHolidayRegion) -> Binding<Bool> {
        Binding {
            !hiddenRegions.contains(Self.regionKey(region))
        } set: { shown in
            var hidden = hiddenRegions
            if shown { hidden.remove(Self.regionKey(region)) } else { hidden.insert(Self.regionKey(region)) }
            hiddenRegionKeys = hidden.sorted().joined(separator: ",")
        }
    }

    /// Bank holidays in the shown regions, the same holiday in several
    /// regions listed once with all of them.
    private func shownHolidays(_ range: (start: Date, end: Date)) -> [String: [TimeOffEntries.Holiday]] {
        let week = configs.config(for: org).week
        var byDay: [String: [String: [String]]] = [:]
        for region in holidayRegions where !hiddenRegions.contains(Self.regionKey(region)) {
            let name = regionName(region)
            for (day, holiday) in holidayStore.calendar(week: week, region: region, years: years(range)).holidays {
                byDay[day, default: [:]][holiday, default: []].append(name)
            }
        }
        return byDay.mapValues { names in
            names.map { TimeOffEntries.Holiday(name: $0.key, regions: $0.value) }.sorted { $0.name < $1.name }
        }
    }

    private func calendars(_ range: (start: Date, end: Date)) -> [String: WorkingCalendar] {
        let week = configs.config(for: org).week
        let years = years(range)
        return Dictionary(uniqueKeysWithValues: people.map {
            ($0.login, peopleDates.workingCalendar(for: $0.login, in: org, orgWeek: week, holidays: holidayStore, years: years))
        })
    }

    /// The org's own calendar, for bank holiday names and days off in the grid.
    private func orgCalendar(_ range: (start: Date, end: Date)) -> WorkingCalendar {
        let week = configs.config(for: org).week
        return holidayStore.calendar(week: week, region: week.holidays, years: years(range))
    }

    // MARK: Year

    private func yearView(_ entries: TimeOffEntries) -> some View {
        let start = range.start
        let months = (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
            ForEach(months, id: \.self) { month in
                monthView(month: month, entries: entries, compact: true)
            }
        }
    }

    // MARK: Month

    /// A month grid, Monday first. Compact is the year view's mini month:
    /// a tinted day per booking, detail on hover, click to open that week.
    private func monthView(month: Date, entries: TimeOffEntries, compact: Bool) -> some View {
        let interval = calendar.dateInterval(of: .month, for: month)
        let first = calendar.startOfWeek(for: interval?.start ?? month)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval?.end ?? month) ?? month
        let weeks = (calendar.dateComponents([.weekOfYear], from: first, to: calendar.startOfWeek(for: lastDay)).weekOfYear ?? 0) + 1
        let orgWorking = orgCalendar((first, calendar.date(byAdding: .day, value: weeks * 7, to: first) ?? first))
        let columns = Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 0), count: 7)
        return VStack(alignment: .leading, spacing: compact ? 6 : 0) {
            if compact {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.headline)
            }
            LazyVGrid(columns: columns, spacing: compact ? 2 : 0) {
                ForEach(WorkWeek.weekdays, id: \.self) { weekday in
                    Text(compact ? String(WorkWeek.name(weekday).prefix(1)) : WorkWeek.name(weekday).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, compact ? 0 : 6)
                }
                ForEach(0..<(weeks * 7), id: \.self) { offset in
                    let day = calendar.date(byAdding: .day, value: offset, to: first) ?? first
                    let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                    if compact {
                        miniDay(day, inMonth: inMonth, entries: entries.on(day), holidays: entries.holidays(on: day), working: orgWorking)
                    } else {
                        monthDay(day, inMonth: inMonth, entries: entries.on(day), holidays: entries.holidays(on: day), working: orgWorking)
                    }
                }
            }
            .overlay {
                if !compact { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            }
        }
    }

    private func miniDay(_ day: Date, inMonth: Bool, entries: [TimeOffEntries.Entry], holidays: [TimeOffEntries.Holiday], working: WorkingCalendar) -> some View {
        let holiday = holidays.isEmpty ? nil : Self.holidayText(holidays)
        let tint = Self.tint(entries, holiday: holiday)
        let isToday = Calendar.current.isDateInToday(day)
        return Text(day.formatted(.dateTime.day()))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(inMonth ? (working.isWorkingDay(day) ? .primary : .secondary) : .quaternary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background {
                if inMonth, let tint {
                    let halves = Set(entries.map(\.half))
                    if halves.count == 1, let half = halves.first ?? nil {
                        // Only half days that day, all the same half.
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(tint.color.opacity(tint.strength))
                                .frame(width: geometry.size.width / 2)
                                .offset(x: half == .afternoon ? geometry.size.width / 2 : 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(tint.color.opacity(tint.strength), lineWidth: 1) }
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(tint.color.opacity(tint.strength))
                    }
                }
            }
            .overlay {
                if isToday { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.6)) }
            }
            .overlay {
                if isSelected(day) { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(Rectangle())
            .help(inMonth ? Self.detail(day, entries: entries, holiday: holiday) : "")
            .onTapGesture(count: 2) {
                anchor = day
                scale = .week
            }
            .onTapGesture { if inMonth { select(day) } }
            .contextMenu { dayMenu(day) }
    }

    /// The month as week rows: each day's number and bank holiday, with
    /// time off drawn over them as bars that run across the days they
    /// cover, stacked when they overlap.
    private func fullMonthView(month: Date, entries: TimeOffEntries) -> some View {
        let interval = calendar.dateInterval(of: .month, for: month)
        let first = calendar.startOfWeek(for: interval?.start ?? month)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval?.end ?? month) ?? month
        let weeks = (calendar.dateComponents([.weekOfYear], from: first, to: calendar.startOfWeek(for: lastDay)).weekOfYear ?? 0) + 1
        let orgWorking = orgCalendar((first, calendar.date(byAdding: .day, value: weeks * 7, to: first) ?? first))
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(WorkWeek.weekdays, id: \.self) { weekday in
                    Text(WorkWeek.name(weekday).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(0..<weeks, id: \.self) { index in
                    let weekStart = calendar.date(byAdding: .day, value: index * 7, to: first) ?? first
                    monthWeek(weekStart, month: month, entries: entries, working: orgWorking)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
    }

    private static let dayHeader: CGFloat = 26
    private static let barHeight: CGFloat = 24
    private static let barGap: CGFloat = 3

    private func monthWeek(_ weekStart: Date, month: Date, entries: TimeOffEntries, working: WorkingCalendar) -> some View {
        let spans = TimeOffSpans(people: shownPeople, org: org, weekStart: weekStart, dates: peopleDates, calendar: calendar)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        // Bank holidays take the top lanes, time off the ones below.
        let holidayLanes = days.map { entries.holidays(on: $0).count }.max() ?? 0
        let lanes = holidayLanes + spans.lanes
        let height = max(104, Self.dayHeader + CGFloat(lanes) * (Self.barHeight + Self.barGap) + 8)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    monthDay(day, inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month), entries: entries.on(day), holidays: entries.holidays(on: day), working: working)
                }
            }
            GeometryReader { geometry in
                let column = geometry.size.width / 7
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    ForEach(Array(entries.holidays(on: day).enumerated()), id: \.element.id) { lane, holiday in
                        holidayBar(holiday)
                            .frame(width: column - 4, height: Self.barHeight)
                            .offset(x: CGFloat(index) * column + 2, y: Self.dayHeader + CGFloat(lane) * (Self.barHeight + Self.barGap))
                    }
                }
                ForEach(spans.spans) { span in
                    spanBar(span, showAvatar: true)
                        .frame(width: span.width(column: column) - 4, height: Self.barHeight)
                        .offset(x: span.x(column: column) + 2, y: Self.dayHeader + CGFloat(holidayLanes + span.lane) * (Self.barHeight + Self.barGap))
                }
            }
        }
        .frame(height: height)
    }

    private func monthDay(_ day: Date, inMonth: Bool, entries: [TimeOffEntries.Entry], holidays: [TimeOffEntries.Holiday], working: WorkingCalendar) -> some View {
        let holiday = holidays.isEmpty ? nil : Self.holidayText(holidays)
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? AnyShapeStyle(Color.accentColor) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected(day) ? Color.accentColor.opacity(0.15) : working.isWorkingDay(day) || !inMonth ? Color.clear : Color.secondary.opacity(0.08))
        .border(.separator.opacity(0.5), width: 0.5)
        .contentShape(Rectangle())
        .help(Self.detail(day, entries: entries, holiday: holiday))
        .onTapGesture(count: 2) {
            anchor = day
            scale = .week
        }
        .onTapGesture { select(day) }
        .contextMenu { dayMenu(day) }
    }

    /// A bank holiday as a one-day bar, naming its regions when more than
    /// one is shown.
    private func holidayBar(_ holiday: TimeOffEntries.Holiday) -> some View {
        let showRegions = holidayRegions.filter { !hiddenRegions.contains(Self.regionKey($0)) }.count > 1
        return HStack(spacing: 4) {
            Image(systemName: "flag.fill").font(.caption2)
            Text(showRegions ? "\(holiday.name) · \(holiday.regions.joined(separator: ", "))" : holiday.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(TimelineMark.bankHoliday.opacity(0.35)))
        .help("Bank holiday: \(holiday.name)\n\(holiday.regions.joined(separator: ", "))")
    }

    static func holidayText(_ holidays: [TimeOffEntries.Holiday]) -> String {
        holidays.map { "\($0.name) (\($0.regions.joined(separator: ", ")))" }.joined(separator: "; ")
    }

    /// One stretch of time off within a week, squared off where it carries
    /// on from the week before or into the next. Click to edit it.
    private func spanBar(_ span: TimeOffSpans.Span, showAvatar: Bool) -> some View {
        let absence = span.absence
        let leading: CGFloat = span.continuesBefore ? 0 : 5
        let trailing: CGFloat = span.continuesAfter ? 0 : 5
        var parts: [String] = []
        let half = absence.halfDay()
        parts.append(half.map { "\(absence.kind.rawValue) (\($0.rawValue.lowercased()))" } ?? absence.kind.rawValue)
        if !absence.note.isEmpty { parts.append(absence.note) }
        return HStack(spacing: 4) {
            // The avatar says who, on every week the bar spans; the name is
            // in the tooltip.
            if showAvatar {
                Avatar(url: span.person.avatarUrl, size: 20)
            }
            Text(parts.joined(separator: " · "))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 5)
        .background(
            ZStack {
                let shape = UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading, bottomTrailingRadius: trailing, topTrailingRadius: trailing)
                if let half {
                    // Half a day: outlined, with its half (morning on the
                    // left) filled.
                    shape.fill(absence.kind.color.opacity(0.1))
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(absence.kind.color.opacity(0.4))
                            .frame(width: geometry.size.width / 2)
                            .offset(x: half == .afternoon ? geometry.size.width / 2 : 0)
                    }
                    .clipShape(shape)
                    shape.strokeBorder(absence.kind.color.opacity(0.6), lineWidth: 1)
                } else {
                    shape.fill(absence.kind.color.opacity(0.35))
                }
            }
        )
        .contentShape(Rectangle())
        .help("\(span.person.displayName): \(absence.label)\n\(PersonDatesSections.range(absence))")
        .onTapGesture {
            adding = NewTimeOff(person: span.person, absence: absence, choosable: false)
        }
        .contextMenu {
            Button("Edit") { adding = NewTimeOff(person: span.person, absence: absence, choosable: false) }
            Button("Remove", role: .destructive) {
                peopleDates.update(span.person.login, in: org) { $0.absences.removeAll { $0.id == absence.id } }
            }
            Divider()
            Button("Dates and Time Off") { editing = span.person }
        }
    }

    // MARK: Week

    /// People down the side, the week's days across, each cell marked as the
    /// work log marks it: time off, bank holidays, days off.
    private func weekView(_ entries: TimeOffEntries, range: (start: Date, end: Date)) -> some View {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: range.start) }
        let calendars = calendars(range)
        let week = configs.config(for: org).week
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: WorkLogPage.nameWidth)
                ForEach(days, id: \.self) { day in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(.medium).monospacedDigit())
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            Divider()
            let holidayLanes = days.map { entries.holidays(on: $0).count }.max() ?? 0
            if holidayLanes > 0 {
                HStack(spacing: 0) {
                    Label("Bank holidays", systemImage: "flag")
                        .foregroundStyle(.secondary)
                        .frame(width: WorkLogPage.nameWidth, alignment: .leading)
                    ForEach(days, id: \.self) { day in
                        VStack(spacing: Self.barGap) {
                            ForEach(entries.holidays(on: day)) { holiday in
                                holidayBar(holiday).frame(height: Self.barHeight)
                            }
                        }
                        .padding(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .leading) { Divider() }
                    }
                }
                .frame(height: 8 + CGFloat(holidayLanes) * (Self.barHeight + Self.barGap))
                Divider()
            }
            ForEach(shownPeople) { person in
                let working = calendars[person.login] ?? WorkingCalendar(week: week)
                let dates = peopleDates.dates(for: person.login, in: org)
                let spans = TimeOffSpans(people: [person], org: org, weekStart: range.start, dates: peopleDates, calendar: calendar)
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Avatar(url: person.avatarUrl, size: 22)
                        Text(person.displayName).lineLimit(1)
                    }
                    .frame(width: WorkLogPage.nameWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = person }
                    .personDatesMenu(person, org: org)
                    ForEach(days, id: \.self) { day in
                        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                        ZStack {
                            if !working.isWorkingDay(day) {
                                Rectangle().fill(.quaternary.opacity(0.35))
                            }
                            // Time off is drawn as bars over the row; cells
                            // keep bank holidays and not started or left.
                            if let mark = dates.mark(from: day, to: end, isDay: true, working: working), !Self.isAbsent(dates, on: day) {
                                TimelineMarkView(mark: mark)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isSelected(day, person: person.login) ? Color.accentColor.opacity(0.18) : Color.clear)
                        .overlay(alignment: .leading) { Divider() }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { addTimeOff(on: day, person: person.login) }
                        .onTapGesture { select(day, person: person.login) }
                        .contextMenu {
                            Button(isSelected(day, person: person.login) ? addTitle.replacingOccurrences(of: "Add Time Off", with: "Add Time Off for \(person.displayName)") : "Add Time Off for \(person.displayName)") {
                                addTimeOff(on: day, person: person.login)
                            }
                            Button("Dates and Time Off") { editing = person }
                        }
                        .help(Self.detail(day, entries: entries.on(day).filter { $0.person.login == person.login }, holiday: working.holiday(on: day)))
                    }
                }
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        let column = (geometry.size.width - WorkLogPage.nameWidth) / 7
                        ForEach(spans.spans) { span in
                            spanBar(span, showAvatar: false)
                                .frame(width: span.width(column: column) - 4, height: Self.barHeight)
                                .offset(x: WorkLogPage.nameWidth + span.x(column: column) + 2, y: 12 + CGFloat(span.lane) * (Self.barHeight + Self.barGap))
                        }
                    }
                }
                .frame(height: max(44, 24 + CGFloat(spans.lanes) * (Self.barHeight + Self.barGap)))
                Divider()
            }
        }
    }

    private static func isAbsent(_ dates: PersonDates, on day: Date) -> Bool {
        if case .absent = dates.status(on: day) { return true }
        return false
    }

    /// Right-click on a day: add time off for it (or the picked days it's in).
    @ViewBuilder
    private func dayMenu(_ day: Date) -> some View {
        let label = isSelected(day) ? addTitle : "Add Time Off on \(day.formatted(.dateTime.day().month(.abbreviated)))"
        Button(label) { addTimeOff(on: day) }
        if selectedDays != nil {
            Button("Clear Selection") { clearSelection() }
        }
    }

    // MARK: Legend and detail

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(Absence.Kind.allCases, id: \.self) { kind in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(kind.color.opacity(0.5)).frame(width: 14, height: 10)
                    Text(kind.rawValue)
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(TimelineMark.bankHoliday.opacity(0.5)).frame(width: 14, height: 10)
                Text("Bank holiday")
            }
            Text(scale == .year
                 ? "Darker days have more people off. Hover a day for who; click to pick, Shift-click for a run, double-click to open its week."
                 : "Bars run from first to last day; only working days count towards totals. Click a bar to edit it, click days to pick them (Shift-click for a run), then Add Time Off.")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.callout)
    }

    /// The colour and strength for a mini day: one person's kind, or the
    /// share of people off, holiday or sick by whichever is more.
    private static func tint(_ entries: [TimeOffEntries.Entry], holiday: String?) -> (color: Color, strength: Double)? {
        if entries.isEmpty {
            return holiday == nil ? nil : (TimelineMark.bankHoliday, 0.35)
        }
        let sick = entries.filter { $0.kind == .sick }.count
        let color = sick * 2 > entries.count ? Absence.Kind.sick.color : Absence.Kind.holiday.color
        return (color, min(0.85, 0.3 + 0.12 * Double(entries.count - 1)))
    }

    private static func detail(_ day: Date, entries: [TimeOffEntries.Entry], holiday: String?) -> String {
        var lines = [day.formatted(date: .complete, time: .omitted)]
        if let holiday { lines.append("Bank holiday: \(holiday)") }
        for entry in entries {
            var line = "\(entry.person.displayName): \(entry.kind.rawValue.lowercased())"
            if let half = entry.half { line += " (\(half.rawValue.lowercased()))" }
            if !entry.note.isEmpty { line += ", \(entry.note)" }
            lines.append(line)
        }
        if entries.isEmpty && holiday == nil { lines.append("Nobody off") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Model

/// Who is off on each day of a range, on their own working days only.
struct TimeOffEntries {
    struct Entry: Identifiable {
        let person: Person
        let kind: Absence.Kind
        let half: Absence.HalfDay?
        let note: String

        var id: String { "\(person.login) \(kind.rawValue) \(half?.rawValue ?? "")" }
    }

    /// A bank holiday on the calendar, with the regions it's in.
    struct Holiday: Identifiable, Hashable {
        let name: String
        let regions: [String]

        var id: String { name }
    }

    private var byDay: [String: [Entry]] = [:]
    /// Bank holidays in the regions being shown, by `yyyy-MM-dd`.
    let holidays: [String: [Holiday]]

    func holidays(on day: Date) -> [Holiday] { holidays[WorkingCalendar.key(day)] ?? [] }

    init(people: [Person], org: String, from: Date, to: Date, dates: PeopleDatesStore, calendars: [String: WorkingCalendar], holidays: [String: [Holiday]] = [:]) {
        self.holidays = holidays
        let calendar = Calendar.current
        for person in people {
            guard let working = calendars[person.login] else { continue }
            for absence in dates.dates(for: person.login, in: org).absences {
                let (start, end) = absence.interval(calendar: calendar)
                guard start < to, end > from else { continue }
                var day = max(calendar.startOfDay(for: start), calendar.startOfDay(for: from))
                while day < min(end, to) {
                    if working.isWorkingDay(day, calendar: calendar) {
                        byDay[WorkingCalendar.key(day, calendar: calendar), default: []].append(
                            Entry(person: person, kind: absence.kind, half: absence.halfDay(calendar: calendar), note: absence.note)
                        )
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
        }
    }

    func on(_ day: Date) -> [Entry] {
        (byDay[WorkingCalendar.key(day)] ?? []).sorted { $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending }
    }
}

/// Each stretch of time off in one week, as columns and lanes: a bar runs
/// from its first to its last day (weekends included, as a calendar shows
/// it) and takes the first lane free across its days.
struct TimeOffSpans {
    struct Span: Identifiable {
        let person: Person
        let absence: Absence
        /// Columns covered, 0 for Monday.
        let first: Int
        let last: Int
        let continuesBefore: Bool
        let continuesAfter: Bool
        var lane = 0

        var id: String { "\(person.login) \(absence.id)" }

        func x(column: CGFloat) -> CGFloat {
            CGFloat(first) * column
        }

        /// A half day keeps its whole column; the bar fills only its half.
        func width(column: CGFloat) -> CGFloat {
            CGFloat(last - first + 1) * column
        }
    }

    let spans: [Span]
    let lanes: Int

    init(people: [Person], org: String, weekStart: Date, dates: PeopleDatesStore, calendar: Calendar) {
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        func column(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: date)).day ?? 0
        }
        var found: [Span] = []
        for person in people {
            for absence in dates.dates(for: person.login, in: org).absences {
                let start = calendar.startOfDay(for: absence.start)
                let end = calendar.startOfDay(for: max(absence.end, absence.start))
                guard start < weekEnd, end >= weekStart else { continue }
                found.append(Span(
                    person: person,
                    absence: absence,
                    first: max(0, column(start)),
                    last: min(6, column(end)),
                    continuesBefore: start < weekStart,
                    continuesAfter: end >= weekEnd
                ))
            }
        }
        // Longest first from each start, then each takes the first free lane.
        found.sort { ($0.first, -($0.last - $0.first), $0.person.displayName) < ($1.first, -($1.last - $1.first), $1.person.displayName) }
        var laneEnds: [Int] = []
        for index in found.indices {
            if let lane = laneEnds.firstIndex(where: { $0 < found[index].first }) {
                found[index].lane = lane
                laneEnds[lane] = found[index].last
            } else {
                found[index].lane = laneEnds.count
                laneEnds.append(found[index].last)
            }
        }
        spans = found
        lanes = laneEnds.count
    }
}
