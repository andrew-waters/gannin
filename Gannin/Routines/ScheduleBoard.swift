import SwiftUI

/// Where the org's agent work falls over the coming days, as the scheduling
/// board draws it: a lane for each run a queue window lets go at once, and
/// one for pinned issues. Queued issues are laid into the windows' open
/// hours in queue order, each taking its window's whole time limit, so a
/// time is the latest it should start by rather than a promise.
struct ScheduleProjection {
    struct Lane: Hashable, Identifiable {
        /// The queue window's ID; nil for pinned issues.
        let window: UUID?
        /// Which of the window's runs at once, from 0.
        let index: Int
        var id: String { "\(window?.uuidString ?? "pinned")-\(index)" }
    }

    struct Bar: Identifiable {
        enum Kind: Equatable {
            /// A run going now.
            case running
            /// Queued, at its place in the org's queue from 1.
            case queued(Int)
            case pinned
        }

        let issue: IssueReference
        let lane: Lane
        let interval: DateInterval
        let kind: Kind
        /// A pinned issue's routine, or the routine a running bar runs for.
        var routine: UUID?
        var id: String { "\(issue.id)-\(lane.id)" }
    }

    var lanes: [Lane] = []
    var bars: [Bar] = []
    /// Queued issues no window reaches within the range, in queue order.
    var later: [QueuedIssue] = []
    /// Each window's open hours within the range.
    var openHours: [UUID: [DateInterval]] = [:]

    static let pinnedLane = Lane(window: nil, index: 0)

    /// `windows` and `pins` are the org's enabled queue windows and pinned
    /// issues, `active` the runs going. While paused, nothing queued starts.
    static func make(windows: [Routine], pins: [Routine], queue: [QueuedIssue], active: [RoutineRun], routines: [Routine],
                     paused: Bool, range: DateInterval, calendar: Calendar = .current,
                     isWorkingDay: RoutineSchedule.WorkingDays = RoutineSchedule.everyWeekday) -> ScheduleProjection {
        var projection = ScheduleProjection()
        var free: [Lane: Date] = [:]
        for window in windows {
            projection.openHours[window.id] = window.schedule.openIntervals(in: range, calendar: calendar, isWorkingDay: isWorkingDay)
            for index in 0..<max(1, window.concurrency) {
                let lane = Lane(window: window.id, index: index)
                projection.lanes.append(lane)
                free[lane] = range.start
            }
        }
        projection.lanes.append(pinnedLane)

        // Runs going hold their lane until their limit, at the latest.
        for run in active {
            guard let issue = run.issue else { continue }
            let routine = routines.first { $0.id == run.routine }
            let start = run.startedAt ?? range.start
            let limit = TimeInterval((routine?.maxMinutes ?? Routine.defaultMaxMinutes) * 60)
            let end = max(start.addingTimeInterval(limit), range.start.addingTimeInterval(5 * 60))
            let lane: Lane
            if let window = routine, window.kind == .issueQueue,
               let open = projection.lanes.filter({ $0.window == window.id }).min(by: { (free[$0] ?? range.start) < (free[$1] ?? range.start) }) {
                lane = open
                free[lane] = max(free[lane] ?? range.start, end)
            } else {
                lane = pinnedLane
            }
            projection.bars.append(Bar(issue: issue, lane: lane, interval: DateInterval(start: start, end: end), kind: .running, routine: run.routine))
        }

        for pin in pins {
            guard let issue = pin.issue, case .once(let at) = pin.schedule, at >= range.start else { continue }
            let end = at.addingTimeInterval(TimeInterval(pin.maxMinutes * 60))
            projection.bars.append(Bar(issue: issue, lane: pinnedLane, interval: DateInterval(start: at, end: end), kind: .pinned, routine: pin.id))
        }

        // Each queued issue goes to whichever window's lane can start it
        // soonest, in queue order, as the scheduler drains them.
        for (position, item) in queue.enumerated() {
            var best: (lane: Lane, start: Date, minutes: Int)?
            if !paused {
                for window in windows {
                    let hours = projection.openHours[window.id] ?? []
                    for lane in projection.lanes where lane.window == window.id {
                        let after = free[lane] ?? range.start
                        guard let open = hours.first(where: { $0.end > after }) else { continue }
                        let start = max(open.start, after)
                        if best.map({ start < $0.start }) ?? true { best = (lane, start, window.maxMinutes) }
                    }
                }
            }
            guard let best else {
                projection.later.append(item)
                continue
            }
            let end = best.start.addingTimeInterval(TimeInterval(best.minutes * 60))
            free[best.lane] = end
            projection.bars.append(Bar(issue: item.issue, lane: best.lane, interval: DateInterval(start: best.start, end: end), kind: .queued(position + 1)))
        }
        return projection
    }
}

