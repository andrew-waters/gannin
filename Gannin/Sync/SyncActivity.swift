import Foundation
import Observation

/// One resource fetched from GitHub during a sync.
struct SyncStep: Identifiable {
    enum State: Equatable {
        case pending
        case running
        case done
        case failed(String)
        /// Never started because an earlier step failed or the sync was cancelled.
        case skipped
    }

    let id: String
    let title: String
    let detail: String?
    var state: State = .pending
    /// Items fetched so far, or the total once done.
    var count: Int?
    /// Items expected, when GitHub says up front.
    var total: Int?
    /// For a step made of several queries (weeks of merged PRs): how many
    /// are done, which drives the progress bar instead of the item count.
    var parts: (done: Int, of: Int)?
    /// GraphQL rate-limit points the step's queries cost.
    var cost = 0
    var startedAt: Date?
    var finishedAt: Date?

    /// 0-1 through the step: whole once done, by items while running.
    var fraction: Double {
        switch state {
        case .done, .failed, .skipped: 1
        case .pending: 0
        case .running:
            if let total, total > 0 {
                min(Double(count ?? 0) / Double(total), 1)
            } else if let parts, parts.of > 0 {
                Double(parts.done) / Double(parts.of)
            } else {
                0
            }
        }
    }

    /// Share of a sync's progress: the items it fetches, so a step of 149
    /// merged PRs outweighs one of 3 teams.
    var weight: Double {
        Double(max(total ?? count ?? 1, 1))
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

/// A single sync (the workload snapshot or the metrics history) for one
/// org, broken down into the resources it fetches.
@Observable
final class SyncRun: Identifiable {
    enum Kind: String, CaseIterable {
        case workload = "Workload"
        case metrics = "Metrics"
        case workLog = "Work log"
    }

    let id = UUID()
    let kind: Kind
    let startedAt = Date.now
    private(set) var finishedAt: Date?
    private(set) var failure: String?
    private(set) var steps: [SyncStep] = []

    init(kind: Kind) {
        self.kind = kind
    }

    var isRunning: Bool { finishedAt == nil }

    /// Queries outside any step, such as the up-front counts.
    private(set) var overheadCost = 0

    var cost: Int { steps.map(\.cost).reduce(0, +) + overheadCost }


    func add(_ id: String, title: String, detail: String? = nil) {
        steps.append(SyncStep(id: id, title: title, detail: detail))
    }

    /// Runs `work` as the step `id`, marking it running, then done with the
    /// count `count` returns, or failed. `work` gets a callback to report
    /// items fetched so far and, when known, how many to expect.
    func track<T>(
        _ id: String,
        count: (T) -> Int?,
        _ work: @MainActor (_ progress: @escaping (_ fetched: Int, _ total: Int?) -> Void) async throws -> T
    ) async throws -> T {
        update(id) {
            $0.state = .running
            $0.startedAt = .now
        }
        do {
            let result = try await SyncContext.$step.withValue(SyncContext.Step(run: self, id: id)) {
                try await work { [weak self] fetched, total in
                    self?.update(id) {
                        $0.count = fetched
                        $0.total = total ?? $0.total
                    }
                }
            }
            update(id) {
                $0.state = .done
                $0.count = count(result)
                $0.finishedAt = .now
            }
            return result
        } catch {
            update(id) {
                $0.state = Task.isCancelled || error is CancellationError ? .skipped : .failed(error.localizedDescription)
                $0.finishedAt = .now
            }
            throw error
        }
    }

    /// Ends the run. Steps that never got going are marked skipped.
    func finish(error: Error? = nil) {
        for index in steps.indices where steps[index].state == .pending || steps[index].state == .running {
            steps[index].state = .skipped
        }
        if let error, !(error is CancellationError) {
            failure = error.localizedDescription
        }
        finishedAt = .now
    }

    /// Runs queries that belong to the run but no one step (their cost
    /// still counts towards the run).
    func overhead<T>(_ work: @MainActor () async throws -> T) async throws -> T {
        try await SyncContext.$step.withValue(SyncContext.Step(run: self, id: "")) {
            try await work()
        }
    }

    /// The number of items a step will fetch, when known before it starts.
    func setTotal(_ total: Int, for id: String) {
        update(id) { $0.total = total }
    }

    func setParts(_ done: Int, of total: Int, for id: String) {
        update(id) { $0.parts = (done, total) }
    }

    func addCost(_ cost: Int, to id: String) {
        if steps.contains(where: { $0.id == id }) {
            update(id) { $0.cost += cost }
        } else {
            overheadCost += cost
        }
    }

    private func update(_ id: String, _ change: (inout SyncStep) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[index])
    }
}

/// The step a query is running for, so `GitHubAPI` can charge its cost
/// to it. Task-local, so parallel steps each see their own.
nonisolated enum SyncContext {
    struct Step: Sendable {
        let run: SyncRun
        let id: String
    }

    @TaskLocal static var step: Step?
}

/// The most recent run of each kind per org, for the sidebar sync panel.
@Observable
final class SyncActivity {
    private(set) var runs: [String: [SyncRun.Kind: SyncRun]] = [:]

    func begin(_ kind: SyncRun.Kind, org: String) -> SyncRun {
        let run = SyncRun(kind: kind)
        runs[org, default: [:]][kind] = run
        return run
    }

    func runs(for org: String) -> [SyncRun] {
        SyncRun.Kind.allCases.compactMap { runs[org]?[$0] }
    }

    func isSyncing(_ org: String) -> Bool {
        runs(for: org).contains(where: \.isRunning)
    }

    func clear() {
        runs = [:]
    }
}
