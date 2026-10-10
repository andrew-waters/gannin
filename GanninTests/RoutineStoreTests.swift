import Foundation
import Testing
@testable import Gannin

/// Routines, the agent queue and run history, kept on this Mac.
struct RoutineStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "RoutineStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func issue(_ number: Int, org: String = "acme") -> IssueReference {
        IssueReference(org: org, id: "I_\(org)_\(number)", number: number, title: "Issue \(number)", repo: "\(org)/app",
                       url: URL(string: "https://github.com/\(org)/app/issues/\(number)")!)
    }

    @Test func newRoutinesStartLocalOnly() {
        for kind in RoutineKind.allCases {
            let routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: kind)
            #expect(routine.limit == .localOnly)
            #expect(routine.maxMinutes == Routine.defaultMaxMinutes)
            #expect(routine.schedule.problem() == nil)
        }
        #expect(Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .issueQueue).schedule.isWindow)
        #expect(Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .pinned, issue: issue(4)).name == "acme/app#4 Issue 4")
    }

    @Test func keepsEverythingOnDisk() {
        let store = RoutineStore(directory: folder)
        let routine = Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .report, name: "Weekly report", now: Date(timeIntervalSince1970: 1_800_000_000))
        store.save(routine)
        store.enqueue(issue(1))
        store.setPaused(true)
        store.record(RoutineRun(id: UUID(), routine: routine.id, scheduledAt: .now, outcome: .finished))

        let again = RoutineStore(directory: folder)
        #expect(again.routines == [routine])
        #expect(again.queue.map(\.issue) == [issue(1)])
        #expect(again.isPaused)
        #expect(again.runs(for: routine.id).count == 1)

        again.remove(routine.id)
        #expect(RoutineStore(directory: folder).runs.isEmpty)
    }

    @Test func queueKeepsOrderPerOrg() {
        let store = RoutineStore(directory: folder)
        store.enqueue(issue(1))
        store.enqueue(issue(9, org: "other"))
        store.enqueue(issue(2))
        store.enqueue(issue(3))
        store.enqueue(issue(2))
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 2, 3])

        store.move(in: "acme", fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.queue(for: "acme").map(\.issue.number) == [3, 1, 2])
        #expect(store.queue(for: "other").map(\.issue.number) == [9])

        store.move(issue(3).id, toFront: false)
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 2, 3])

        store.dequeue(issue(2).id)
        #expect(store.queue(for: "acme").map(\.issue.number) == [1, 3])
        #expect(RoutineStore(directory: folder).queue(for: "acme").map(\.issue.number) == [1, 3])
    }

    @Test func gapsAreOneRow() {
        let store = RoutineStore(directory: folder)
        let routine = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let times = (0..<96).map { start.addingTimeInterval(Double($0) * 600) }
        store.recordGap(times, routine: routine, outcome: .missed)
        store.recordGap([], routine: routine, outcome: .missed)
        let runs = store.runs(for: routine)
        #expect(runs.count == 1)
        #expect(runs[0].count == 96)
        #expect(runs[0].scheduledAt == times[0])
        #expect(runs[0].lastScheduledAt == times[95])
        #expect(runs[0].summary.hasPrefix("Missed 96 times, "))
    }

    @Test func keepsTheNewestRunsButNeverOneGoing() {
        let store = RoutineStore(directory: folder)
        let routine = UUID()
        let going = RoutineRun(id: UUID(), routine: routine, scheduledAt: .distantPast, outcome: .running)
        store.record(going)
        for index in 0..<RoutineStore.maxRuns {
            store.record(RoutineRun(id: UUID(), routine: routine, scheduledAt: Date(timeIntervalSince1970: Double(index)), outcome: .finished))
        }
        #expect(store.runs.count == RoutineStore.maxRuns)
        #expect(store.run(going.id) != nil)
        #expect(store.activeRuns.map(\.id) == [going.id])
    }
}
