import Foundation
import Observation

/// Merged-PR history per org, backfilled to the metrics window and topped
/// up incrementally, persisted as JSON in Application Support.
@Observable
final class MetricsStore {
    static let windowKey = "metricsWindowDays"
    static let defaultWindowDays = 30
    static let windowOptions = [7, 14, 30, 90]

    private(set) var histories: [String: MetricsHistory] = [:]
    private(set) var syncing: Set<String> = []
    private(set) var errors: [String: String] = [:]

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
    }

    func history(for org: String) -> MetricsHistory? { histories[org] }

    /// Start of the stored range for a window: the Monday on or before
    /// `now - windowDays`, so every weekly bucket in view is complete.
    static func coverageStart(windowDays: Int, now: Date = .now) -> Date {
        let windowStart = Calendar.metrics.date(byAdding: .day, value: -windowDays, to: now) ?? now
        return Calendar.metrics.startOfWeek(for: windowStart)
    }

    func sync(_ org: String, windowDays: Int, force: Bool = false) async {
        loadCached(org)
        guard let api = auth.api, !syncing.contains(org) else { return }

        let now = Date.now
        let start = Self.coverageStart(windowDays: windowDays, now: now)
        var history = histories[org] ?? MetricsHistory(
            orgLogin: org,
            coveredFrom: now,
            syncedAt: .distantPast,
            pullRequests: [:],
            openedPerWeek: [:]
        )
        let isFresh = now.timeIntervalSince(history.syncedAt) < 10 * 60
        if !force && isFresh && history.coveredFrom <= start { return }

        syncing.insert(org)
        defer { syncing.remove(org) }
        do {
            // Backfill anything older than we hold, then top up since the
            // last sync with a day of overlap.
            if history.coveredFrom > start {
                for pr in try await api.metricPullRequests(org: org, from: start, to: history.coveredFrom) {
                    history.pullRequests[pr.id] = pr
                }
                history.coveredFrom = start
            }
            if history.syncedAt != .distantPast {
                let since = history.syncedAt.addingTimeInterval(-24 * 60 * 60)
                for pr in try await api.metricPullRequests(org: org, from: since, to: now) {
                    history.pullRequests[pr.id] = pr
                }
            }

            // Opened counts are cheap: fetch missing weeks and refresh the
            // last two, which may still be changing.
            let recent = Calendar.metrics.date(byAdding: .day, value: -7, to: Calendar.metrics.startOfWeek(for: now)) ?? now
            let weeks = Self.weeks(from: start, to: now).filter { history.openedPerWeek[$0] == nil || $0 >= recent }
            for (week, count) in try await api.openedCounts(org: org, weeks: weeks) {
                history.openedPerWeek[week] = count
            }

            history.syncedAt = now
            histories[org] = history
            errors[org] = nil
            save(history)
        } catch is CancellationError {
        } catch APIError.unauthorized {
            auth.signOut()
        } catch {
            errors[org] = error.localizedDescription
        }
    }

    static func weeks(from start: Date, to end: Date) -> [Date] {
        var weeks: [Date] = []
        var week = Calendar.metrics.startOfWeek(for: start)
        while week <= end {
            weeks.append(week)
            guard let next = Calendar.metrics.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return weeks
    }

    func clear() {
        histories = [:]
        errors = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    private func loadCached(_ org: String) {
        guard histories[org] == nil,
              let data = try? Data(contentsOf: Self.fileURL(org)),
              let history = try? Self.decoder.decode(MetricsHistory.self, from: data) else {
            return
        }
        histories[org] = history
    }

    private func save(_ history: MetricsHistory) {
        if let data = try? Self.encoder.encode(history) {
            try? data.write(to: Self.fileURL(history.orgLogin), options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Metrics", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(org).json")
    }
}
