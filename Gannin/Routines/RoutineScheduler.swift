import AppKit
import Foundation
import Observation

/// What starting a scheduled run came to.
enum RoutineStart {
    case started(session: UUID)
    /// `retry` is false when the issue itself is the trouble (it already
    /// has a session), so a queued one isn't put back.
    case failed(String, retry: Bool = true)
}

/// Starts agent sessions by themselves while Gannin runs: each routine's
/// times as they come, and queue windows draining the agent queue. Ticks
/// every 15 seconds, and at once when the Mac wakes. Times older than the
/// grace (Gannin was closed or the Mac asleep) are recorded as missed and
/// not run (R2); while paused, as skipped (R14).
@Observable
final class RoutineScheduler {
    let store: RoutineStore
    /// Starts a run of the routine at its time; for a queue window or a
    /// pinned issue, of the issue given. Set by the app (`SessionStore`).
    @ObservationIgnored var start: (Routine, IssueReference?, UUID) async -> RoutineStart = { _, _, _ in .failed("Gannin isn't ready to start sessions.") }
    /// The org's working days: its working week less its bank holidays.
    @ObservationIgnored var workingDays: (String) -> RoutineSchedule.WorkingDays = { _ in RoutineSchedule.everyWeekday }
    /// Called each tick to watch the runs going (limits, outcomes).
    @ObservationIgnored var watch: () -> Void = {}
    /// The calendar times are worked out in; a test's own.
    @ObservationIgnored var calendar: Calendar = .current

    static let tick: Duration = .seconds(15)
    /// How late a time may be noticed and still run.
    static let grace: TimeInterval = 120
    /// How long a queue window waits after a start fails before trying the
    /// issue (put back at the front) again, doubled for each failure in a row.
    static let holdAfterFailure: TimeInterval = 5 * 60
    /// Failures in a row after which a window stops trying until it next
    /// opens, or Run Now.
    static let maxFailures = 4

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Starts under way, by run: a start can take minutes (a sandbox's
    /// image, the harness commit), so none is awaited by a look.
    @ObservationIgnored private var starting: [UUID: Task<Void, Never>] = [:]
    /// Queue windows held off after a failed start, until when.
    private(set) var heldUntil: [UUID: Date] = [:]
    /// Each queue window's failed starts in a row.
    private(set) var failures: [UUID: Int] = [:]
    /// While a look is under way: the wake's and the loop's never overlap.
    @ObservationIgnored private var checking = false

    init(store: RoutineStore) {
        self.store = store
    }

    func begin() {
        guard loop == nil else { return }
        // Terminals don't outlive Gannin: a run still going from before
        // ended when it quit.
        let quitAt = store.checkedAt ?? .now
        for run in store.activeRuns {
            store.updateRun(run.id) { run in
                run.outcome = .failed
                run.endedAt = run.endedAt ?? quitAt
                run.note = "Gannin quit while it ran. Open its session to resume it."
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                try? await Task.sleep(for: Self.tick)
            }
        }
        // Waking, look straight away: what came due while asleep is missed.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
    }

    /// What the routine's times since the last look come to.
    struct Plan: Equatable {
        /// The time to run now, if one is due.
        var due: Date?
        var missed: [Date] = []
        var skipped: [Date] = []
    }

    /// The routine's times after `since` (or its creation, if later) up to
    /// `now`: the latest within the grace runs, unless paused; older ones
    /// were missed; while paused all are skipped. Queue windows have no
    /// times to run: they drain while open.
    static func plan(_ routine: Routine, since: Date, now: Date, paused: Bool, calendar: Calendar = .current, isWorkingDay: RoutineSchedule.WorkingDays) -> Plan {
        guard routine.isEnabled, !routine.schedule.isWindow else { return Plan() }
        let from = max(since, routine.createdAt)
        guard from < now else { return Plan() }
        let times = routine.schedule.times(after: from, through: now, calendar: calendar, isWorkingDay: isWorkingDay)
        guard !times.isEmpty else { return Plan() }
        if paused { return Plan(skipped: times) }
        var plan = Plan()
        if let last = times.last, now.timeIntervalSince(last) <= grace {
            plan.due = last
            plan.missed = Array(times.dropLast())
        } else {
            plan.missed = times
        }
        return plan
    }

    /// How many more of the window's runs may start now: none while it's
    /// shut, paused or off, else its concurrency less those going.
    static func freeSlots(_ routine: Routine, active: Int, now: Date, paused: Bool, calendar: Calendar = .current, isWorkingDay: RoutineSchedule.WorkingDays) -> Int {
        guard routine.isEnabled, !paused, routine.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: isWorkingDay) else { return 0 }
        return max(0, routine.concurrency - active)
    }

