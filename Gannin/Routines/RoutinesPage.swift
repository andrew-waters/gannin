import SwiftUI

/// Agents › Routines: the org's routines, queue windows and pinned issues,
/// each with its schedule, next run and last outcome, with Pause All
/// (R14) and New Routine in the toolbar. A routine opens its page.
struct RoutinesPage: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    @Environment(\.navigate) private var navigate
    let org: String
    @State private var editing: EditedRoutine?
    @State private var deleting: Routine?

    var body: some View {
        let all = routines.routines(for: org)
        let recurring = all.filter { $0.kind == .report || $0.kind == .code }
        let windows = all.filter { $0.kind == .issueQueue }
        let pins = all.filter { $0.kind == .pinned }.sorted { (pinTime($0) ?? .distantPast) > (pinTime($1) ?? .distantPast) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if routines.isPaused { pausedBanner }
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No routines yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Routines start Claude Code sessions by themselves while Gannin is running: reports and maintenance on a schedule, and issues from the agent queue in a window. Times missed while Gannin was closed or the Mac was asleep are recorded, not run.")
                    } actions: {
                        newMenu
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
                section("Reports and maintenance", recurring)
                section("Queue windows", windows, footer: windows.isEmpty ? nil : "Each drains the agent queue (Agents › Queue) while it's open.")
                section("Pinned issues", pins)
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    routines.setPaused(!routines.isPaused)
                } label: {
                    Label(routines.isPaused ? "Resume All" : "Pause All", systemImage: routines.isPaused ? "play.fill" : "pause.fill")
                }
                .help(routines.isPaused ? "Let routines start sessions again" : "Start no scheduled run until resumed; times passing are recorded as skipped")
            }
            ToolbarItem { newMenu }
        }
        .sheet(item: $editing) { edited in
            RoutineEditor(routine: edited.routine, isNew: edited.isNew)
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "this routine")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { routine in
            Button("Delete", role: .destructive) { routines.remove(routine.id) }
        } message: { _ in
            Text("Its schedule and run history go. Sessions it started stay until you finish them.")
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Routines are paused")
                    .font(.headline)
                Text("No scheduled run starts until they're resumed. Times that pass meanwhile are recorded as skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume All") { routines.setPaused(false) }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var newMenu: some View {
        Menu {
            ForEach([RoutineKind.report, .code, .issueQueue]) { kind in
                Button {
                    editing = EditedRoutine(routine: Routine.new(org: org, harnessRepo: harnessRepo, kind: kind), isNew: true)
                } label: {
                    Label("New \(kind.label)", systemImage: kind.systemImage)
                }
            }
        } label: {
            Label("New Routine", systemImage: "plus")
        }
        .help("A report, maintenance or a window for the agent queue")
        .disabled(configs.config(for: org).allHarnesses.isEmpty)
    }

    /// The window's project, else the org's first.
    private var harnessRepo: String {
        configs.config(for: org).harnesses.first?.repo ?? configs.config(for: org).allHarnesses.first?.repo ?? ""
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [Routine], footer: String? = nil) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(list) { routine in
                        RoutineRow(routine: routine, isWorkingDay: RoutineScheduleContext.workingDays(org: org, configs: configs, holidays: holidays))
                            .contentShape(Rectangle())
                            .onTapGesture { navigate?.perform(.routine(id: routine.id, name: routine.name)) }
                            .contextMenu { RoutineMenu(routine: routine, editing: $editing, deleting: $deleting) }
                        if routine.id != list.last?.id { Divider() }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.separatorLine) }
                if let footer {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pinTime(_ routine: Routine) -> Date? {
        if case .once(let at) = routine.schedule { at } else { nil }
    }
}

/// A routine being added or edited, for the editor sheet.
struct EditedRoutine: Identifiable {
    var id: UUID { routine.id }
    let routine: Routine
    let isNew: Bool
}

