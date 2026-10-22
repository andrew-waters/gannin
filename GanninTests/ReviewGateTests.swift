import Foundation
import Testing
@testable import Gannin

/// Whether an automatic review starts now or waits for a review window.
struct ReviewGateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let everyDay: RoutineSchedule.WorkingDays = { _ in true }

    private func window(_ start: Int, _ end: Int, atOnce: Int = 1, org: String = "acme") -> Routine {
        var routine = Routine.new(org: org, harnessRepo: "", kind: .reviewQueue,
                                  schedule: .window(RoutineWindow(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end), days: nil)))
        routine.concurrency = atOnce
        return routine
    }

    private func decide(_ windows: [Routine], at now: Date, running: Int = 0, paused: Bool = false) -> ReviewGate.Decision {
        ReviewGate.decide(now: now, windows: windows, running: running, paused: paused, calendar: calendar, isWorkingDay: everyDay)
    }

    @Test func withNoWindowsReviewsStartAsBefore() {
        #expect(decide([], at: date(2026, 10, 21, 3)) == .start(limit: AutoReview.maxRunning))
        #expect(decide([], at: date(2026, 10, 21, 3), paused: true) == .start(limit: AutoReview.maxRunning))
        var off = window(12, 13)
        off.isEnabled = false
        #expect(decide([off], at: date(2026, 10, 21, 3)) == .start(limit: AutoReview.maxRunning))
    }

    @Test func insideAWindowWithRoomItStarts() {
        let lunch = window(12, 13, atOnce: 2)
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30)) == .start(limit: 2))
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30), running: 1) == .start(limit: 2))
    }

    @Test func outsideEveryWindowItWaits() {
        let windows = [window(12, 13), window(18, 20)]
        #expect(decide(windows, at: date(2026, 10, 21, 9)) == .queue)
        #expect(decide(windows, at: date(2026, 10, 21, 13)) == .queue)
        #expect(decide(windows, at: date(2026, 10, 21, 19)) == .start(limit: 1))
    }

    @Test func aWindowPastMidnightIsOpenTheNextMorning() {
        let night = window(22, 6)
        #expect(decide([night], at: date(2026, 10, 21, 23)) == .start(limit: 1))
        #expect(decide([night], at: date(2026, 10, 22, 5, 59)) == .start(limit: 1))
        #expect(decide([night], at: date(2026, 10, 22, 6)) == .queue)
    }

    @Test func reviewsRunningInAnyOrgFillTheWindow() {
        // `running` counts every automatic review on the Mac, so another
        // org's review takes this window's only place.
        let lunch = window(12, 13)
        #expect(decide([lunch], at: date(2026, 10, 21, 12, 30), running: 1) == .queue)
        // Overlapping windows don't add up: the roomiest open one decides.
        let wide = window(11, 14, atOnce: 2)
        #expect(decide([lunch, wide], at: date(2026, 10, 21, 12, 30), running: 1) == .start(limit: 2))
        #expect(decide([lunch, wide], at: date(2026, 10, 21, 12, 30), running: 2) == .queue)
    }

    @Test func whilePausedItWaitsEvenInAWindow() {
        #expect(decide([window(12, 13)], at: date(2026, 10, 21, 12, 30), paused: true) == .queue)
    }

    @Test func windowsNotYetKnownStartNothing() {
        // Just after launch, before sign-in or the harness has loaded.
        #expect(ReviewGate.decide(now: date(2026, 10, 21, 12, 30), windows: nil, running: 0, paused: false, calendar: calendar, isWorkingDay: everyDay) == .unknown)
    }
}

/// What a queued review's turn comes to before it starts.
struct QueuedReviewCheckTests {
    private let pr = PullRequestReference(org: "acme", id: "PR_1", number: 1, title: "PR 1", repo: "acme/app",
                                          url: URL(string: "https://github.com/acme/app/pull/1")!)
    private let open = PullRequestState(state: "OPEN", isDraft: false)

    private var request: QueuedReview { QueuedReview(pullRequest: pr, queuedAt: .now) }
    private var lookAgain: QueuedReview {
        QueuedReview(pullRequest: pr, lookAgain: .init(session: UUID(), hasNewCommits: true, newComments: 0), queuedAt: .now)
    }

    private func facts(_ state: PullRequestState?, requested: Set<String>? = ["PR_1"]) -> QueuedReviewCheck.Facts {
        var facts = QueuedReviewCheck.Facts(requested: requested)
        facts.pullRequest = state
        return facts
    }

    @Test func anOpenRequestStillAskingGoesAhead() {
        #expect(QueuedReviewCheck.verdict(request, facts(open)) == nil)
        // Before the first look at requests, it isn't held to them.
        #expect(QueuedReviewCheck.verdict(request, facts(open, requested: nil)) == nil)
    }

    @Test func aPRThatChangedWhileItWaitedIsSkipped() {
        #expect(QueuedReviewCheck.verdict(request, facts(PullRequestState(state: "MERGED", isDraft: false))) == .skipped("It was merged while it waited."))
        #expect(QueuedReviewCheck.verdict(request, facts(PullRequestState(state: "CLOSED", isDraft: false))) == .skipped("It was closed while it waited."))
        #expect(QueuedReviewCheck.verdict(request, facts(PullRequestState(state: "OPEN", isDraft: true))) == .skipped("It was made a draft while it waited."))
        #expect(QueuedReviewCheck.verdict(request, facts(nil)) == .skipped("The PR is gone."))
        // The same holds for a Look Again.
        #expect(QueuedReviewCheck.verdict(lookAgain, facts(PullRequestState(state: "MERGED", isDraft: false))) == .skipped("It was merged while it waited."))
    }

    @Test func aRequestNoLongerAskingOrDismissedIsSkipped() {
        // `requested` leaves out dismissed requests.
        #expect(QueuedReviewCheck.verdict(request, facts(open, requested: [])) == .skipped("It no longer asks for your review, or you dismissed it."))
    }

    @Test func aRequestAlreadyReviewedStartingOrOffIsHandledWithoutStarting() {
        var reviewed = facts(open)
        reviewed.hasReview = true
        #expect(QueuedReviewCheck.verdict(request, reviewed) == .skipped("It already has a review."))
        var starting = facts(open)
        starting.isStarting = true
        #expect(QueuedReviewCheck.verdict(request, starting) == .notYet("Its review was already being started."))
        var off = facts(open)
        off.autoReviewIsOn = false
        #expect(QueuedReviewCheck.verdict(request, off) == .skipped("Auto review is off for acme."))
    }

    @Test func aLookAgainNeedsItsReviewWatchingAndFree() {
        var finished = facts(open, requested: [])
        finished.reviewIsWatching = false
        #expect(QueuedReviewCheck.verdict(lookAgain, finished) == .skipped("Its review was finished, or stopped watching the PR."))
        var busy = facts(open, requested: [])
        busy.reviewIsWatching = true
        busy.reviewIsBusy = true
        #expect(QueuedReviewCheck.verdict(lookAgain, busy) == .notYet("Its review was busy, so it waits for the next turn."))
        // A Look Again isn't held to the requests: the request was answered long ago.
        var free = facts(open, requested: [])
        free.reviewIsWatching = true
        #expect(QueuedReviewCheck.verdict(lookAgain, free) == nil)
    }
}
