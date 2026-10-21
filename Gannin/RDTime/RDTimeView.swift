import SwiftUI

/// The R&D Time page under Delivery: each person's working hours over a
/// range, allocated to the issues they worked on, with those that count as
/// R&D (and how much of each, and why), by issue or by person, exported for
/// an accountant or adviser. Its activity is fetched only from here, after
/// showing what it will cost (`RDActivityStore`), never by Refresh.
struct RDTimeView: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(RDActivityStore.self) private var activity
    @Environment(AuthStore.self) private var auth
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(BankHolidayStore.self) private var holidayStore
    @Environment(HiddenStore.self) private var hidden
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.navigate) private var navigate

    let org: String
    let workload: Workload?

    @SceneStorage("rdTab") private var tab: Tab = .work
    /// An `RDRange`'s raw value, or `period:` and one of the org's periods.
    @SceneStorage("rdRange") private var rangeChoice: String = RDRange.thisYear.rawValue
    @SceneStorage("rdFrom") private var customFrom: Double = Date.now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970
    @SceneStorage("rdTo") private var customTo: Double = Date.now.timeIntervalSince1970
    @SceneStorage("rdOnlyCounted") private var onlyCounted = true
    @State private var workSort: StatsSort?
    @State private var peopleSort: StatsSort?
    /// The issue whose mark is being edited.
    @State private var editing: RDWorkItem?
    /// A fetch priced and waiting to be confirmed.
    @State private var pending: RDActivityStore.Plan?
    @State private var planError: String?

    enum Tab: String, CaseIterable {
        case work = "By issue"
        case people = "By person"
    }

    private var config: OrgConfig { configs.config(for: org) }

    private static let periodPrefix = "period:"

    /// The org's period picked, if it still exists.
    private var period: AccountingPeriod? {
        guard rangeChoice.hasPrefix(Self.periodPrefix), let id = UUID(uuidString: String(rangeChoice.dropFirst(Self.periodPrefix.count))) else { return nil }
        return config.accountingCalendar.period(id: id)
    }

    /// The preset picked; a period that's gone reads as this year.
    private var rangePreset: RDRange { RDRange(rawValue: rangeChoice) ?? .thisYear }

    private var range: DateInterval {
        if let period { return period.interval }
        return rangePreset.interval(yearStart: config.accountingCalendar.year, customFrom: Date(timeIntervalSince1970: customFrom), customTo: Date(timeIntervalSince1970: customTo))
    }

    var body: some View {
        let range = range
        let name = config.rndConfig.displayName
        let cache = activity.cache(for: org)
        let report = cache.map { report($0, range: range) }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                fetchPanel(cache, range: range)
                if let report {
                    summary(report, name: name)
                    switch tab {
                    case .work: workTable(report, name: name)
                    case .people: peopleTable(report, name: name)
                    }
                    footnote(name: name)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { toolbar(report, range: range, name: name) }
        .outsideReposNotice(org: org)
        .sheet(item: $editing) { item in
            RDMarkEditor(org: org, item: item, name: name)
        }
        // A plan priced for one range doesn't hold for another.
        .onChange(of: rangeChoice) { pending = nil }
        .onChange(of: customFrom) { pending = nil }
        .task(id: "\(years(range)) \(regions.hashValue)") {
            await holidayStore.load(regions, years: years(range))
        }
    }

    // MARK: Fetching

    /// What's fetched for the range, and the way to fetch more: priced
    /// first, confirmed here, with progress and Cancel while it runs.
    @ViewBuilder
    private func fetchPanel(_ cache: RDActivityStore.Cache?, range: DateInterval) -> some View {
        let reaches = cache.map { $0.coveredFrom <= range.start } ?? false
        let current = cache.map { $0.fetchedAt >= min(range.end, .now) } ?? false
        if let progress = activity.progress[org] {
            panel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Fetching activity").font(.headline)
                        Spacer()
                        Button("Cancel") { activity.cancel(org) }
                    }
                    ProgressView(value: Double(progress.weeksDone), total: Double(max(progress.weeks, 1)))
                    Text("\(progress.step): \(progress.weeksDone) of \(progress.weeks) weeks, \(progress.pullRequests) pull requests, \(progress.issues) issues\(progress.records > 0 ? ", \(progress.records) issues looked up" : "")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else if let pending {
            confirmation(pending)
        } else if !reaches || cache == nil {
            panel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(cache == nil ? "No activity fetched yet" : "Activity reaches back to \(Self.day(cache?.coveredFrom))").font(.headline)
                    Text("R&D Time fetches commits, reviews and issue comments only when you ask, since a long range takes a search per week. The range starts \(Self.day(range.start)). See what fetching it would take first; nothing is fetched until you confirm.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    estimateButton(range: range)
                    notice
                }
            }
        } else if let cache {
            HStack(spacing: 8) {
                Text("Activity fetched back to \(Self.day(cache.coveredFrom)), last \(cache.fetchedAt.formatted(.relative(presentation: .named))).")
                    .foregroundStyle(.secondary)
                if !current { estimateButton(range: range, title: "Update") }
                notice
            }
            .font(.callout)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var notice: some View {
        if let message = planError ?? activity.notices[org] {
            Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func estimateButton(range: DateInterval, title: String = "See What It Takes") -> some View {
        HStack(spacing: 8) {
            Button(title) {
                planError = nil
                Task {
                    do {
                        let plan = try await activity.plan(org: org, from: range.start, through: range.end)
                        if plan.isEmpty { return }
                        pending = plan
                    } catch {
                        planError = "Couldn't count what to fetch: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(activity.estimating.contains(org))
            if activity.estimating.contains(org) {
                ProgressView().controlSize(.small)
                Text("Counting").foregroundStyle(.secondary)
            }
        }
    }

    /// The plan's cost, against what's left of the budget, to confirm.
    private func confirmation(_ plan: RDActivityStore.Plan) -> some View {
        let budget = auth.rateLimit
        return panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fetch activity back to \(Self.day(plan.start))?").font(.headline)
                Text("\(plan.weeks.count) weekly searches, finding about \(plan.pullRequests) pull requests and \(plan.issues) issues, then the issues they worked on are looked up for what counts.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("About \(plan.requests) requests and \(plan.points) points of GitHub's hourly budget\(budget.map { ", with \($0.remaining) of \($0.limit) left until \($0.resetAt.formatted(date: .omitted, time: .shortened))" } ?? ""). It stops before the last \(RDActivityStore.reserve) points, so the rest of Gannin keeps working, and you can cancel at any time; what's fetched is kept.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.weeks.contains(where: { $0.pullRequests > RDActivityStore.Plan.searchCap || $0.issues > RDActivityStore.Plan.searchCap }) {
                    Text("Some weeks have more than \(RDActivityStore.Plan.searchCap) results, GitHub's limit for a search, so part of them can't be fetched.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Fetch") {
                        activity.fetch(plan)
                        pending = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Not Now") { pending = nil }
                }
            }
        }
    }

    private static func day(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }

    // MARK: Data

    /// Everyone with activity or on the team, but those left out of the
    /// org's stats.
    private func people(_ cache: RDActivityStore.Cache) -> Set<String> {
        var logins = Set(workload?.people.map(\.person.login) ?? [])
        for pr in cache.pullRequests.values {
            if let author = pr.author { logins.insert(author) }
            logins.formUnion(pr.commits.compactMap(\.author))
            logins.formUnion(pr.reviews.map(\.author))
        }
        for issue in cache.issues.values { logins.formUnion(issue.comments.map(\.author)) }
        return logins.filter { !config.excludes($0) }
    }

    private var regions: Set<BankHolidayRegion> {
        let orgRegion = config.week.holidays
        guard let cache = activity.cache(for: org) else { return [] }
        return Set(people(cache).compactMap { peopleDates.region(for: $0, in: org, default: orgRegion) })
    }

    private func years(_ range: DateInterval) -> ClosedRange<Int> {
        let calendar = Calendar.current
        let first = calendar.component(.year, from: range.start)
        return first...max(first, calendar.component(.year, from: range.end))
    }

    /// The range's part that's been fetched: from where coverage reaches.
    private func report(_ cache: RDActivityStore.Cache, range: DateInterval) -> RDReport {
        let config = config
        let rnd = config.rndConfig
        let people = people(cache)
        let years = years(range)
        let covered = DateInterval(start: max(range.start, Calendar.current.startOfDay(for: cache.coveredFrom)), end: max(range.end, cache.coveredFrom))
        let calendars = Dictionary(uniqueKeysWithValues: people.map {
            ($0, peopleDates.workingCalendar(for: $0, in: org, orgWeek: config.week, holidays: holidayStore, years: years))
        })
        let dates = Dictionary(uniqueKeysWithValues: people.map { ($0, peopleDates.dates(for: $0, in: org)) })
        let found = RDActivityAllocator.allocate(.init(
            people: people, range: covered,
            pullRequests: cache.pullRequests.values.filter { !hidden.keys.contains($0.id) && !config.repoExclusion.contains($0.repo) },
            issues: cache.issues.values.filter { !hidden.keys.contains($0.id) && !config.repoExclusion.contains($0.repo) },
            calendars: calendars, dates: dates, orgCalendar: holidayStore.calendar(week: config.week, region: config.week.holidays, years: years),
            options: rnd.activityOptions
        ))
        // The issue history's copy when it has one (kept current by the
        // regular sync), else the one looked up for R&D Time.
        let history = issueStore.history(for: org)?.issues ?? [:]
        func record(_ id: String) -> IssueRecord? { history[id] ?? cache.records[id] }
        let investments = config.investmentConfig
        return RDReport(found) { item in
            let found = record(item.id)
            return rnd.status(item.id, record: found, parent: found?.parentID.flatMap(record), investments: investments)
        }
    }

    private var names: [String: String] {
        Dictionary((workload?.people.map(\.person) ?? []).map { ($0.login, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// How the numbers were found, for the page and the export.
    private func method(name: String) -> String {
        let rnd = config.rndConfig
        let options = rnd.activityOptions
        var counted = ["commits"]
        if options.reviews { counted.append("reviews") }
        if options.comments { counted.append("issue comments") }
        return "\(name) work: \(rnd.qualifiedBy.summary.lowercased()), plus issues marked by hand. Time: \(rnd.timeSources.map(\.name).joined(separator: ", ").lowercased()), each working day's hours (less bank holidays and leave) split \(options.splitBy == .even ? "evenly" : "by activity") across the work touched by \(counted.joined(separator: ", ")); quiet days go to \(options.quiet == .openWork ? "the person's open pull requests" : "nothing (unallocated)")."
    }

    // MARK: Summary

    private func summary(_ report: RDReport, name: String) -> some View {
        HStack(alignment: .top, spacing: 32) {
            stat("\(name) hours", Self.hours(report.rdHours), detail: report.available > 0 ? "\(RDExport.percent(report.rdHours / report.available)) of working hours" : nil)
            stat("Working hours", Self.hours(report.available), detail: "\(report.people.count) people")
            stat("Allocated", Self.hours(report.hours), detail: "\(report.work.count) issues and pull requests")
            stat("Unallocated", Self.hours(report.unallocated), detail: "Working days with nothing to show")
        }
    }

    private func stat(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func footnote(name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(method(name: name))
            Text("Hours only: no salaries, rates or costs are recorded. Which work qualifies under a given scheme is for the claimant and their adviser to decide.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: By issue

    private func workTable(_ report: RDReport, name: String) -> some View {
        let rows = onlyCounted ? report.rdWork : report.work
        return VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text(onlyCounted ? "Nothing counts as \(name) in this range. Right-click an issue under Everything to mark it, or set what counts in Settings › R&D." : "No activity in this range.")
                    .foregroundStyle(.secondary)
            } else {
                StatsTable(rows: rows, columns: workColumns(name: name), sort: $workSort, selectedID: nil, onSelect: open, contextMenu: { row in
                    AnyView(markMenu(row.item, name: name))
                }, destination: { row in
                    row.item.kind == .issue ? .issueReference(reference(row.item)) : nil
                })
            }
        }
    }

    private func workColumns(name: String) -> [StatsColumn<RDReport.WorkRow>] {
        [
            StatsColumn(id: "work", title: "Issue", help: "The issue, or a pull request that closes none", minWidth: 280,
                        sortKey: { .text($0.item.title) },
                        cell: { row in AnyView(VStack(alignment: .leading, spacing: 2) {
                            Text(row.item.title).lineLimit(1)
                            Text(row.item.kind == .issue ? row.item.reference : "\(row.item.reference), pull request").font(.caption).foregroundStyle(.secondary)
                        }) }),
            StatsColumn(id: "counts", title: name, help: "Whether it counts, how much of it, and why", width: 150,
                        sortKey: { .number($0.status?.share ?? -1) },
                        cell: { row in AnyView(Self.statusCell(row.status)) }),
            StatsColumn(id: "hours", title: "Hours", help: "Hours allocated to it in the range", width: 70, alignment: .trailing,
                        sortKey: { .number($0.hours) },
                        cell: { row in AnyView(Text(Self.hours(row.hours)).monospacedDigit()) }),
            StatsColumn(id: "rd", title: "\(name) hours", help: "Hours times its share", width: 90, alignment: .trailing,
                        sortKey: { .number($0.rdHours) },
                        cell: { row in AnyView(Text(Self.hours(row.rdHours)).monospacedDigit()) }),
            StatsColumn(id: "people", title: "People", help: "Who the hours are from", width: 200,
                        sortKey: { .number(Double($0.people.count)) },
                        cell: { row in AnyView(Text(row.people.sorted { $0.value > $1.value }.map { "\($0.key) \(Self.hours($0.value))" }.joined(separator: ", ")).lineLimit(2).font(.caption)) }),
            StatsColumn(id: "rationale", title: "Rationale", help: "Why it counts, as marked", width: 220,
                        sortKey: { .text($0.status?.rationale ?? "") },
                        cell: { row in AnyView(Text(row.status?.rationale ?? "").lineLimit(2).font(.caption).foregroundStyle(.secondary)) }),
        ]
    }

    private static func statusCell(_ status: RDStatus?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status {
                Text(status.share < 1 ? "Yes, \(RDExport.percent(status.share))" : "Yes")
                Text(status.basis.rawValue).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func markMenu(_ item: RDWorkItem, name: String) -> some View {
        if item.kind == .issue {
            let mark = config.rndConfig.mark(item.id)
            Button("Count as \(name)") { setMark(item, RDMark(counts: true, share: mark?.share, rationale: mark?.rationale, issue: item.reference)) }
            Button("Don't Count as \(name)") { setMark(item, RDMark(counts: false, rationale: mark?.rationale, issue: item.reference)) }
            Button("Edit \(name) Mark") { editing = item }
            if mark != nil {
                Divider()
                Button("Clear Mark") { setMark(item, nil) }
            }
        } else {
            Text("Only issues can count as \(name)")
        }
    }

    private func setMark(_ item: RDWorkItem, _ mark: RDMark?) {
        configs.updateRD(org) { rnd in
            var marks = rnd.marks ?? [:]
            marks[item.id] = mark
            rnd.marks = marks.isEmpty ? nil : marks
        }
    }

    private func reference(_ item: RDWorkItem) -> IssueReference {
        IssueReference(org: org, id: item.id, number: item.number, title: item.title, repo: item.repo, url: item.url)
    }

    private func open(_ row: RDReport.WorkRow) {
        guard row.item.kind == .issue else { return openURL(row.item.url) }
        let reference = reference(row.item)
        if let navigate { navigate(.issueReference(reference)) } else { openWindow(value: reference) }
    }

    // MARK: By person

    private func peopleTable(_ report: RDReport, name: String) -> some View {
        StatsTable(rows: report.people, columns: personColumns(name: name), sort: $peopleSort, selectedID: nil, onSelect: { _ in })
    }

    private func personColumns(name: String) -> [StatsColumn<RDReport.PersonRow>] {
        let names = names
        func number(_ id: String, _ title: String, _ help: String, _ value: @escaping (RDReport.PersonRow) -> Double) -> StatsColumn<RDReport.PersonRow> {
            StatsColumn(id: id, title: title, help: help, width: 110, alignment: .trailing,
                        sortKey: { .number(value($0)) },
                        cell: { row in AnyView(Text(Self.hours(value(row))).monospacedDigit()) })
        }
        return [
            StatsColumn(id: "who", title: "Person", help: "Who", minWidth: 200,
                        sortKey: { .text(names[$0.login] ?? $0.login) },
                        cell: { row in AnyView(VStack(alignment: .leading, spacing: 2) {
                            Text(names[row.login] ?? row.login)
                            if names[row.login] != nil { Text(row.login).font(.caption).foregroundStyle(.secondary) }
                        }) }),
            number("available", "Working hours", "Their working days' hours in the range, less bank holidays and leave", \.available),
            number("allocated", "Allocated", "Hours placed on issues and pull requests", \.allocated),
            number("unallocated", "Unallocated", "Working hours with nothing to place them on", \.unallocated),
            number("rd", "\(name) hours", "Allocated hours on work that counts, times its share", \.rdHours),
            StatsColumn(id: "share", title: "\(name) share", help: "\(name) hours as a share of working hours", width: 90, alignment: .trailing,
                        sortKey: { .number($0.rdShare) },
                        cell: { row in AnyView(Text(RDExport.percent(row.rdShare)).monospacedDigit()) }),
        ]
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ report: RDReport?, range: DateInterval, name: String) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if tab == .work {
                Picker("Show", selection: $onlyCounted) {
                    Text(name).tag(true)
                    Text("Everything").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Only work that counts as \(name), or everything with time on it")
            }
            Picker("Range", selection: Binding { period.map { Self.periodPrefix + $0.id.uuidString } ?? rangePreset.rawValue } set: { rangeChoice = $0 }) {
                ForEach(RDRange.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0.rawValue) }
                let periods = config.accountingCalendar.namedPeriods
                if !periods.isEmpty {
                    Divider()
                    ForEach(periods) { Text($0.name).tag(Self.periodPrefix + $0.id.uuidString) }
                }
                Divider()
                Text(RDRange.custom.rawValue).tag(RDRange.custom.rawValue)
            }
            .fixedSize()
            .help("\(range.start.formatted(date: .abbreviated, time: .omitted)) to \(RDExport.lastDay(range).formatted(date: .abbreviated, time: .omitted))")
            if period == nil, rangePreset == .custom {
                DatePicker("From", selection: date($customFrom), displayedComponents: .date)
                    .labelsHidden()
                DatePicker("To", selection: date($customTo), displayedComponents: .date)
                    .labelsHidden()
            }
            Menu {
                ForEach(RDExport.allCases) { export in
                    Button(export.rawValue) {
                        guard let report else { return }
                        export.save(report, name: name, range: range, method: method(name: name), names: names)
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(report == nil)
            .help("Save the report as CSV or Markdown")
            Menu {
                Button("Forget Fetched Activity") {
                    pending = nil
                    activity.clear(org)
                }
                .disabled(activity.cache(for: org) == nil || activity.isFetching(org))
            } label: {
                Label("Activity", systemImage: "ellipsis.circle")
            }
            .help("The activity fetched for R&D Time, kept on this Mac")
        }
    }

    private func date(_ seconds: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: seconds.wrappedValue) }, set: { seconds.wrappedValue = $0.timeIntervalSince1970 })
    }

    static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// Marks an issue by hand: whether it counts, how much of it, and why.
private struct RDMarkEditor: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.dismiss) private var dismiss

    let org: String
    let item: RDWorkItem
    let name: String

    @State private var counts = true
    @State private var percent = 100
    @State private var rationale = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Issue") { Text("\(item.title) (\(item.reference))").lineLimit(2) }
                    Toggle("Counts as \(name)", isOn: $counts)
                    if counts {
                        Stepper(value: $percent, in: 5...100, step: 5) {
                            LabeledContent("Share", value: "\(percent)%")
                        }
                    }
                } footer: {
                    Text("A share below 100% counts only that part of the issue's hours.")
                        .foregroundStyle(.secondary)
                }
                Section("Rationale") {
                    TextEditor(text: $rationale)
                        .frame(minHeight: 90)
                        .font(.body)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear {
            guard let mark = configs.config(for: org).rndConfig.mark(item.id) else { return }
            counts = mark.counts
            percent = Int((mark.clampedShare * 100).rounded())
            rationale = mark.rationale ?? ""
        }
    }

    private func save() {
        let mark = RDMark(counts: counts, share: counts && percent < 100 ? Double(percent) / 100 : nil, rationale: rationale.isEmpty ? nil : rationale, issue: item.reference)
        configs.updateRD(org) { rnd in
            var marks = rnd.marks ?? [:]
            marks[item.id] = mark
            rnd.marks = marks
        }
        dismiss()
    }
}
