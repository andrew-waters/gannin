import SwiftUI

/// The schedule as the editor's pickers hold it, turned into a
/// `RoutineSchedule` and back.
struct ScheduleDraft: Equatable {
    enum Form: String, CaseIterable, Identifiable {
        case every, daily, workingDays, weekly, cron
        var id: Self { self }

        var label: String {
            switch self {
            case .every: "Every"
            case .daily: "Daily"
            case .workingDays: "Working days"
            case .weekly: "Weekly"
            case .cron: "Cron expression"
            }
        }
    }

    enum Unit: String, CaseIterable, Identifiable {
        case minutes, hours
        var id: Self { self }
    }

    var form: Form = .workingDays
    var interval = 1
    var unit: Unit = .hours
    var time = TimeOfDay(hour: 9)
    var weekday = 2
    var cron = "0 9 * * 1-5"
    var anchor = Calendar.current.startOfDay(for: .now)
    /// A queue window's.
    var window = RoutineWindow(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 8), days: nil)
    /// A pin's.
    var once = Date.now.addingTimeInterval(3600)

    init(_ schedule: RoutineSchedule) {
        switch schedule {
        case .every(let minutes, let anchor):
            form = .every
            self.anchor = anchor
            if minutes % 60 == 0 {
                interval = minutes / 60
                unit = .hours
            } else {
                interval = minutes
                unit = .minutes
            }
        case .daily(let time):
            form = .daily
            self.time = time
        case .workingDays(let time):
            form = .workingDays
            self.time = time
        case .weekly(let weekday, let time):
            form = .weekly
            self.weekday = weekday
            self.time = time
        case .cron(let text):
            form = .cron
            cron = text
        case .once(let date):
            once = date
        case .window(let window):
            self.window = window
        }
    }

    func schedule(for kind: RoutineKind) -> RoutineSchedule {
        switch kind {
        case .issueQueue: return .window(window)
        case .pinned: return .once(once)
        case .report, .code:
            switch form {
            case .every: return .every(minutes: max(1, interval) * (unit == .hours ? 60 : 1), anchor: anchor)
            case .daily: return .daily(time)
            case .workingDays: return .workingDays(time)
            case .weekly: return .weekly(weekday: weekday, time)
            case .cron: return .cron(cron)
            }
        }
    }
}

extension TimeOfDay {
    /// As a date today, for a time picker.
    var date: Date { on(.now, calendar: .current) ?? .now }

