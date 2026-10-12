import Foundation

/// Running several GitHub searches at once and cutting a date range into
/// weeks, as the issue and work log stores both do.
enum ParallelSearches {
    /// Searches run at most this many at once, to stay clear of GitHub's
    /// secondary rate limits.
    static let concurrency = 4

    /// Runs `operation` for each index in `0..<count`, `concurrency` at a
    /// time, and returns everything they fetched. `operation` is handed a
    /// callback for the number it has fetched so far, summed across all of
    /// them for `progress`.
    static func run<Element: Sendable>(
        count: Int,
        progress: @escaping (Int, Int?) -> Void,
        operation: @escaping @MainActor @Sendable (_ index: Int, _ fetched: @escaping @MainActor (Int) -> Void) async throws -> [Element]
    ) async throws -> [Element] {
        let tally = Tally(report: progress)
        func task(_ index: Int) -> @MainActor @Sendable () async throws -> [Element] {
            { try await operation(index) { tally.set(index, $0) } }
        }
        return try await withThrowingTaskGroup(of: [Element].self) { group in
            var next = 0
            while next < min(concurrency, count) {
                group.addTask(operation: task(next))
                next += 1
            }
            var results: [Element] = []
            while let batch = try await group.next() {
                results += batch
                if next < count {
                    group.addTask(operation: task(next))
                    next += 1
                }
            }
            return results
        }
    }

    /// Week-long `[start, end)` ranges covering `[from, to)`.
    static func weeks(from: Date, to: Date) -> [(Date, Date)] {
        var ranges: [(Date, Date)] = []
        var start = from
        while start < to {
            let end = min(Calendar.current.date(byAdding: .day, value: 7, to: start) ?? to, to)
            ranges.append((start, end))
            start = end
        }
        return ranges
    }

    /// What each parallel search has fetched so far, summed for the progress bar.
    private final class Tally {
        private var counts: [Int: Int] = [:]
        private let report: (Int, Int?) -> Void

        init(report: @escaping (Int, Int?) -> Void) {
            self.report = report
        }

        func set(_ index: Int, _ fetched: Int) {
            counts[index] = fetched
            report(counts.values.reduce(0, +), nil)
        }
    }
}
