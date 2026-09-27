import SwiftUI

/// How much time each column covers.
enum WorkLogScale: String, CaseIterable, Identifiable {
    case days = "Days"
    case weeks = "Weeks"

    var id: Self { self }

    /// Columns per page.
    var columns: Int { self == .days ? 14 : 12 }
}

/// The pages listed under People in the sidebar: Activity (drawn from the
/// work log's PR activity) and the time off calendar.
enum PeopleView: String, CaseIterable, Hashable {
    case activity = "Activity"
    case timeOff = "Time off"

    var systemImage: String {
        switch self {
        case .activity: "circle.grid.3x3"
        case .timeOff: "calendar"
        }
    }
}

/// The Activity page's tabs.
enum ActivityView: String, CaseIterable, Hashable {
    case workLog = "Work log"
    case threads = "Threads"
    case punchcards = "Punchcards"
}

/// The Activity page under People: Work log, Threads and Punchcards as tabs
/// over one page of days or weeks, the tabs, scale and paging in the pinned
/// header (the page stays put when switching tabs). The work log is people down the side, days or weeks
/// across the top, and a cluster of dots per cell, one per commit, review,
/// PR opened and PR merged; Threads and Punchcards draw the same activity
/// another way.
struct WorkLogPage: View {
    @Environment(WorkLogStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HiddenStore.self) private var hidden
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(BankHolidayStore.self) private var holidayStore
    @Environment(\.openWindow) private var openWindow

    let org: String
    let workload: Workload?
    @AppStorage("activityTab") private var view: ActivityView = .workLog
    @AppStorage("workLogScale") private var scale: WorkLogScale = .days
    /// Pages back from the current one.
    @State private var pagesBack = 0

    static let nameWidth: CGFloat = 170
    private static let rowHeight: CGFloat = 104
    /// How far back paging goes.
    private static let maxDaysBack = 365

    var body: some View {
        let columns = columns
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content(columns)
                        .padding(.horizontal, view == .punchcards ? 20 : 8)
                        .padding(.top, view == .punchcards ? 14 : 0)
                        .padding(.bottom, 28)
                } header: {
                    PinnedHeader { controls(columns) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(org) \(columns.first?.start.timeIntervalSince1970 ?? 0)") {
            await store.sync(org, from: columns.first?.start)
        }
        .task(id: "\(years(columns)) \(regions.hashValue)") {
            await holidayStore.load(regions, years: years(columns))
        }
        .onChange(of: scale) { pagesBack = 0 }
    }

    /// Everyone's bank holiday regions, the org's included.
    private var regions: Set<BankHolidayRegion> {
        let orgRegion = configs.config(for: org).week.holidays
        return Set(people.compactMap { peopleDates.region(for: $0.login, in: org, default: orgRegion) })
    }

    private func years(_ columns: [WorkLogGrid.Column]) -> ClosedRange<Int> {
        let calendar = Calendar.current
        let first = calendar.component(.year, from: columns.first?.start ?? .now)
        let last = calendar.component(.year, from: columns.last?.end ?? .now)
        return first...max(first, last)
    }

    /// Each person's working days on this page: their pattern or the org's
    /// week, less their bank holidays.
    private func workingCalendars(_ columns: [WorkLogGrid.Column]) -> [String: WorkingCalendar] {
        let week = configs.config(for: org).week
        let years = years(columns)
        return Dictionary(uniqueKeysWithValues: people.map { person in
            (person.login, peopleDates.workingCalendar(for: person.login, in: org, orgWeek: week, holidays: holidayStore, years: years))
        })
    }