    init(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}

/// A routine's settings: what it runs, where, when (with the next five
/// times, or why the schedule can't be used), how far it may go and its
/// limits. New ones start on Local only (R10).
struct RoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RoutineStore.self) private var routines
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    let original: Routine
    let isNew: Bool
    @State private var routine: Routine
    @State private var schedule: ScheduleDraft
    @State private var repoText: String

    init(routine: Routine, isNew: Bool) {
        original = routine
        self.isNew = isNew
        _routine = State(initialValue: routine)
        _schedule = State(initialValue: ScheduleDraft(routine.schedule))
        _repoText = State(initialValue: routine.repos.joined(separator: ", "))
    }

    var body: some View {
        let built = schedule.schedule(for: routine.kind)
        VStack(spacing: 0) {
            Form {
                whatSection
                whenSection(built)
                if routine.kind.touchesCode { limitSection }
                limitsSection
                if let warning = autoModeWarning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let why = cantSave(built) {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save(built) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cantSave(built) != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 720)
    }

    // MARK: Sections

    @ViewBuilder
    private var whatSection: some View {
        Section {
            TextField("Name", text: $routine.name)
            if isNew, routine.kind != .pinned {
                Picker("Kind", selection: $routine.kind) {
                    ForEach([RoutineKind.report, .code, .issueQueue]) { kind in
                        Label(kind.label, systemImage: kind.systemImage).tag(kind)
                    }
                }
            }
            let harnesses = configs.config(for: routine.org).allHarnesses
            // Issue runs go to the project covering the issue's repos.
            if routine.kind == .report || routine.kind == .code {
                Picker("Project", selection: $routine.harnessRepo) {
                    ForEach(harnesses, id: \.repo) { harness in
                        Text(harness.repo).tag(harness.repo)
                    }
                    if !harnesses.contains(where: { $0.repo == routine.harnessRepo }) {
                        Text(routine.harnessRepo).tag(routine.harnessRepo)
                    }
                }
            }
            if let issue = routine.issue {
                LabeledContent("Issue", value: "\(issue.reference) \(issue.title)")
            }
            if routine.kind == .code {
                TextField("Repos", text: $repoText, prompt: Text("owner/name, owner/name"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(promptLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $routine.prompt)
                    .font(.body)
                    .frame(minHeight: 90)
            }
            teamPrompts
        } header: {
            Text("What it runs")
        } footer: {
            Text(kindExplanation)
        }
    }

    private var promptLabel: String {
        switch routine.kind {
        case .report: "What to report on, as you'd ask in an Ask"
        case .code: "The task"
        case .issueQueue, .pinned: "A note added to each issue's prompt (optional)"
        }
    }

    private var kindExplanation: String {
        switch routine.kind {
        case .report: "An Ask session on this Mac with no code worktree. What it writes stays with the run, to open or Commit to Harness; nothing is committed by itself."
        case .code: "A session with no issue, a new branch each run, worktrees of the repos named, laid out as Work on This lays them out."
        case .issueQueue: "While the window is open, the next issue in the org's agent queue starts as Work on This would, in the project covering its repos, up to the number at once below. Its session record is committed to the harness."
        case .pinned: "The issue starts as Work on This would at the time below. Its session record is committed to the harness."
        }
    }

    @ViewBuilder
    private var teamPrompts: some View {
        let use: PromptUse = routine.kind == .report ? .ask : .work
        let library = sessions.promptLibrary(org: routine.org, setup: HarnessConfig(repo: routine.harnessRepo))
        let offered = library.offered(for: use)
        if !offered.isEmpty {
            DisclosureGroup("The team's prompts (\(routine.teamPrompts.isEmpty ? "the defaults" : "\(routine.teamPrompts.count) picked"))") {
                ForEach(offered) { prompt in
                    Toggle(prompt.title, isOn: Binding(
                        get: { routine.teamPrompts.contains(prompt.path) },
                        set: { on in
                            routine.teamPrompts.removeAll { $0 == prompt.path }
                            if on { routine.teamPrompts.append(prompt.path) }
                        }
                    ))
                    .checkboxToggle()
                }
                Text("With none picked, runs take the team's defaults, as a start with no sheet does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func whenSection(_ built: RoutineSchedule) -> some View {
        Section("When") {
            switch routine.kind {
            case .pinned:
                DatePicker("At", selection: $schedule.once, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
            case .issueQueue:
                DatePicker("Opens", selection: timeBinding(\.window.start), displayedComponents: .hourAndMinute)
                DatePicker("Closes", selection: timeBinding(\.window.end), displayedComponents: .hourAndMinute)
                Picker("On", selection: Binding(get: { schedule.window.days == nil }, set: { working in
                    schedule.window.days = working ? nil : Set(WorkWeek.weekdays.prefix(5))
                })) {
                    Text("Working days").tag(true)
                    Text("Days I pick").tag(false)
                }
                .pickerStyle(.segmented)
                if let days = schedule.window.days {
                    HStack {
                        ForEach(WorkWeek.weekdays, id: \.self) { day in
                            Toggle(WorkWeek.name(day), isOn: Binding(
                                get: { days.contains(day) },
                                set: { on in
                                    var next = days
                                    if on { next.insert(day) } else { next.remove(day) }
                                    schedule.window.days = next
                                }
                            ))
                            .toggleStyle(.button)
                        }
                    }
                }
                Stepper("At once: \(routine.concurrency)", value: $routine.concurrency, in: 1...6)
            case .report, .code:
                Picker("Runs", selection: $schedule.form) {
                    ForEach(ScheduleDraft.Form.allCases) { form in
                        Text(form.label).tag(form)
                    }
                }
                switch schedule.form {
                case .every:
                    HStack {
                        Stepper("\(schedule.interval)", value: $schedule.interval, in: 1...(schedule.unit == .hours ? 168 : 720))
                        Picker("", selection: $schedule.unit) {
                            Text("minutes").tag(ScheduleDraft.Unit.minutes)
                            Text("hours").tag(ScheduleDraft.Unit.hours)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                case .daily, .workingDays:
                    DatePicker("At", selection: timeBinding(\.time), displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("On", selection: $schedule.weekday) {
                        ForEach(WorkWeek.weekdays, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[(day - 1) % 7]).tag(day)
                        }
                    }
                    DatePicker("At", selection: timeBinding(\.time), displayedComponents: .hourAndMinute)
                case .cron:
                    TextField("Expression", text: $schedule.cron, prompt: Text("minute hour day month weekday"))
                        .font(.body.monospaced())
                }
            }
            nextTimes(built)
        }
    }

    /// The next five times (R3), or why the schedule can't be used.
    @ViewBuilder
    private func nextTimes(_ built: RoutineSchedule) -> some View {
        if let problem = built.problem() {
            Label(problem, systemImage: "xmark.octagon")
                .foregroundStyle(ChartPalette.critical)
        } else {
            let days = RoutineScheduleContext.workingDays(org: routine.org, configs: configs, holidays: holidays)
            let times = built.nextTimes(after: .now, count: 5, isWorkingDay: days)
            VStack(alignment: .leading, spacing: 2) {
                Text(built.isWindow ? "Opens next" : "Next runs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(times, id: \.self) { time in
                    Text(time.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()))
                        .font(.callout.monospacedDigit())
                }
                if routine.kind == .code || routine.kind == .report, schedule.form == .workingDays {
                    Text("The org's working days, less its bank holidays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var limitSection: some View {
        Section {
            Picker("Unattended, it may", selection: $routine.limit) {
                ForEach(RoutineLimit.allCases) { limit in
                    Text(limit.label).tag(limit)
                }
            }
            .pickerStyle(.segmented)
            Text(routine.limit.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("How far it goes")
        } footer: {
            Text("Runs work in auto mode. Gannin takes away the commands the limit doesn't allow; it's a guard, not a sandbox.")
        }
    }

    private var limitsSection: some View {
        Section {
            Stepper("Stop after \(routine.maxMinutes) minutes", value: $routine.maxMinutes, in: 5...600, step: 5)
            TextField("Stop after spending", value: $routine.maxCost, format: .currency(code: "USD"))
        } header: {
            Text("Limits")
        } footer: {
            Text("At either, Gannin interrupts Claude, keeps what it's done and marks the run Stopped at limit. Time and cost keep counting while it waits on you.")
        }
    }

    // MARK: Helpers

    private func timeBinding(_ path: WritableKeyPath<ScheduleDraft, TimeOfDay>) -> Binding<Date> {
        Binding(get: { schedule[keyPath: path].date }, set: { schedule[keyPath: path] = TimeOfDay($0) })
    }

    private var repos: [String] {
        repoText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// Where its runs would start, as auto mode is remembered for.
    private var autoModeWarning: String? {
        let box: String
        if routine.kind == .report {
            box = ""
        } else if SandboxCredentials.isEnabled {
            box = "sandbox" + (SessionStore.connectCommand.map { " on \($0)" } ?? "")
        } else {
            box = SessionStore.connectCommand ?? ""
        }
        guard sessions.autoUnavailableBoxes.contains(box) else { return nil }
        let place = box.isEmpty ? "this Mac" : box
        return "Auto mode wasn't available the last time Claude started on \(place), so runs there will fail without doing anything until it is."
    }

    private func cantSave(_ built: RoutineSchedule) -> String? {
        if routine.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if let problem = built.problem() { return problem }
        if routine.kind == .code {
            if repos.isEmpty { return "Name a repo to work in." }
            if let bad = repos.first(where: { $0.split(separator: "/").count != 2 }) { return "\(bad) isn't owner/name." }
            if routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what the task is." }
        }
        if routine.kind == .report, routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what to report on." }
        if routine.maxCost <= 0 { return "Give it a cost limit." }
        return nil
    }

    private func save(_ built: RoutineSchedule) {
        var saved = routine
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.schedule = built
        saved.repos = saved.kind == .code ? repos : []
        // A new schedule counts from now: an edit isn't taken for times missed.
        if saved.schedule != original.schedule, !isNew {
            saved = Routine(
                id: saved.id, name: saved.name, org: saved.org, harnessRepo: saved.harnessRepo, kind: saved.kind, prompt: saved.prompt,
                teamPrompts: saved.teamPrompts, repos: saved.repos, schedule: saved.schedule, limit: saved.limit, maxMinutes: saved.maxMinutes,
                maxCost: saved.maxCost, concurrency: saved.concurrency, issue: saved.issue,
                // Off stays off; a pin moved to a time to come is on again.
                isEnabled: saved.isEnabled || saved.kind == .pinned, createdAt: .now
            )
        }
        routines.save(saved)
        dismiss()
    }
}

/// The org's working days for a schedule shown in a view: its working week
/// less the bank holidays loaded so far, as the scheduler reads them.
enum RoutineScheduleContext {
    static func workingDays(org: String, configs: OrgConfigStore, holidays: BankHolidayStore) -> RoutineSchedule.WorkingDays {
        let week = configs.config(for: org).week
        let year = Calendar.current.component(.year, from: .now)
        let calendar = holidays.calendar(week: week, region: week.holidays, years: year...(year + 1))
        return { calendar.isWorkingDay($0) }
    }
}
