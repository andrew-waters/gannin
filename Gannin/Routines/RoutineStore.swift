import Foundation
import Observation
import SwiftUI

/// How far a scheduled code or issue run may go unattended (R9). A new
/// routine, queue window or pinned issue starts on Local only (R10).
enum RoutineLimit: String, Codable, CaseIterable, Identifiable {
    /// Commits in its worktree, never pushes.
    case localOnly
    /// May push and open a draft PR.
    case draftPR
    /// May open a PR ready for review.
    case readyPR

    var id: Self { self }

    var label: String {
        switch self {
        case .localOnly: "Local only"
        case .draftPR: "Draft PR"
        case .readyPR: "Ready PR"
        }
    }

    var explanation: String {
        switch self {
        case .localOnly: "Commits in its worktree and never pushes."
        case .draftPR: "May push its branch and open a draft pull request."
        case .readyPR: "May push its branch and open a pull request ready for review."
        }
    }
}

/// What a routine starts.
enum RoutineKind: String, Codable, CaseIterable, Identifiable {
    /// A report: an Ask-shaped session with no code worktree, its files
    /// kept with the run (R4).
    case report
    /// Maintenance: worktrees of the routine's repos, a branch a run (R5).
    case code
    /// A window that drains the agent queue (R7).
    case issueQueue
    /// An issue pinned to a time (R8).
    case pinned

    var id: Self { self }

    var label: String {
        switch self {
        case .report: "Report"
        case .code: "Maintenance"
        case .issueQueue: "Queue window"
        case .pinned: "Pinned issue"
        }
    }

    var systemImage: String {
        switch self {
        case .report: "doc.text.magnifyingglass"
        case .code: "wrench.and.screwdriver"
        case .issueQueue: "tray.full"
        case .pinned: "pin"
        }
    }

    /// Whether its runs work on code, so the push limit applies.
    var touchesCode: Bool { self != .report }
}

/// A recurring agent session, a queue window or a pinned issue, the
/// user's own, kept on this Mac (R15).
struct Routine: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var org: String
    /// The project harness its sessions run in (`owner/name`).
    var harnessRepo: String
    var kind: RoutineKind
    /// What the session is told: a report's question, a maintenance task.
    /// A queue window's or pinned issue's is added to the issue's prompt.
    var prompt: String = ""
    /// The team's prompts (`prompts/<name>.md`) added after it, by name.
    var teamPrompts: [String] = []
    /// A maintenance routine's repos (`owner/name`).
    var repos: [String] = []
    var schedule: RoutineSchedule
    var limit: RoutineLimit = .localOnly
    /// Longest a run may go before it's stopped (R11).
    var maxMinutes: Int = 60
    /// Most a run may cost, in US dollars, before it's stopped (R11).
    var maxCost: Double = 5
    /// How many of a queue window's runs go at once (R7).
    var concurrency: Int = 1
    /// A pinned issue's issue.
    var issue: IssueReference?
    var isEnabled = true
    let createdAt: Date

    static let defaultMaxMinutes = 60
    static let defaultMaxCost = 5.0

    /// A new routine on Local only (R10), its limits the defaults.
    static func new(org: String, harnessRepo: String, kind: RoutineKind, name: String = "", schedule: RoutineSchedule? = nil, issue: IssueReference? = nil, now: Date = .now) -> Routine {
        let midnight = Calendar.current.startOfDay(for: now)
        let fallback: RoutineSchedule = switch kind {
        case .issueQueue: .window(RoutineWindow(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 8), days: nil))
        case .pinned: .once(Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now)
        case .report: .workingDays(TimeOfDay(hour: 9))
        case .code: .every(minutes: 7 * 24 * 60, anchor: midnight)
        }
        return Routine(
            id: UUID(), name: name.isEmpty ? (issue.map { "\($0.reference) \($0.title)" } ?? kind.label) : name,
            org: org, harnessRepo: harnessRepo, kind: kind, schedule: schedule ?? fallback, issue: issue, createdAt: now
        )
    }
}

/// An issue waiting in the agent queue, in order (R6).
struct QueuedIssue: Codable, Identifiable, Hashable {
    var id: String { issue.id }
    let issue: IssueReference
    let addedAt: Date
}