    @ViewBuilder
    private func content(_ columns: [WorkLogGrid.Column]) -> some View {
        VStack(spacing: 0) {
            if let history = store.history(for: org) {
                let config = configs.config(for: org)
                let calendars = workingCalendars(columns)
                switch view {
                case .workLog:
                    let grid = WorkLogGrid(history: history, columns: columns, scale: scale, people: people, config: config, hidden: hidden.keys)
                    header(columns)
                    Divider()
                    ForEach(grid.rows, id: \.person.login) { row in
                        rowView(row, columns: columns, working: calendars[row.person.login] ?? WorkingCalendar(week: config.week))
                        Divider()
                    }
                    legend
                case .threads:
                    header(columns)
                    Divider()
                    ThreadsContent(org: org, pullRequests: history.pullRequests(config: config, hidden: hidden.keys), columns: columns, scale: scale, people: people, calendars: calendars, week: config.week)
                case .punchcards:
                    PunchcardContent(org: org, pullRequests: history.pullRequests(config: config, hidden: hidden.keys), columns: columns, people: people, calendars: calendars, week: config.week)
                }
            } else if let error = store.errors[org] {
                ContentUnavailableView {
                    Label("Couldn't load the work log", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await store.sync(org, force: true) } }
                }
                .frame(minHeight: 160)
            } else {
                ProgressView("Loading recent activity")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func controls(_ columns: [WorkLogGrid.Column]) -> some View {
        HStack(spacing: 12) {
            Picker("View", selection: $view) {
                ForEach(ActivityView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .font(.body)
            Text(Self.rangeLabel(columns))
                .foregroundStyle(.secondary)
                .fontWeight(.regular)
            if store.syncing.contains(org) {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 8)
            Group {
                Picker("Scale", selection: $scale) {
                    ForEach(WorkLogScale.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("What each column covers")
                ControlGroup {
                    Button { pagesBack += 1 } label: { Label("Earlier", systemImage: "chevron.left") }
                        .disabled(!canGoBack)
                        .help("Earlier")
                    Button("Today") { pagesBack = 0 }
                        .disabled(pagesBack == 0)
                    Button { pagesBack -= 1 } label: { Label("Later", systemImage: "chevron.right") }
                        .disabled(pagesBack == 0)
                        .help("Later")
                }
                .fixedSize()
            }
            .font(.body)
        }
    }

    // MARK: Range

    /// The page's columns, oldest first, each `[start, end)`.
    private var columns: [WorkLogGrid.Column] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        switch scale {
        case .days:
            let last = calendar.date(byAdding: .day, value: -pagesBack * scale.columns, to: today) ?? today
            return (0..<scale.columns).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: last),
                      let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                return WorkLogGrid.Column(start: day, end: end)
            }
        case .weeks:
            let thisWeek = Calendar.metrics.startOfWeek(for: today)
            let last = calendar.date(byAdding: .weekOfYear, value: -pagesBack * scale.columns, to: thisWeek) ?? thisWeek
            return (0..<scale.columns).reversed().compactMap { offset in
                guard let week = calendar.date(byAdding: .weekOfYear, value: -offset, to: last),
                      let end = calendar.date(byAdding: .day, value: 7, to: week) else { return nil }
                return WorkLogGrid.Column(start: week, end: end)
            }
        }
    }

    private var canGoBack: Bool {
        guard let first = columns.first?.start,
              let limit = Calendar.current.date(byAdding: .day, value: -Self.maxDaysBack, to: .now) else { return false }
        return first > limit
    }

    static func rangeLabel(_ columns: [WorkLogGrid.Column]) -> String {
        guard let first = columns.first, let last = columns.last,
              let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: last.end) else { return "" }
        let sameMonth = Calendar.current.isDate(first.start, equalTo: lastDay, toGranularity: .month)
        let start = sameMonth ? first.start.formatted(.dateTime.day()) : first.start.formatted(.dateTime.day().month(.abbreviated))
        return "\(start) - \(lastDay.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// Members in view (team and exclusions applied), by name.
    private var people: [Person] {
        (workload?.people.map(\.person) ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func header(_ columns: [WorkLogGrid.Column]) -> some View {
        HStack(spacing: 0) {
            Spacer()
                .frame(width: Self.nameWidth)
            ForEach(columns) { column in
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    switch scale {
                    case .days:
                        Text(column.start.formatted(.dateTime.day()))
                            .font(.title3.weight(.medium).monospacedDigit())
                        Text(column.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    case .weeks:
                        Text(column.start.formatted(.dateTime.day()))
                            .font(.title3.weight(.medium).monospacedDigit())
                        Text(column.start.formatted(.dateTime.month(.abbreviated)).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .help(scale == .weeks ? "Week of \(column.start.formatted(date: .abbreviated, time: .omitted))" : column.start.formatted(date: .complete, time: .omitted))
            }
        }
        .padding(.vertical, 10)
    }

    private func rowView(_ row: WorkLogGrid.Row, columns: [WorkLogGrid.Column], working: WorkingCalendar) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Avatar(url: row.person.avatarUrl, size: 22)
                Text(row.person.displayName).lineLimit(1)
            }
            .padding(.leading, 16)
            .frame(width: Self.nameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .personDatesMenu(row.person, org: org)
            let dates = peopleDates.dates(for: row.person.login, in: org)
            ForEach(columns) { column in
                WorkLogCell(
                    dots: row.cells[column.start] ?? [],
                    isDayOff: scale == .days && !working.isWorkingDay(column.start),
                    mark: dates.mark(from: column.start, to: column.end, isDay: scale == .days, working: working)
                ) { event in
                    open(event.pullRequest)
                }
                .overlay(alignment: .leading) { Divider() }
            }
        }
        .frame(height: Self.rowHeight)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(WorkLogEvent.Kind.allCases, id: \.self) { kind in
                HStack(spacing: 6) {
                    Circle().fill(ChartPalette.slot(kind.slot)).frame(width: 9, height: 9)
                    Text(kind.rawValue)
                }
            }
            Text("Commit dots grow with lines changed. Hover a dot for detail, click to open its PR in a new window.")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// In a window of its own; clicking again brings that window forward.
    private func open(_ pr: WorkLogPullRequest) {
        openWindow(value: PullRequestReference(org: org, pullRequest: pr))
    }
}

// MARK: - Grid

/// Events bucketed by person and day, each day's dots packed into a cluster.
struct WorkLogGrid {
    struct Column: Identifiable {
        let start: Date
        let end: Date

        var id: Date { start }
    }

    struct Row {
        let person: Person
        /// Packed dots per column, keyed by the column's start.
        let cells: [Date: [PackedDot]]
    }

    let rows: [Row]

    init(history: WorkLogHistory, columns: [Column], scale: WorkLogScale, people: [Person], config: OrgConfig, hidden: Set<String>) {
        let first = columns.first?.start ?? .distantPast
        let end = columns.last?.end ?? .distantFuture
        func bucket(_ date: Date) -> Date {
            scale == .days ? Calendar.current.startOfDay(for: date) : Calendar.metrics.startOfWeek(for: date)
        }

        let events = history.pullRequests(config: config, hidden: hidden)
            .flatMap(\.events)
            .filter { $0.at >= first && $0.at < end }
        var byPersonDay: [String: [Date: [WorkLogEvent]]] = [:]
        for event in events {
            byPersonDay[event.login, default: [:]][bucket(event.at), default: []].append(event)
        }
        rows = people.map { person in
            Row(person: person, cells: (byPersonDay[person.login] ?? [:]).mapValues(DotPacker.pack))
        }
    }
}

extension WorkLogHistory {
    /// PRs left after hiding and the org's repo exclusions.
    func pullRequests(config: OrgConfig, hidden: Set<String>) -> [WorkLogPullRequest] {
        pullRequests.values.filter { !hidden.contains($0.id) && !config.excludedRepos.contains($0.repo) }
    }
}

struct PackedDot: Identifiable {
    let event: WorkLogEvent
    /// Offset from the cluster's centre, in unscaled points.
    let offset: CGPoint
    let radius: Double

    var id: String { event.id }
}

/// Packs dots around a centre, biggest first, along a golden-angle spiral:
/// each dot takes the first spot that doesn't overlap one already placed.
/// Placed dots are bucketed on a grid so each check only looks nearby.
enum DotPacker {
    private static let gap = 1.5
    /// Bigger than any dot's diameter plus the gap, so neighbours are at most
    /// one bucket away.
    private static let bucketSize = 20.0

    static func pack(_ events: [WorkLogEvent]) -> [PackedDot] {
        let sorted = events.sorted { $0.radius > $1.radius }
        var placed: [PackedDot] = []
        var buckets: [Int: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int { x &* 73_856_093 ^ y &* 19_349_663 }
        func cell(_ value: Double) -> Int { Int((value / bucketSize).rounded(.down)) }

        var searchFrom = 0
        for event in sorted {
            let radius = event.radius
            var index = max(0, searchFrom - 40)
            while true {
                let point = spiral(index)
                let cx = cell(point.x), cy = cell(point.y)
                var fits = true
                search: for dx in -1...1 {
                    for dy in -1...1 {
                        for other in buckets[key(cx + dx, cy + dy)] ?? [] {
                            let dot = placed[other]
                            if hypot(point.x - dot.offset.x, point.y - dot.offset.y) < radius + dot.radius + gap {
                                fits = false
                                break search
                            }
                        }
                    }
                }
                if fits {
                    buckets[key(cx, cy), default: []].append(placed.count)
                    placed.append(PackedDot(event: event, offset: point, radius: radius))
                    searchFrom = index
                    break
                }
                index += 1
            }
        }
        return placed
    }

    private static func spiral(_ index: Int) -> CGPoint {
        guard index > 0 else { return .zero }
        let angle = Double(index) * 2.399963
        let distance = 1.6 * sqrt(Double(index))
        return CGPoint(x: distance * cos(angle), y: distance * sin(angle))
    }
}

// MARK: - Cell

/// One person's day: the cluster, scaled down to fit when it's busy, with
/// hover detail and click to open.
private struct WorkLogCell: View {
    let dots: [PackedDot]
    let isDayOff: Bool
    let mark: TimelineMark?
    let onOpen: (WorkLogEvent) -> Void

    @State private var hovered: PackedDot?

    var body: some View {
        GeometryReader { geometry in
            let transform = Transform(dots: dots, size: geometry.size)
            ZStack {
                if isDayOff {
                    Rectangle().fill(.quaternary.opacity(0.35))
                }
                if let mark {
                    TimelineMarkView(mark: mark)
                }
                Canvas { context, _ in
                    for dot in dots {
                        let center = transform.point(dot.offset)
                        let radius = dot.radius * transform.scale
                        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                        let color = ChartPalette.slot(dot.event.kind.slot)
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(hovered == nil || hovered?.id == dot.id ? 1 : 0.45)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = transform.dot(at: location, in: dots)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { location in
                    if let dot = transform.dot(at: location, in: dots) { onOpen(dot.event) }
                }
                if let hovered {
                    Text(hovered.event.summary)
                        .font(.caption)
                        .lineLimit(2)
                        .padding(6)
                        .frame(width: 220, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 3)
                        // Inside the row (the next row would cover it), on the
                        // side of the cell away from the dot.
                        .position(
                            x: geometry.size.width / 2,
                            y: transform.point(hovered.offset).y > geometry.size.height / 2 ? 22 : geometry.size.height - 22
                        )
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
            }
        }
        .zIndex(hovered == nil ? 0 : 1)
    }

    /// Centres the cluster and shrinks it to fit the cell.
    private struct Transform {
        let center: CGPoint
        let scale: Double

        init(dots: [PackedDot], size: CGSize) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            let extent = dots.map { hypot($0.offset.x, $0.offset.y) + $0.radius }.max() ?? 1
            let room = max(min(size.width, size.height) / 2 - 6, 1)
            scale = min(1, room / extent)
        }

        func point(_ offset: CGPoint) -> CGPoint {
            CGPoint(x: center.x + offset.x * scale, y: center.y + offset.y * scale)
        }

        func dot(at location: CGPoint, in dots: [PackedDot]) -> PackedDot? {
            dots.first { dot in
                let center = point(dot.offset)
                return hypot(location.x - center.x, location.y - center.y) <= max(dot.radius * scale, 4)
            }
        }
    }
}
