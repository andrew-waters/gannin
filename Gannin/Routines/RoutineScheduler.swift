import AppKit
import Foundation
import Observation

/// What starting a scheduled run came to.
enum RoutineStart: Equatable {
    case started(session: UUID)
    /// `retry` is false when the issue itself is the trouble (it already
    /// has a session), so a queued one isn't put back.
    case failed(String, retry: Bool = true)
    /// A queued review no longer wanted, and why (R7).
    case skipped(String)
    /// A queued review that can't start yet through no fault of the window
    /// (its review is busy): it goes back where it was, with no hold and no
    /// run recorded. `reviewReady` passes over these, so it's only a race.
    case notYet(String)
}

/// Starts agent sessions by themselves while Gannin runs: each routine's
/// times as they come, queue windows draining the agent queue, and review
/// windows draining the review queue. Ticks
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
    /// The org's review windows, this Mac's or the person's synced ones
    /// (`ReviewWindowBook`).
    /// Nil while they aren't known yet, which holds the queue.
    @ObservationIgnored var reviewWindows: (String) -> [Routine]? = { _ in [] }
    /// Automatic reviews running on this Mac, every org's.
    @ObservationIgnored var runningReviews: () -> Int = { 0 }
    /// Starts a queued review whose turn has come, after checking it's still
    /// wanted (`SessionStore.startQueuedReview`).
    @ObservationIgnored var startReview: (QueuedReview, UUID) async -> RoutineStart = { _, _ in .failed("Gannin isn't ready to start reviews.") }
    /// Whether a queued review could start now: false for a Look Again
    /// whose review is busy, which waits without holding up the rest.
    @ObservationIgnored var reviewReady: (QueuedReview) -> Bool = { _ in true }
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
    /// What a review run counts against when no review window started it:
    /// Run Now with none open, or a queue left after its windows went.
    static let reviewQueueRuns = UUID(uuidString: "5EC0E5E0-0000-4000-8000-000000000000")!

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Starts under way, by run: a start can take minutes (a sandbox's
    /// image, the harness commit), so none is awaited by a look.
    @ObservationIgnored private var starting: [UUID: Task<Void, Never>] = [:]
    /// Queue and review windows held off after a failed start, until when.
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
        // A look that starts or records anything is saved at once, so a
        // relaunch doesn't plan its times again.
        var acted = false
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
            if plan.due != nil || !plan.missed.isEmpty || !plan.skipped.isEmpty { acted = true }
        }
        for routine in store.routines where routine.kind == .issueQueue {
            if drain(routine, now: now) { acted = true }
        }
        for org in Set(store.reviewQueue.map(\.pullRequest.org)).sorted() {
            if drainReviews(org: org, now: now) { acted = true }
        }
        if acted { store.saveState() }
    }

    /// Reviews being started, which count as running until their session is.
    var reviewsStarting: Int { starting.keys.filter { store.run($0)?.pullRequest != nil }.count }

    /// Starts the org's queued reviews in order while a review window is open
    /// and every automatic review on this Mac, whatever its org, is under its
    /// reviews at once (R5), as `ReviewGate` decides; with no windows, as
    /// Auto review would (R11). A window closing only stops new starts (R6).
    /// Whether it started any.
    private func drainReviews(org: String, now: Date) -> Bool {
        // Pause All holds the queue, with or without windows.
        guard !store.isPaused else { return false }
        let days = workingDays(org)
        // Not known yet (just launched, not signed in): hold the queue.
        guard let windows = reviewWindows(org)?.filter(\.isEnabled) else { return false }
        for window in windows where !window.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: days) {
            failures[window.id] = nil
            heldUntil[window.id] = nil
        }
        var started = false
        while let next = store.reviewQueue(for: org).first(where: reviewReady) {
            let running = runningReviews() + reviewsStarting
            guard case .start(let limit) = ReviewGate.decide(now: now, windows: windows, running: running, paused: store.isPaused, calendar: calendar, isWorkingDay: days),
                  running < limit else { return started }
            // The roomiest open window with a place takes it.
            let window = windows
                .filter { $0.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: days) && $0.concurrency > running }
                .max { $0.concurrency < $1.concurrency }
            let counted = window?.id ?? Self.reviewQueueRuns
            if let held = heldUntil[counted], now < held { return started }
            store.dequeueReview(next.id)
            runReview(next, counted: counted, scheduledAt: now)
            started = true
        }
        return started
    }

    /// Records the review's run as going and starts it in a task of its own,
    /// as `run` does. One whose start fails goes back to the front and holds
    /// its window off; one no longer wanted is dropped with why (R7).
    private func runReview(_ review: QueuedReview, counted: UUID, scheduledAt: Date) {
        let id = UUID()
        store.record(RoutineRun(id: id, routine: counted, scheduledAt: scheduledAt, pullRequest: review.pullRequest, startedAt: .now, outcome: .running))
        starting[id] = Task { [weak self] in
            guard let self else { return }
            let result = await self.startReview(review, id)
            self.starting[id] = nil
            switch result {
            case .started(let session):
                self.store.updateRun(id) { $0.session = session }
                self.failures[counted] = nil
                self.heldUntil[counted] = nil
            case .skipped(let why):
                self.store.updateRun(id) { run in
                    run.outcome = .skipped
                    run.endedAt = .now
                    run.note = why
                }
            case .notYet:
                self.store.removeRun(id)
                self.store.enqueueReview(review, atFront: true)
            case .failed(let why, let retry):
                self.store.updateRun(id) { run in
                    run.outcome = .failed
                    run.endedAt = .now
                    run.note = why
                }
                if retry {
                    self.store.enqueueReview(review, atFront: true)
                    self.holdAfterFailure(counted, scheduledAt: scheduledAt)
                }
            }
        }
    }

    /// Runs a queued review now, whatever the time (R8), counted against the
    /// org's first review window if it has one.
    func runReviewNow(_ review: QueuedReview) {
        guard store.isReviewQueued(review.id) else { return }
        let counted = reviewWindows(review.pullRequest.org)?.first?.id ?? Self.reviewQueueRuns
        store.dequeueReview(review.id)
        heldUntil[counted] = nil
        failures[counted] = nil
        runReview(review, counted: counted, scheduledAt: .now)
    }

    /// Backs the window off after a failed start, then gives up until it
    /// next opens. Runs with no window (`reviewQueueRuns`) never open or
    /// shut, so they keep backing off, at most as long as the last hold
    /// before giving up, rather than stopping for good.
    private func holdAfterFailure(_ window: UUID, scheduledAt: Date) {
        let count = (failures[window] ?? 0) + 1
        failures[window] = count
        if count >= Self.maxFailures, window != Self.reviewQueueRuns {
            heldUntil[window] = .distantFuture
            return
        }
        let doublings = min(count, Self.maxFailures - 1) - 1
        heldUntil[window] = max(scheduledAt, .now).addingTimeInterval(Self.holdAfterFailure * pow(2, Double(doublings)))
    }

    /// Starts the next queued issues while the window has room (R7), each
    /// taken off the queue as it starts. Runs being started count, as
    /// they're recorded as going at once. Whether it started any.
    private func drain(_ routine: Routine, now: Date) -> Bool {
        let days = workingDays(routine.org)
        // Shut, it starts afresh when it next opens.
        if !routine.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: days) {
            failures[routine.id] = nil
            heldUntil[routine.id] = nil
        }
        if let held = heldUntil[routine.id], now < held { return false }
        var started = false
        while true {
            let active = store.activeRuns.filter { $0.routine == routine.id }.count
            guard Self.freeSlots(routine, active: active, now: now, paused: store.isPaused, calendar: calendar, isWorkingDay: days) > 0,
                  let next = store.queue(for: routine.org).first else { return started }
            store.dequeue(next.issue.id)
            run(routine, scheduledAt: now, issue: next.issue, fromQueue: true)
            started = true
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
                    self.holdAfterFailure(routine.id, scheduledAt: scheduledAt)
                }
            case .skipped(let why), .notYet(let why):
                self.store.updateRun(id) { run in
                    run.outcome = .skipped
                    run.endedAt = .now
                    run.note = why
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