/// One run of a routine (R13), or a gap of times missed or skipped.
struct RoutineRun: Codable, Identifiable, Hashable {
    enum Outcome: String, Codable {
        case running
        /// Claude is asking something; the clock runs on (R12).
        case needsYou
        case finished
        case stoppedAtLimit
        /// Due while Gannin was closed or the Mac asleep (R2).
        case missed
        /// Due while routines were paused (R14).
        case skippedPaused
        case failed

        var label: String {
            switch self {
            case .running: "Running"
            case .needsYou: "Needs you"
            case .finished: "Finished"
            case .stoppedAtLimit: "Stopped at limit"
            case .missed: "Missed"
            case .skippedPaused: "Skipped while paused"
            case .failed: "Failed"
            }
        }

        var isActive: Bool { self == .running || self == .needsYou }
    }

    let id: UUID
    let routine: UUID
    /// The time it was due; for a gap, the first.
    let scheduledAt: Date
    /// A gap's last time, with how many there were.
    var lastScheduledAt: Date?
    var count: Int?
    /// The issue a queue window or pinned issue ran.
    var issue: IssueReference?
    var startedAt: Date?
    var endedAt: Date?
    var outcome: Outcome
    var session: UUID?
    /// US dollars, from the transcript's cost records.
    var cost: Double?
    var pullRequests: [URL] = []
    /// Why it failed or stopped.
    var note: String?

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    /// "Missed 96 times, 18:05 to 09:55" for a gap, else the outcome.
    var summary: String {
        guard let count, count > 1, let last = lastScheduledAt else { return outcome.label }
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(outcome.label) \(count) times, \(scheduledAt.formatted(style)) to \(last.formatted(style))"
    }
}

/// Routines, the agent queue and run history, on this Mac only (R15):
/// Application Support/<bundle ID>/Routines, written through as each
/// changes. Runs are the newest 500.
@Observable
final class RoutineStore {
    private(set) var routines: [Routine] = []
    /// Every org's queue in one list; each org's in its order.
    private(set) var queue: [QueuedIssue] = []
    private(set) var runs: [RoutineRun] = []
    /// Pause All (R14).
    private(set) var isPaused = false
    /// The scheduler's last look, so times due while Gannin was closed are
    /// known as missed on the next launch (R2).
    private(set) var checkedAt: Date?

    static let maxRuns = 500

    private struct State: Codable {
        var isPaused = false
        var checkedAt: Date?
    }

