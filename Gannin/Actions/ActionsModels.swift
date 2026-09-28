import Foundation

/// One GitHub Actions workflow run, as the runs list reports its latest
/// attempt. Earlier attempts aren't listed, so a run that failed and was
/// re-run shows only how the re-run ended.
nonisolated struct WorkflowRun: Codable, Hashable, Identifiable {
    let id: Int
    /// `owner/name`.
    let repo: String
    let workflowID: Int
    let name: String
    /// The workflow file, such as `.github/workflows/ci.yml`.
    let path: String
    let event: String
    let branch: String?
    let headSha: String
    let runNumber: Int
    let attempt: Int
    /// `queued`, `in_progress`, `completed` and so on.
    let status: String
    /// Set once completed: `success`, `failure`, `cancelled`, `skipped`,
    /// `timed_out`, `startup_failure`, `action_required`, `neutral` or `stale`.
    let conclusion: String?
    let createdAt: Date
    /// When the latest attempt started.
    let startedAt: Date?
    let updatedAt: Date
    let actor: String?
    let url: URL

    /// Identifies the workflow across its runs.
    var workflowKey: String { WorkflowRun.key(repo: repo, workflowID: workflowID) }

    static func key(repo: String, workflowID: Int) -> String { "\(repo)#\(workflowID)" }

    var isCompleted: Bool { status == "completed" }

    var outcome: RunOutcome {
        guard isCompleted else { return .running }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "cancelled": return .cancelled
        default: return .skipped
        }
    }

    /// Wall-clock time of the latest attempt, start to last update, for
    /// completed runs that ran (not skipped).
    var duration: TimeInterval? {
        guard isCompleted, outcome != .skipped, let startedAt else { return nil }
        let seconds = updatedAt.timeIntervalSince(startedAt)
        return seconds >= 0 ? seconds : nil
    }

    /// Passed only after being re-run, the usual sign of a flaky job.
    var passedOnRetry: Bool { outcome == .success && attempt > 1 }

    var shortName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// How a run ended, grouped for rates. Failure includes timeouts and
/// startup failures; skipped covers everything that didn't really run.
nonisolated enum RunOutcome: String, CaseIterable, Codable {
    case success = "Succeeded"
    case failure = "Failed"
    case cancelled = "Cancelled"
    case skipped = "Skipped"
    case running = "Running"
}

/// A job in one attempt of a run, fetched when a workflow is opened.
nonisolated struct WorkflowJob: Codable, Hashable, Identifiable {
    let id: Int
    let runID: Int
    let runAttempt: Int
    let name: String
    let status: String
    let conclusion: String?
    /// When the job was queued; the wait to `startedAt` is queue time.
    let createdAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let labels: [String]
    let runnerName: String?
    let steps: [WorkflowStep]
    let url: URL?

    var outcome: RunOutcome {
        guard status == "completed" else { return .running }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "cancelled": return .cancelled
        default: return .skipped
        }
    }

    var duration: TimeInterval? {
        guard outcome != .skipped, let startedAt, let completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(startedAt)
        return seconds >= 0 ? seconds : nil
    }

    var queueTime: TimeInterval? {
        guard outcome != .skipped, let createdAt, let startedAt else { return nil }
        let seconds = startedAt.timeIntervalSince(createdAt)
        return seconds >= 0 ? seconds : nil
    }

    /// The job's name without a matrix's values, so `test (ubuntu, 20)` and
    /// `test (macos, 22)` count as one job.
    var baseName: String {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return name }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? name : base
    }
}

nonisolated struct WorkflowStep: Codable, Hashable {
    let name: String
    let number: Int
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?

    var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(startedAt)
        return seconds >= 0 ? seconds : nil
    }
}

/// A repo the runs were fetched for, with its default branch.
nonisolated struct ActionsRepository: Codable, Hashable {
    let name: String
    var defaultBranch: String?
    /// Runs created from here to `syncedAt` are all held.
    var coveredFrom: Date
    var syncedAt: Date
}

/// Per-org Actions history kept on disk: runs from the window's starting
/// Monday, topped up on each sync, and jobs for runs that have been opened.
nonisolated struct ActionsHistory: Codable {
    static let currentVersion = 1

    var version: Int
    let orgLogin: String
    var syncedAt: Date
    var repositories: [String: ActionsRepository]
    var runs: [Int: WorkflowRun]
    /// Jobs of every attempt of a run, by run ID, fetched on demand.
    var jobs: [Int: [WorkflowJob]]
    /// The attempt `jobs` were fetched for, so a re-run fetches them again.
    var jobsAttempt: [Int: Int]
}