/// One routine in the list: its kind, name, schedule, next run, last
/// outcome and whether it's on.
private struct RoutineRow: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(RoutineScheduler.self) private var scheduler
    let routine: Routine
    let isWorkingDay: RoutineSchedule.WorkingDays

    var body: some View {
        let last = routines.lastRun(of: routine.id)
        let next = routine.isEnabled ? routine.schedule.nextTimes(after: .now, count: 1, isWorkingDay: isWorkingDay).first : nil
        HStack(spacing: 12) {
            Image(systemName: routine.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(routine.schedule.summary)
                    if routine.kind.touchesCode { Text(routine.limit.label) }
                    if routine.kind == .issueQueue { Text("\(routine.concurrency) at once") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if routine.kind == .issueQueue, routine.isEnabled, routine.schedule.isOpen(at: .now, isWorkingDay: isWorkingDay) {
                    Text("Open now")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ChartPalette.good)
                } else if let next {
                    Text("Next \(next.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                } else {
                    Text(routine.isEnabled ? "No more runs" : "Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let last {
                    RunOutcomeLabel(run: last)
                        .font(.caption)
                }
                if let note = scheduler.queueNote(routine.id) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Toggle("On", isOn: Binding(get: { routine.isEnabled }, set: { on in routines.update(routine.id) { $0.isEnabled = on } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(routine.isEnabled ? "Turn it off: no runs, and nothing recorded as missed" : "Turn it on")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A run's outcome in its colour.
struct RunOutcomeLabel: View {
    let run: RoutineRun

    var body: some View {
        Text(run.summary)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch run.outcome {
        case .running: .accentColor
        case .needsYou, .stoppedAtLimit: .orange
        case .failed: ChartPalette.critical
        case .finished: ChartPalette.good
        case .missed, .skippedPaused: .secondary
        }
    }
}

/// Run Now, Edit, turning it on or off, and Delete.
struct RoutineMenu: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(RoutineScheduler.self) private var scheduler
    let routine: Routine
    @Binding var editing: EditedRoutine?
    @Binding var deleting: Routine?

    var body: some View {
        Button("Run Now") { scheduler.runNow(routine) }
            .disabled(routine.kind == .issueQueue && routines.queue(for: routine.org).isEmpty)
        Button("Edit…") { editing = EditedRoutine(routine: routine, isNew: false) }
        Button(routine.isEnabled ? "Turn Off" : "Turn On") { routines.update(routine.id) { $0.isEnabled.toggle() } }
        Divider()
        Button("Delete…", role: .destructive) { deleting = routine }
    }
}

/// A routine's page: its settings, the next five times and every run
/// (R13), each opening its session.
struct RoutinePage: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(RoutineScheduler.self) private var scheduler
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    @Environment(\.openWindow) private var openWindow
    let org: String
    let id: UUID
    @State private var editing: EditedRoutine?
    @State private var deleting = false

    var body: some View {
        if let routine = routines.routine(id) {
            let runs = routines.runs(for: id)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(routine)
                    upcoming(routine)
                    if routine.kind == .issueQueue {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Schedule")
                                .font(.headline)
                            ScheduleBoard(org: routine.org, window: routine.id)
                                .frame(height: 420)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separatorLine))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runs")
                            .font(.headline)
                        if runs.isEmpty {
                            Text("None yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            runTable(runs)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem {
                    Button { scheduler.runNow(routine) } label: { Label("Run Now", systemImage: "play") }
                        .help("Start a run now, outside its schedule")
                        .disabled(routine.kind == .issueQueue && routines.queue(for: routine.org).isEmpty)
                }
                ToolbarItem {
                    Button { editing = EditedRoutine(routine: routine, isNew: false) } label: { Label("Edit", systemImage: "pencil") }
                }
                ToolbarItem {
                    Button(role: .destructive) { deleting = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .sheet(item: $editing) { edited in
                RoutineEditor(routine: edited.routine, isNew: edited.isNew)
            }
            .confirmationDialog("Delete \(routine.name)?", isPresented: $deleting) {
                Button("Delete", role: .destructive) { routines.remove(id) }
            } message: {
                Text("Its schedule and run history go. Sessions it started stay until you finish them.")
            }
        } else {
            ContentUnavailableView("No such routine", systemImage: "clock.arrow.circlepath", description: Text("It was deleted."))
        }
    }

    private func header(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: routine.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(routine.name)
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("On", isOn: Binding(get: { routine.isEnabled }, set: { on in routines.update(id) { $0.isEnabled = on } }))
                    .toggleStyle(.switch)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                fact("Kind", routine.kind.label)
                fact("Project", routine.kind.touchesCode && routine.kind != .code ? "The one covering each issue's repos" : routine.harnessRepo)
                fact("When", routine.schedule.summary)
                if let issue = routine.issue { fact("Issue", "\(issue.reference) \(issue.title)") }
                if !routine.repos.isEmpty { fact("Repos", routine.repos.joined(separator: ", ")) }
                if routine.kind.touchesCode { fact("May", "\(routine.limit.label): \(routine.limit.explanation)") }
                if routine.kind == .issueQueue { fact("At once", "\(routine.concurrency)") }
                fact("Limits", "\(routine.maxMinutes) minutes or \(routine.maxCost.formatted(.currency(code: "USD")))")
            }
            .font(.callout)
            if !routine.prompt.isEmpty {
                Text(routine.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if routines.isPaused {
                Label("Routines are paused: no run starts until they're resumed.", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func upcoming(_ routine: Routine) -> some View {
        let days = RoutineScheduleContext.workingDays(org: org, configs: configs, holidays: holidays)
        let times = routine.isEnabled ? routine.schedule.nextTimes(after: .now, count: 5, isWorkingDay: days) : []
        if !times.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.schedule.isWindow ? "Opens next" : "Next runs")
                    .font(.headline)
                ForEach(times, id: \.self) { time in
                    Text(time.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()))
                        .font(.callout.monospacedDigit())
                }
            }
        }
    }

    /// Scheduled, started, outcome, duration, cost and PRs (R13).
    private func runTable(_ runs: [RoutineRun]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Scheduled")
                Text("Started")
                Text("Outcome")
                Text("Took")
                Text("Cost")
                Text("Pull requests")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(runs) { run in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.scheduledAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        if let issue = run.issue, routines.routine(run.routine)?.kind == .issueQueue {
                            Text("\(issue.reference) \(issue.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(run.startedAt?.formatted(.dateTime.hour().minute()) ?? "–")
                    VStack(alignment: .leading, spacing: 1) {
                        RunOutcomeLabel(run: run)
                        if let note = run.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Text(run.duration.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) } ?? "–")
                    Text(run.cost.map { $0.formatted(.currency(code: "USD")) } ?? "–")
                    HStack(spacing: 6) {
                        ForEach(run.pullRequests, id: \.self) { url in
                            Link("#\(url.lastPathComponent)", destination: url)
                        }
                        if let session = run.session, sessions.sessions[session] != nil {
                            Button("Open Session") { sessions.show(session, with: openWindow) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}