    @ObservationIgnored private let directory: URL

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.gannin", directoryHint: .isDirectory)
            .appending(path: "Routines", directoryHint: .isDirectory)
    }

    init(directory: URL = RoutineStore.defaultDirectory) {
        self.directory = directory
        routines = read([Routine].self, "routines.json") ?? []
        queue = read([QueuedIssue].self, "queue.json") ?? []
        runs = read([RoutineRun].self, "runs.json") ?? []
        let state = read(State.self, "state.json") ?? State()
        isPaused = state.isPaused
        checkedAt = state.checkedAt
    }

    // MARK: Routines

    func routine(_ id: UUID) -> Routine? { routines.first { $0.id == id } }

    /// The org's routines, queue windows and pinned issues, by name.
    func routines(for org: String) -> [Routine] {
        routines.filter { $0.org == org }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds it, or replaces the one with its ID.
    func save(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        write(routines, "routines.json")
    }

    func update(_ id: UUID, _ change: (inout Routine) -> Void) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[index])
        write(routines, "routines.json")
    }

    /// Removes it and its history, but for runs still going, whose limits
    /// are still watched until they end. Sessions it started stay.
    func remove(_ id: UUID) {
        routines.removeAll { $0.id == id }
        runs.removeAll { $0.routine == id && !$0.outcome.isActive }
        write(routines, "routines.json")
        write(runs, "runs.json")
    }

    /// The issue's pin, if it has one still to come.
    func pin(for issueID: String) -> Routine? {
        routines.first { $0.kind == .pinned && $0.isEnabled && $0.issue?.id == issueID }
    }

    // MARK: The queue

    func queue(for org: String) -> [QueuedIssue] { queue.filter { $0.issue.org == org } }

    func isQueued(_ issueID: String) -> Bool { queue.contains { $0.issue.id == issueID } }

    /// Adds the issue at the end of its org's queue, once; or at its front,
    /// as a queued issue whose start failed goes back.
    func enqueue(_ issue: IssueReference, atFront: Bool = false, now: Date = .now) {
        guard !isQueued(issue.id) else { return }
        let item = QueuedIssue(issue: issue, addedAt: now)
        if atFront { queue.insert(item, at: 0) } else { queue.append(item) }
        write(queue, "queue.json")
    }

    /// Puts the issue at `position` in its org's queue (0 for the front, past
    /// the end for the back), moving it there if it's queued already, as
    /// the scheduling board drops it.
    func insert(_ issue: IssueReference, at position: Int, now: Date = .now) {
        let item = queue.first { $0.issue.id == issue.id } ?? QueuedIssue(issue: issue, addedAt: now)
        queue.removeAll { $0.issue.id == issue.id }
        let mine = queue(for: issue.org)
        let index: Int
        if position < mine.count, let before = queue.firstIndex(of: mine[max(0, position)]) {
            index = before
        } else if let last = mine.last, let after = queue.firstIndex(of: last) {
            index = after + 1
        } else {
            index = queue.endIndex
        }
        queue.insert(item, at: index)
        write(queue, "queue.json")
    }

    func dequeue(_ issueID: String) {
        guard isQueued(issueID) else { return }
        queue.removeAll { $0.issue.id == issueID }
        write(queue, "queue.json")
    }

    /// Reorders the org's queue as a list does (`onMove`), leaving other
    /// orgs' where they are.
    func move(in org: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        var mine = queue(for: org)
        mine.move(fromOffsets: source, toOffset: destination)
        var next = mine.makeIterator()
        queue = queue.map { $0.issue.org == org ? (next.next() ?? $0) : $0 }
        write(queue, "queue.json")
    }

    /// Moves the issue to the front or the back of its org's queue.
    func move(_ issueID: String, toFront: Bool) {
        guard let item = queue.first(where: { $0.issue.id == issueID }) else { return }
        let org = item.issue.org
        guard let from = queue(for: org).firstIndex(of: item) else { return }
        move(in: org, fromOffsets: IndexSet(integer: from), toOffset: toFront ? 0 : queue(for: org).count)
    }

    // MARK: Runs

    func run(_ id: UUID) -> RoutineRun? { runs.first { $0.id == id } }

    /// The routine's runs, newest first.
    func runs(for routine: UUID) -> [RoutineRun] {
        runs.filter { $0.routine == routine }.sorted { $0.scheduledAt > $1.scheduledAt }
    }

    func lastRun(of routine: UUID) -> RoutineRun? { runs(for: routine).first }

    /// Runs going now, everywhere.
    var activeRuns: [RoutineRun] { runs.filter(\.outcome.isActive) }

    func run(forSession session: UUID) -> RoutineRun? {
        runs.last { $0.session == session }
    }

    func record(_ run: RoutineRun) {
        runs.append(run)
        if runs.count > Self.maxRuns {
            // Never drop one still going.
            let finished = runs.indices.filter { !runs[$0].outcome.isActive }
            let excess = runs.count - Self.maxRuns
            let dropped = Set(finished.prefix(excess))
            runs = runs.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }
        write(runs, "runs.json")
    }

    func updateRun(_ id: UUID, _ change: (inout RoutineRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        let before = runs[index]
        change(&runs[index])
        if runs[index] != before { write(runs, "runs.json") }
    }

    /// Times passed without running, as one row for the gap: missed (R2) or
    /// skipped while paused (R14).
    func recordGap(_ times: [Date], routine: UUID, outcome: RoutineRun.Outcome, issue: IssueReference? = nil) {
        guard let first = times.first, let last = times.last else { return }
        record(RoutineRun(
            id: UUID(), routine: routine, scheduledAt: first, lastScheduledAt: times.count > 1 ? last : nil,
            count: times.count, issue: issue, outcome: outcome
        ))
    }

    // MARK: State

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        saveState()
    }

    func checked(at date: Date) {
        checkedAt = date
        saveState()
    }

    private func saveState() {
        write(State(isPaused: isPaused, checkedAt: checkedAt), "state.json")
    }

    // MARK: Disk

    private func read<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: directory.appending(path: name), options: .atomic) }
    }
}
