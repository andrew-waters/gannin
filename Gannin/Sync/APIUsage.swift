import Foundation
import Observation

/// The source a request is charged to. Task-local, so a fetcher names it
/// once and everything it awaits (child tasks too) is charged to it.
nonisolated enum UsageContext {
    @TaskLocal static var source: SyncSource?
}

/// Runs `work` with its GitHub requests charged to `source`.
func chargingTo<T>(_ source: SyncSource, _ work: @MainActor () async throws -> T) async rethrows -> T {
    try await UsageContext.$source.withValue(source) {
        try await work()
    }
}

/// Every GitHub request Gannin made in the last day, by source: GraphQL
/// points (as `rateLimit` reports each query's cost) and REST requests, for
/// Settings › Sync. Kept on disk, so a relaunch doesn't forget the hour.
@Observable
final class APIUsage {
    static let shared = APIUsage()

    struct Entry: Codable {
        let at: Date
        let source: SyncSource
        /// GraphQL points, or 1 for a REST request.
        let cost: Int
        let isREST: Bool
    }

    struct Total {
        var points = 0
        var requests = 0
        var restRequests = 0
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let kept: TimeInterval = 24 * 60 * 60

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? Self.decoder.decode([Entry].self, from: data) {
            entries = saved.filter { -$0.at.timeIntervalSinceNow < Self.kept }
        }
    }

    /// The request's source: the one its fetcher named, else its sync run's.
    static var currentSource: SyncSource {
        UsageContext.source ?? SyncContext.step.map { SyncSource(kind: $0.run.kind) } ?? .other
    }

    func record(cost: Int, isREST: Bool, source: SyncSource = APIUsage.currentSource) {
        let now = Date.now
        entries.append(Entry(at: now, source: source, cost: max(cost, 0), isREST: isREST))
        if let first = entries.first, now.timeIntervalSince(first.at) > Self.kept {
            entries.removeAll { now.timeIntervalSince($0.at) > Self.kept }
        }
        scheduleSave()
    }

    /// Each source's spend since `date`, with everything's under `nil`.
    func totals(since date: Date) -> (bySource: [SyncSource: Total], all: Total) {
        var bySource: [SyncSource: Total] = [:]
        var all = Total()
        for entry in entries.reversed() {
            guard entry.at >= date else { break }
            var total = bySource[entry.source] ?? Total()
            if entry.isREST {
                total.restRequests += 1
                all.restRequests += 1
            } else {
                total.points += entry.cost
                total.requests += 1
                all.points += entry.cost
                all.requests += 1
            }
            bySource[entry.source] = total
        }
        return (bySource, all)
    }

    /// How far back the ledger reaches, for saying "since launch" honestly.
    var earliest: Date? { entries.first?.at }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: Disk

    /// Written a few seconds after the last request, not after each.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            if let data = try? Self.encoder.encode(entries) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "APIUsage.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