/// The scheduling board: the project's unscheduled open issues beside the
/// coming week of the org's queue windows and pinned issues, laid out as
/// `ScheduleProjection` works them out. Dragging an issue onto a window's
/// lane queues it at that point, onto Pinned pins it at that time, and back
/// to the list takes it off. `window` limits it to one window's lanes, on
/// that window's page.
struct ScheduleBoard: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(IssueStore.self) private var issues
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    @Environment(\.navigate) private var navigate
    let org: String
    var window: UUID?
    @State private var search = ""
    @State private var editing: EditedRoutine?
    @AppStorage("scheduleBoardHourWidth") private var hourWidth = 24.0

    static let days = 7
    private let laneHeight: CGFloat = 40
    private let headerHeight: CGFloat = 36
    private let labelWidth: CGFloat = 150

    var body: some View {
        // From the start of this hour, so the first column is whole.
        let start = Calendar.current.dateInterval(of: .hour, for: .now)?.start ?? .now
        let range = DateInterval(start: start, duration: TimeInterval(Self.days * 24 * 3600))
        let projection = projection(range)
        HStack(spacing: 0) {
            unscheduled(projection)
                .frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                timeline(projection, range: range)
                footer(projection)
            }
        }
        .sheet(item: $editing) { edited in
            RoutineEditor(routine: edited.routine, isNew: edited.isNew)
        }
    }

    private func projection(_ range: DateInterval) -> ScheduleProjection {
        let mine = routines.routines(for: org)
        return ScheduleProjection.make(
            windows: mine.filter { $0.kind == .issueQueue && $0.isEnabled },
            pins: mine.filter { $0.kind == .pinned && $0.isEnabled },
            queue: routines.queue(for: org),
            active: routines.activeRuns.filter { $0.issue?.org == org },
            routines: mine, paused: routines.isPaused, range: range,
            isWorkingDay: RoutineScheduleContext.workingDays(org: org, configs: configs, holidays: holidays)
        )
    }

    /// The lanes shown: every one, or the window's alone on its page.
    private func lanes(_ projection: ScheduleProjection) -> [ScheduleProjection.Lane] {
        projection.lanes.filter { window == nil || $0.window == window }
    }

    // MARK: Unscheduled

    /// The project's open issues not queued, pinned or being worked on by a
    /// scheduled run, newest first, searched by title, number or repo.
    private func unscheduledIssues(_ projection: ScheduleProjection) -> [IssueRecord] {
        guard let history = issues.history(for: org) else { return [] }
        let excluded = configs.config(for: org).repoExclusion
        let scheduled = Set(projection.bars.map(\.issue.id) + projection.later.map(\.issue.id))
        let words = search.lowercased().split(separator: " ").map(String.init)
        return history.issues.values
            .filter { $0.isOpen && !excluded.contains($0.repo) && !scheduled.contains($0.id) }
            .filter { issue in
                let text = "\(issue.title) #\(issue.number) \(issue.repo)".lowercased()
                return words.allSatisfy(text.contains)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func unscheduled(_ projection: ScheduleProjection) -> some View {
        let list = unscheduledIssues(projection)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unscheduled")
                    .font(.headline)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text(issues.history(for: org) == nil ? "Loading issues" : "\(list.count) open issue\(list.count == 1 ? "" : "s"). Drag one onto a lane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            List(list.prefix(300), id: \.id) { issue in
                let reference = IssueReference(org: org, record: issue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .lineLimit(2)
                    Text(reference.reference)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .draggable(issue.id)
                .onTapGesture(count: 2) { navigate?.perform(.issueReference(reference)) }
                .contextMenu {
                    Button("Open") { navigate?.perform(.issueReference(reference)) }
                    Button("Add to Agent Queue") { routines.enqueue(reference) }
                }
            }
            .listStyle(.plain)
        }
        // Dropped back here, it comes off the board.
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { unschedule(id) }
            return !ids.isEmpty
        }
    }

    // MARK: Timeline

    private func timeline(_ projection: ScheduleProjection, range: DateInterval) -> some View {
        let shown = lanes(projection)
        let width = CGFloat(Self.days * 24) * hourWidth
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker("Zoom", selection: $hourWidth) {
                        Text("Week").tag(12.0)
                        Text("Days").tag(24.0)
                        Text("Hours").tag(60.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                .frame(height: headerHeight)
                .padding(.horizontal, 8)
                ForEach(shown) { lane in
                    laneLabel(lane)
                        .frame(height: laneHeight)
                        .padding(.horizontal, 8)
                    Divider()
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header(range)
                        .frame(width: width, height: headerHeight, alignment: .leading)
                    ForEach(shown) { lane in
                        row(lane, projection: projection, range: range)
                            .frame(width: width, height: laneHeight, alignment: .leading)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func laneLabel(_ lane: ScheduleProjection.Lane) -> some View {
        if let id = lane.window, let routine = routines.routine(id) {
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.name)
                    .lineLimit(1)
                Text(routine.concurrency > 1 ? "Run \(lane.index + 1) of \(routine.concurrency)" : routine.schedule.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("\(routine.name): \(routine.schedule.summary), \(routine.maxMinutes) minutes a run at most")
        } else {
            Label("Pinned", systemImage: "pin")
                .help("Issues pinned to a time. Drop one here to pin it there.")
        }
    }

    private func x(_ date: Date, in range: DateInterval) -> CGFloat {
        CGFloat(date.timeIntervalSince(range.start) / 3600) * hourWidth
    }

    private func date(atX x: CGFloat, in range: DateInterval) -> Date {
        range.start.addingTimeInterval(TimeInterval(x / hourWidth) * 3600)
    }

    /// Day names, and hour ticks as far as the zoom leaves room for.
    private func header(_ range: DateInterval) -> some View {
        let calendar = Calendar.current
        let step = hourWidth >= 60 ? 1 : hourWidth >= 24 ? 3 : 6
        let hours = Array(stride(from: 0, to: Self.days * 24, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { offset in
                let time = range.start.addingTimeInterval(TimeInterval(offset * 3600))
                let hour = calendar.component(.hour, from: time)
                VStack(alignment: .leading, spacing: 2) {
                    if hour == 0 || offset == 0 {
                        Text(time.formatted(.dateTime.weekday(.abbreviated).day()))
                            .font(.caption.bold())
                    } else {
                        Text(" ").font(.caption.bold())
                    }
                    Text(String(format: "%02d", hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 3)
                .frame(width: CGFloat(step) * hourWidth, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(hour == 0 ? Color.secondary.opacity(0.5) : Color.separatorLine).frame(width: 1)
                }
                .offset(x: CGFloat(offset) * hourWidth)
            }
        }
    }

    private func row(_ lane: ScheduleProjection.Lane, projection: ScheduleProjection, range: DateInterval) -> some View {
        ZStack(alignment: .topLeading) {
            // Open hours, where a queued issue can start.
            if let id = lane.window {
                ForEach(Array((projection.openHours[id] ?? []).enumerated()), id: \.offset) { _, open in
                    Rectangle()
                        .fill(ChartPalette.good.opacity(0.08))
                        .frame(width: max(1, x(open.end, in: range) - x(open.start, in: range)), height: laneHeight)
                        .offset(x: x(open.start, in: range))
                }
            }
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 1.5, height: laneHeight)
                .offset(x: x(.now, in: range))
            ForEach(projection.bars.filter { $0.lane == lane }) { bar in
                barView(bar)
                    .frame(width: max(18, x(bar.interval.end, in: range) - x(max(bar.interval.start, range.start), in: range) - 2), height: laneHeight - 8)
                    .offset(x: x(max(bar.interval.start, range.start), in: range) + 1, y: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, location in
            let time = date(atX: location.x, in: range)
            for id in ids { drop(id, on: lane, at: time, projection: projection) }
            return !ids.isEmpty
        }
    }

    private func barView(_ bar: ScheduleProjection.Bar) -> some View {
        let color: Color = switch bar.kind {
        case .running: ChartPalette.good
        case .queued: .teal
        case .pinned: .indigo
        }
        let time = bar.interval.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let help: String = switch bar.kind {
        case .running: "\(bar.issue.reference) \(bar.issue.title)\nRunning since \(time)"
        case .queued(let position): "\(bar.issue.reference) \(bar.issue.title)\nNumber \(position) in the queue; starts by \(time), if each run before it takes its whole limit"
        case .pinned: "\(bar.issue.reference) \(bar.issue.title)\nPinned to \(time)"
        }
        return HStack(spacing: 4) {
            if case .queued(let position) = bar.kind {
                Text("\(position)").font(.caption2.bold().monospacedDigit())
            } else {
                Image(systemName: bar.kind == .running ? "play.fill" : "pin.fill").font(.caption2)
            }
            Text("\(bar.issue.reference) \(bar.issue.title)")
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.7)))
        .help(help)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { navigate?.perform(.issueReference(bar.issue)) }
        .modifier(DraggableUnlessRunning(id: bar.issue.id, running: bar.kind == .running))
        .contextMenu {
            Button("Open Issue") { navigate?.perform(.issueReference(bar.issue)) }
            switch bar.kind {
            case .running:
                EmptyView()
            case .queued:
                Button("Move to Top") { routines.move(bar.issue.id, toFront: true) }
                Button("Move to Bottom") { routines.move(bar.issue.id, toFront: false) }
                Divider()
                Button("Remove from Queue") { routines.dequeue(bar.issue.id) }
            case .pinned:
                if let id = bar.routine, let pin = routines.routine(id) {
                    Button("Change Pin…") { editing = EditedRoutine(routine: pin, isNew: false) }
                    Divider()
                    Button("Unpin") { routines.remove(id) }
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ projection: ScheduleProjection) -> some View {
        let shown = lanes(projection)
        VStack(alignment: .leading, spacing: 4) {
            if !projection.later.isEmpty {
                Text("After this week: " + projection.later.map(\.issue.reference).joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            if routines.isPaused {
                Text("Routines are paused, so nothing queued starts.")
                    .foregroundStyle(.orange)
            } else if shown.allSatisfy({ $0.window == nil }) {
                Text("No queue window is on, so queued issues won't start by themselves. Add one under Routines.")
                    .foregroundStyle(.secondary)
            }
            Text("Times assume each run takes its window's whole limit, so they're the latest each should start. An issue with a session already carries on in it.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dropping

    /// The issue an ID dragged from the list or a bar names.
    private func reference(_ id: String) -> IssueReference? {
        if let record = issues.history(for: org)?.issues[id] { return IssueReference(org: org, record: record) }
        if let queued = routines.queue.first(where: { $0.issue.id == id }) { return queued.issue }
        return routines.routines.first { $0.issue?.id == id }?.issue
    }

    private func drop(_ id: String, on lane: ScheduleProjection.Lane, at time: Date, projection: ScheduleProjection) {
        guard let reference = reference(id) else { return }
        let pin = routines.pin(for: id)
        if lane.window != nil {
            // Without itself, so moving one later doesn't count its own place.
            let position = projection.bars.filter { bar in
                if case .queued = bar.kind { bar.issue.id != id && bar.interval.start < time } else { false }
            }.count
            routines.insert(reference, at: position)
            if let pin { routines.remove(pin.id) }
        } else {
            // Pinned on the quarter hour, never in the past.
            let quarter = TimeInterval(15 * 60)
            let at = max(Date(timeIntervalSinceReferenceDate: (time.timeIntervalSinceReferenceDate / quarter).rounded() * quarter),
                         Date.now.addingTimeInterval(60))
            if let pin {
                routines.update(pin.id) { $0.schedule = .once(at) }
            } else {
                let repo = configs.config(for: org).harness(covering: WorkOnThisLauncher.repos(reference, issues: issues))?.repo
                    ?? configs.config(for: org).allHarnesses.first?.repo ?? ""
                routines.save(Routine.new(org: org, harnessRepo: repo, kind: .pinned, schedule: .once(at), issue: reference))
            }
            routines.dequeue(id)
        }
    }

    private func unschedule(_ id: String) {
        routines.dequeue(id)
        if let pin = routines.pin(for: id) { routines.remove(pin.id) }
    }
}

/// A bar can be dragged unless its run is going.
private struct DraggableUnlessRunning: ViewModifier {
    let id: String
    let running: Bool

    func body(content: Content) -> some View {
        if running { content } else { content.draggable(id) }
    }
}
