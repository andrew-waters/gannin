import Foundation
import Testing
@testable import Gannin

/// The scheduling board: queue windows' open hours, where queued issues
/// fall in them, dropping into the queue, and carrying a run on in an
/// issue's own session.
struct ScheduleBoardTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "ScheduleBoardTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Saturday 10 October 2026, midnight UTC.
    private var saturday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))! }

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        saturday.addingTimeInterval(TimeInterval(dayOffset * 86400 + hour * 3600 + minute * 60))
    }

    private func issue(_ number: Int, org: String = "acme") -> IssueReference {
        IssueReference(org: org, id: "I_\(org)_\(number)", number: number, title: "Issue \(number)", repo: "\(org)/app",
                       url: URL(string: "https://github.com/\(org)/app/issues/\(number)")!)
    }

    private func window(_ start: Int, _ end: Int, days: Set<Int>? = Set(1...7), concurrency: Int = 1) -> Routine {
        var routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .issueQueue, name: "Window",
                                  schedule: .window(RoutineWindow(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end), days: days)),
                                  now: saturday)
        routine.concurrency = concurrency
        return routine
    }

    private func project(_ windows: [Routine], queue: [Int], pins: [Routine] = [], active: [RoutineRun] = [], paused: Bool = false) -> ScheduleProjection {
        ScheduleProjection.make(
            windows: windows, pins: pins, queue: queue.map { QueuedIssue(issue: issue($0), addedAt: saturday) },
            active: active, routines: windows + pins, paused: paused,
            range: DateInterval(start: saturday, duration: 7 * 86400), calendar: calendar
        )
    }

    @Test func openHoursRunPastMidnightAndKeepToTheirDays() {
        // Saturdays (7) and Sundays (1), 22:00 to 02:00.
        let late = window(22, 2, days: [7, 1]).schedule
        let hours = late.openIntervals(in: DateInterval(start: saturday, duration: 3 * 86400), calendar: calendar)
        #expect(hours.map(\.start) == [at(22), at(22, dayOffset: 1)])
        #expect(hours.map(\.end) == [at(2, dayOffset: 1), at(2, dayOffset: 2)])
        // Friday's window, still open at midnight, is cut to the range.
        let nightly = window(22, 2).schedule.openIntervals(in: DateInterval(start: saturday, duration: 86400), calendar: calendar)
        #expect(nightly.first == DateInterval(start: saturday, end: at(2)))
    }

    @Test func queuedIssuesFillTheWindowInOrder() {
        let one = project([window(6, 21)], queue: [1, 2, 3])
        #expect(one.bars.map(\.issue.number) == [1, 2, 3])
        #expect(one.bars.map(\.interval.start) == [at(6), at(7), at(8)])
        #expect(one.bars.map(\.kind) == [.queued(1), .queued(2), .queued(3)])

        let two = project([window(6, 21, concurrency: 2)], queue: [1, 2, 3])
        #expect(two.bars.map(\.interval.start) == [at(6), at(6), at(7)])
        #expect(Set(two.bars.prefix(2).map(\.lane.index)) == [0, 1])
    }

    @Test func runsGoingHoldTheirLane() {
        let open = window(6, 21)
        let run = RoutineRun(id: UUID(), routine: open.id, scheduledAt: at(5, 30), issue: issue(9), startedAt: at(5, 30), outcome: .running)
        let projection = project([open], queue: [1], active: [run])
        #expect(projection.bars.first { $0.kind == .running }?.interval.end == at(6, 30))
        #expect(projection.bars.first { $0.issue.number == 1 }?.interval.start == at(6, 30))
    }

    @Test func pausedOrWithNoWindowNothingQueuedIsPlaced() {
        #expect(project([window(6, 21)], queue: [1, 2], paused: true).later.map(\.issue.number) == [1, 2])
        #expect(project([], queue: [1]).later.map(\.issue.number) == [1])
    }

    @Test func pinsSitInTheirOwnLane() {
        let pin = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .pinned, schedule: .once(at(14)), issue: issue(5), now: saturday)
        let projection = project([window(6, 21)], queue: [], pins: [pin])
        #expect(projection.bars.count == 1)
        #expect(projection.bars[0].lane == ScheduleProjection.pinnedLane)
        #expect(projection.bars[0].interval == DateInterval(start: at(14), end: at(15)))
        #expect(projection.lanes.last == ScheduleProjection.pinnedLane)
    }

    @Test func insertingPlacesAndMovesWithinTheOrgsQueue() {
        let store = RoutineStore(directory: folder)
        store.enqueue(issue(1))
        store.enqueue(issue(9, org: "other"))
        store.enqueue(issue(2))
        store.insert(issue(3), at: 1)
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 3, 2])
        // Already queued, it moves rather than appearing twice.
        store.insert(issue(2), at: 0)
        #expect(store.queue(for: "acme").map(\.issue.number) == [2, 1, 3])
        store.insert(issue(2), at: 99)
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 3, 2])
        #expect(store.queue(for: "other").map(\.issue.number) == [9])
        // It's kept on disk in that order.
        #expect(RoutineStore(directory: folder).queue(for: "acme").map(\.issue.number) == [1, 3, 2])
    }

    @Test func aResumedRunIsToldToCarryOnAndHowFarItMayGo() throws {
        let routine = window(6, 21)
        let info = RoutineRunInfo(routine: routine, run: UUID(), resumed: true)
        #expect(info.resumed == true)
        let session = CodeSession(
            id: UUID(), issue: issue(7), repo: "acme/harness", branch: "7-issue-7", createdAt: .now,
            harnessRepo: "acme/harness", harnessPath: "~/Code/acme/harness"
        )
        let prompt = SessionStore.resumedIssuePrompt(session, info: info, note: "Keep it small.")
        #expect(prompt.contains("Carry on with acme/app#7"))
        #expect(prompt.contains("## Scheduled run"))
        #expect(prompt.hasSuffix("Keep it small."))
        // Runs recorded before `resumed` existed still read.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RoutineRunInfo(routine: routine, run: UUID()))) as! [String: Any]
        old["resumed"] = nil
        let decoded = try JSONDecoder().decode(RoutineRunInfo.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.resumed == nil)
    }
}