    /// One look: watch what's going, then each routine's times, then the
    /// queue windows.
    func check(now: Date = .now) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        watch()
        let since = store.checkedAt ?? now
        store.checked(at: now)
        for routine in store.routines {
            let days = workingDays(routine.org)
            let plan = Self.plan(routine, since: since, now: now, paused: store.isPaused, calendar: calendar, isWorkingDay: days)
            store.recordGap(plan.missed, routine: routine.id, outcome: .missed, issue: routine.issue)
            store.recordGap(plan.skipped, routine: routine.id, outcome: .skippedPaused, issue: routine.issue)
            // A pin's time has come and gone, run or not.
            if routine.kind == .pinned, plan.due != nil || !plan.missed.isEmpty || !plan.skipped.isEmpty {
                store.update(routine.id) { $0.isEnabled = false }
            }
            if let due = plan.due {
                run(routine, scheduledAt: due, issue: routine.issue)
            }
        }
        for routine in store.routines where routine.kind == .issueQueue {
            drain(routine, now: now)
        }
    }

    /// Starts the next queued issues while the window has room (R7), each
    /// taken off the queue as it starts. Runs being started count, as
    /// they're recorded as going at once.
    private func drain(_ routine: Routine, now: Date) {
        let days = workingDays(routine.org)
        // Shut, it starts afresh when it next opens.
        if !routine.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: days) {
            failures[routine.id] = nil
            heldUntil[routine.id] = nil
        }
        if let held = heldUntil[routine.id], now < held { return }
        while true {
            let active = store.activeRuns.filter { $0.routine == routine.id }.count
            guard Self.freeSlots(routine, active: active, now: now, paused: store.isPaused, calendar: calendar, isWorkingDay: days) > 0,
                  let next = store.queue(for: routine.org).first else { return }
            store.dequeue(next.issue.id)
            run(routine, scheduledAt: now, issue: next.issue, fromQueue: true)
        }
    }

    /// Records the run as going, then starts its session in a task of its
    /// own, so a slow start holds up no look (and no other run's limits).
    /// A queued issue whose start fails goes back to the front, and its
    /// window waits a while before trying again.
    private func run(_ routine: Routine, scheduledAt: Date, issue: IssueReference?, fromQueue: Bool = false) {
        let id = UUID()
        store.record(RoutineRun(id: id, routine: routine.id, scheduledAt: scheduledAt, issue: issue, startedAt: .now, outcome: .running))
        starting[id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.start(routine, issue, id)
            self.starting[id] = nil
            switch result {
            case .started(let session):
                self.store.updateRun(id) { $0.session = session }
                if fromQueue {
                    self.failures[routine.id] = nil
                    self.heldUntil[routine.id] = nil
                }
            case .failed(let why, let retry):
                self.store.updateRun(id) { run in
                    run.outcome = .failed
                    run.endedAt = .now
                    run.note = why
                }
                if fromQueue, retry, let issue {
                    self.store.enqueue(issue, atFront: true)
                    let count = (self.failures[routine.id] ?? 0) + 1
                    self.failures[routine.id] = count
                    // Backs off, then gives up until the window next opens.
                    self.heldUntil[routine.id] = count >= Self.maxFailures
                        ? .distantFuture
                        : max(scheduledAt, .now).addingTimeInterval(Self.holdAfterFailure * pow(2, Double(count - 1)))
                }
            }
        }
    }

    /// Why a queue window isn't starting issues after failed starts, for
    /// its row: waiting to try again, or stopped until it next opens.
    func queueNote(_ routine: UUID, now: Date = .now) -> String? {
        guard let held = heldUntil[routine], held > now, let count = failures[routine] else { return nil }
        if held == .distantFuture {
            return "Stopped after \(count) failed starts in a row, until it next opens or Run Now"
        }
        return "\(count) failed start\(count == 1 ? "" : "s"), trying again \(held.formatted(.relative(presentation: .named)))"
    }

    /// Whether one of the routine's runs is being started.
    func isStarting(_ routine: UUID) -> Bool {
        starting.keys.contains { store.run($0)?.routine == routine }
    }

    /// Waits for every start under way; for tests.
    func startsFinished() async {
        while let task = starting.values.first {
            await task.value
        }
    }

    /// Runs the routine now, outside its schedule (Run Now).
    func runNow(_ routine: Routine) {
        guard !isStarting(routine.id) else { return }
        if routine.kind == .issueQueue {
            guard let next = store.queue(for: routine.org).first else { return }
            store.dequeue(next.issue.id)
            heldUntil[routine.id] = nil
            failures[routine.id] = nil
            run(routine, scheduledAt: .now, issue: next.issue, fromQueue: true)
        } else {
            run(routine, scheduledAt: .now, issue: routine.issue)
        }
    }
}
