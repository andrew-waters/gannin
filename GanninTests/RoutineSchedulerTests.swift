import Foundation
import Testing
@testable import Gannin

/// The scheduler's decisions: what runs, what was missed, what was skipped
/// while paused, and how many queued issues a window may start.
struct RoutineSchedulerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private let everyDay: RoutineSchedule.WorkingDays = { _ in true }

    private func routine(_ schedule: RoutineSchedule, kind: RoutineKind = .report, created: Date? = nil) -> Routine {
        Routine.new(org: "acme", harnessRepo: "acme/harness", kind: kind, schedule: schedule, now: created ?? date(2026, 1, 1))
    }

    @Test func runsATimeJustPassed() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 9, 59, 50), now: date(2026, 10, 9, 10, 0, 5), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init(due: date(2026, 10, 9, 10)))
        // Nothing due between ticks.
        let quiet = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 10, 0, 5), now: date(2026, 10, 9, 10, 0, 20), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(quiet == .init())
    }

    @Test func timesWhileClosedOrAsleepAreMissed() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        // Closed from 18:30 to 09:10 the next morning.
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 18, 30), now: date(2026, 10, 10, 9, 10), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan.due == nil)
        #expect(plan.missed.count == 15)
        #expect(plan.missed.first == date(2026, 10, 9, 19))
        #expect(plan.missed.last == date(2026, 10, 10, 9))
        // Back within the grace of the last one: it runs, the rest are missed.
        let back = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 18, 30), now: date(2026, 10, 10, 9, 1), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(back.due == date(2026, 10, 10, 9))
        #expect(back.missed.count == 14)
    }

    @Test func pausedTimesAreSkipped() {
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 9, 9, 59), now: date(2026, 10, 9, 10, 0, 10), paused: true, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init(skipped: [date(2026, 10, 9, 10)]))
    }

    @Test func nothingFromBeforeItWasMadeOrWhileOff() {
        let made = date(2026, 10, 9, 9, 30)
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)), created: made)
        let plan = RoutineScheduler.plan(hourly, since: date(2026, 10, 8), now: date(2026, 10, 9, 9, 35), paused: false, calendar: calendar, isWorkingDay: everyDay)
        #expect(plan == .init())
        var off = hourly
        off.isEnabled = false
        #expect(RoutineScheduler.plan(off, since: date(2026, 10, 9, 9, 59), now: date(2026, 10, 9, 10, 0, 10), paused: false, calendar: calendar, isWorkingDay: everyDay) == .init())
    }

    @Test func windowsHaveNoTimesButFreeSlots() {
        var window = routine(.window(RoutineWindow(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 8), days: nil)), kind: .issueQueue)
        window.concurrency = 2
        let evening = date(2026, 10, 9, 19)
        #expect(RoutineScheduler.plan(window, since: date(2026, 10, 9, 17, 59), now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == .init())
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 2)
        #expect(RoutineScheduler.freeSlots(window, active: 1, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 1)
        #expect(RoutineScheduler.freeSlots(window, active: 3, now: evening, paused: false, calendar: calendar, isWorkingDay: everyDay) == 0)
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: evening, paused: true, calendar: calendar, isWorkingDay: everyDay) == 0)
        #expect(RoutineScheduler.freeSlots(window, active: 0, now: date(2026, 10, 9, 12), paused: false, calendar: calendar, isWorkingDay: everyDay) == 0)
    }

    @Test func checkRecordsGapsAndStarts() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoutineSchedulerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = RoutineStore(directory: folder)
        let hourly = routine(.every(minutes: 60, anchor: date(2026, 10, 9)))
        store.save(hourly)
        store.checked(at: date(2026, 10, 9, 6, 30))
        let scheduler = RoutineScheduler(store: store)
        scheduler.calendar = calendar
        scheduler.workingDays = { _ in { _ in true } }
        var started: [UUID] = []
        scheduler.start = { routine, _, _ in
            started.append(routine.id)
            return .started(session: UUID())
        }
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 30))
        await scheduler.startsFinished()
        #expect(started == [hourly.id])
        let runs = store.runs(for: hourly.id)
        #expect(runs.count == 2)
        #expect(runs.first?.outcome == .running)
        #expect(runs.first?.session != nil)
        #expect(runs.last?.outcome == .missed)
        #expect(runs.last?.count == 3)

        // A queue window drains one at a time up to its limit, taking each off.
        var window = routine(.window(RoutineWindow(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17), days: Set(1...7))), kind: .issueQueue)
        window.concurrency = 2
        store.save(window)
        for number in 1...3 {
            store.enqueue(IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                                         url: URL(string: "https://github.com/acme/app/issues/\(number)")!))
        }
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 45))
        await scheduler.startsFinished()
        #expect(store.runs(for: window.id).compactMap(\.issue?.number).sorted() == [1, 2])
        #expect(store.queue(for: "acme").map(\.issue.number) == [3])
    }

    @Test func aLookThatActsSavesItsTimeAndAQuietOneDoesNot() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoutineSchedulerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = RoutineStore(directory: folder)
        store.save(routine(.every(minutes: 60, anchor: date(2026, 10, 9))))
        let scheduler = RoutineScheduler(store: store)
        scheduler.calendar = calendar
        scheduler.workingDays = { _ in { _ in true } }
        scheduler.start = { _, _, _ in .started(session: UUID()) }
        let first = date(2026, 10, 9, 9, 59, 50)
        store.checked(at: first)
        // Nothing due: the time stays in memory.
        await scheduler.check(now: date(2026, 10, 9, 9, 59, 55))
        #expect(RoutineStore(directory: folder).checkedAt == first)
        // The 10:00 run is due: the look's time is on disk.
        let acting = date(2026, 10, 9, 10, 0, 5)
        await scheduler.check(now: acting)
        await scheduler.startsFinished()
        #expect(RoutineStore(directory: folder).checkedAt == acting)
    }

    @Test func aFailedQueuedStartGoesBackAndHoldsTheWindow() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoutineSchedulerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = RoutineStore(directory: folder)
        let scheduler = RoutineScheduler(store: store)
        scheduler.calendar = calendar
        scheduler.workingDays = { _ in { _ in true } }
        var tries = 0
        scheduler.start = { _, _, _ in
            tries += 1
            return .failed("The harness isn't checked out here.")
        }
        var window = routine(.window(RoutineWindow(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59), days: Set(1...7))), kind: .issueQueue)
        window.concurrency = 1
        store.save(window)
        for number in 1...3 {
            store.enqueue(IssueReference(org: "acme", id: "I_\(number)", number: number, title: "Issue \(number)", repo: "acme/app",
                                         url: URL(string: "https://github.com/acme/app/issues/\(number)")!))
        }
        store.checked(at: date(2026, 10, 9, 10))
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 15))
        await scheduler.startsFinished()
        // One try, the issue back at the front, the rest still queued.
        #expect(tries == 1)
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 2, 3])
        #expect(store.runs(for: window.id).map(\.outcome) == [.failed])
        // Held off on the next look.
        await scheduler.check(now: date(2026, 10, 9, 10, 0, 30))
        await scheduler.startsFinished()
        #expect(tries == 1)
    }

    // MARK: Review windows

    private func pullRequest(_ number: Int, org: String = "acme") -> PullRequestReference {
        PullRequestReference(org: org, id: "PR_\(org)_\(number)", number: number, title: "PR \(number)", repo: "\(org)/app",
                             url: URL(string: "https://github.com/\(org)/app/pull/\(number)")!)
    }

    private func reviewWindow(_ start: Int, _ end: Int, atOnce: Int = 1, org: String = "acme") -> Routine {
        var window = Routine.new(org: org, harnessRepo: "", kind: .reviewQueue,
                                 schedule: .window(RoutineWindow(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end), days: nil)))
        window.concurrency = atOnce
        return window
    }

    /// A scheduler over a fresh store whose review starts count as running
    /// until `finish`, with `windows` for every org.
    private final class Reviews {
        let store: RoutineStore
        let scheduler: RoutineScheduler
        var windows: [String: [Routine]] = [:]
        var running: [String] = []
        var started: [Int] = []
        var answer: (QueuedReview) -> RoutineStart = { _ in .started(session: UUID()) }
        var busy: Set<Int> = []

        init(calendar: Calendar) {
            store = RoutineStore(directory: FileManager.default.temporaryDirectory.appending(path: "RoutineSchedulerTests-\(UUID().uuidString)", directoryHint: .isDirectory))
            scheduler = RoutineScheduler(store: store)
            scheduler.calendar = calendar
            scheduler.workingDays = { _ in { _ in true } }
            scheduler.reviewWindows = { [unowned self] org in self.windows[org] ?? [] }
            scheduler.runningReviews = { [unowned self] in self.running.count }
            scheduler.reviewReady = { [unowned self] review in !self.busy.contains(review.pullRequest.number) }
            scheduler.startReview = { [unowned self] review, _ in
                let result = self.answer(review)
                if case .started = result {
                    self.started.append(review.pullRequest.number)
                    self.running.append(review.id)
                }
                return result
            }
        }

        func queue(_ prs: [PullRequestReference]) {
            for pr in prs { store.enqueueReview(QueuedReview(pullRequest: pr, queuedAt: .now)) }
        }

        func check(_ now: Date) async {
            await scheduler.check(now: now)
            await scheduler.startsFinished()
        }
    }

    @Test func aReviewWindowStartsQueuedReviewsInOrderUpToItsNumber() async {
        let reviews = Reviews(calendar: calendar)
        let lunch = reviewWindow(12, 13, atOnce: 2)
        reviews.windows["acme"] = [lunch]
        reviews.queue((1...3).map { pullRequest($0) })
        // Shut: nothing starts.
        await reviews.check(date(2026, 10, 21, 11, 59))
        #expect(reviews.started.isEmpty)
        // Open: the first two, in queue order, each recorded against the window.
        await reviews.check(date(2026, 10, 21, 12, 0, 15))
        #expect(reviews.started == [1, 2])
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [3])
        #expect(reviews.store.runs(for: lunch.id).compactMap(\.pullRequest?.number).sorted() == [1, 2])
        // One finishes: the third takes its place.
        reviews.running.removeFirst()
        await reviews.check(date(2026, 10, 21, 12, 20))
        #expect(reviews.started == [1, 2, 3])
    }

    @Test func reviewsRunningInAnotherOrgFillTheWindow() async {
        let reviews = Reviews(calendar: calendar)
        reviews.windows["acme"] = [reviewWindow(12, 13)]
        reviews.windows["other"] = [reviewWindow(12, 13, org: "other")]
        reviews.queue([pullRequest(1, org: "other"), pullRequest(1)])
        await reviews.check(date(2026, 10, 21, 12, 0, 15))
        // One review at once across the Mac, whichever org went first.
        #expect(reviews.started.count == 1)
        #expect(reviews.store.reviewQueue.count == 1)
    }

    @Test func aClosingWindowStartsNothingNew() async {
        let reviews = Reviews(calendar: calendar)
        reviews.windows["acme"] = [reviewWindow(12, 13)]
        reviews.queue([pullRequest(1), pullRequest(2)])
        await reviews.check(date(2026, 10, 21, 12, 50))
        #expect(reviews.started == [1])
        // The first finishes after the window has shut: the second waits.
        reviews.running.removeAll()
        await reviews.check(date(2026, 10, 21, 13, 5))
        #expect(reviews.started == [1])
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [2])
    }

    @Test func aReviewNoLongerWantedIsSkippedWithWhy() async {
        let reviews = Reviews(calendar: calendar)
        let lunch = reviewWindow(12, 13)
        reviews.windows["acme"] = [lunch]
        reviews.answer = { $0.pullRequest.number == 1 ? .skipped("It was merged while it waited.") : .started(session: UUID()) }
        reviews.queue([pullRequest(1), pullRequest(2)])
        await reviews.check(date(2026, 10, 21, 12, 0, 15))
        await reviews.check(date(2026, 10, 21, 12, 0, 30))
        let skipped = reviews.store.runs(for: lunch.id).first { $0.pullRequest?.number == 1 }
        #expect(skipped?.outcome == .skipped)
        #expect(skipped?.note == "It was merged while it waited.")
        #expect(reviews.started == [2])
        #expect(reviews.store.reviewQueue.isEmpty)
    }

    @Test func aFailedReviewStartGoesBackAndHoldsItsWindow() async {
        let reviews = Reviews(calendar: calendar)
        reviews.windows["acme"] = [reviewWindow(0, 23)]
        var tries = 0
        reviews.answer = { _ in
            tries += 1
            return .failed("Couldn't look the PR up.")
        }
        reviews.queue([pullRequest(1), pullRequest(2)])
        await reviews.check(date(2026, 10, 21, 10))
        #expect(tries == 1)
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [1, 2])
        await reviews.check(date(2026, 10, 21, 10, 0, 15))
        #expect(tries == 1)
    }

    @Test func runNowStartsAQueuedReviewOutsideEveryWindow() async {
        let reviews = Reviews(calendar: calendar)
        let lunch = reviewWindow(12, 13)
        reviews.windows["acme"] = [lunch]
        reviews.queue([pullRequest(1), pullRequest(2)])
        let second = reviews.store.reviewQueue(for: "acme")[1]
        reviews.scheduler.runReviewNow(second)
        await reviews.scheduler.startsFinished()
        #expect(reviews.started == [2])
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [1])
        #expect(reviews.store.runs(for: lunch.id).count == 1)
    }

    @Test func aBusyLookAgainWaitsWithoutHoldingUpTheRest() async {
        let reviews = Reviews(calendar: calendar)
        reviews.windows["acme"] = [reviewWindow(0, 23)]
        reviews.busy = [1]
        reviews.queue([pullRequest(1), pullRequest(2)])
        await reviews.check(date(2026, 10, 21, 10))
        #expect(reviews.started == [2])
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [1])
        // Run Now while it's busy puts it back, and the window isn't held.
        reviews.answer = { _ in .notYet("Its review was busy, so it waits for the next turn.") }
        let runsBefore = reviews.store.runs.count
        reviews.scheduler.runReviewNow(reviews.store.reviewQueue(for: "acme")[0])
        await reviews.scheduler.startsFinished()
        #expect(reviews.store.reviewQueue(for: "acme").map(\.pullRequest.number) == [1])
        // It leaves no run behind.
        #expect(reviews.store.runs.count == runsBefore)
        reviews.busy = []
        reviews.running = []
        reviews.answer = { _ in .started(session: UUID()) }
        await reviews.check(date(2026, 10, 21, 10, 0, 15))
        #expect(reviews.started == [2, 1])
    }

    @Test func pauseAllHoldsTheQueueEvenWithNoWindows() async {
        let reviews = Reviews(calendar: calendar)
        reviews.queue([pullRequest(1)])
        reviews.store.setPaused(true)
        await reviews.check(date(2026, 10, 21, 3))
        #expect(reviews.started.isEmpty)
        reviews.store.setPaused(false)
        await reviews.check(date(2026, 10, 21, 3, 0, 15))
        #expect(reviews.started == [1])
    }

    @Test func withNoWindowsFailedStartsKeepBackingOffRatherThanStopping() async {
        let reviews = Reviews(calendar: calendar)
        var tries = 0
        reviews.answer = { _ in
            tries += 1
            return .failed("Couldn't look the PR up.")
        }
        reviews.queue([pullRequest(1)])
        // Holds count from the look's time when it's later than now: 5, 10,
        // 20 minutes, then 20 again past the fourth failure, never for good.
        for minute in [0, 6, 17, 38, 59] {
            await reviews.check(date(2030, 1, 1, 10, minute))
        }
        #expect(tries == 5)
        #expect(reviews.scheduler.heldUntil[RoutineScheduler.reviewQueueRuns] == date(2030, 1, 1, 11, 19))
    }

    @Test func withNoWindowsALeftoverQueueDrainsAsAutoReviewWould() async {
        let reviews = Reviews(calendar: calendar)
        reviews.queue((1...3).map { pullRequest($0) })
        await reviews.check(date(2026, 10, 21, 3))
        #expect(reviews.started == [1, 2])
        #expect(reviews.store.runs(for: RoutineScheduler.reviewQueueRuns).count == 2)
    }
}
