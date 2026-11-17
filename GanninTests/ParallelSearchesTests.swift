import Foundation
import Testing
@testable import Gannin

@MainActor
struct ParallelSearchesTests {
    @Test func cutsARangeIntoContiguousWeeks() {
        let from = Date(timeIntervalSince1970: 1_791_590_400)
        let to = Calendar.current.date(byAdding: .day, value: 15, to: from)!
        let weeks = ParallelSearches.weeks(from: from, to: to)
        #expect(weeks.count == 3)
        #expect(weeks.first?.0 == from)
        #expect(weeks.last?.1 == to)
        for (earlier, later) in zip(weeks, weeks.dropFirst()) { #expect(earlier.1 == later.0) }
    }

    @Test func cutsARangeIntoContiguousDays() {
        let from = Date(timeIntervalSince1970: 1_791_590_400)
        let to = Calendar.current.date(byAdding: .day, value: 3, to: from)!.addingTimeInterval(3_600)
        let days = ParallelSearches.days(from: from, to: to)
        #expect(days.count == 4)
        #expect(days.first?.0 == from)
        #expect(days.last?.1 == to)
        for (earlier, later) in zip(days, days.dropFirst()) { #expect(earlier.1 == later.0) }
        #expect(days.dropLast().allSatisfy { Calendar.current.dateComponents([.day], from: $0.0, to: $0.1).day == 1 })
    }

    @Test func returnsEverySearchsResultsAndSumsProgress() async throws {
        var lastTotal = 0
        let results = try await ParallelSearches.run(count: 10, progress: { total, _ in lastTotal = total }) { index, fetched in
            fetched(2)
            return [index, index + 100]
        }
        #expect(Set(results) == Set((0..<10).flatMap { [$0, $0 + 100] }))
        #expect(lastTotal == 20)
    }

    @Test func noSearchesReturnNothing() async throws {
        let results: [Int] = try await ParallelSearches.run(count: 0, progress: { _, _ in }) { _, _ in [1] }
        #expect(results.isEmpty)
    }
}
