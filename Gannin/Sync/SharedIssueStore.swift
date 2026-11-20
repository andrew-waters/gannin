import Foundation

struct StoredLabel: Codable, Hashable, Sendable {
    let name: String
    /// Nil when the label came from a fetch that reads names only.
    var color: String?
}

/// What every store that fetches an issue shares, so an issue is kept once.
struct IssueCore: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: Person?
    let createdAt: Date
    let closedAt: Date?
    /// When GitHub last updated it. Nil for an issue carried over from a
    /// cache that never recorded it.
    var updatedAt: Date?
    var assignees: [Person]
    var labels: [StoredLabel]

    /// The newer people, each keeping a name or avatar only the older list has.
    private static func merged(_ newer: [Person], _ older: [Person]) -> [Person] {
        newer.map { person in
            guard let held = older.first(where: { $0.login == person.login }) else { return person }
            return Person(login: person.login, name: person.name ?? held.name, avatarUrl: person.avatarUrl ?? held.avatarUrl)
        }
    }

    private static func merged(_ newer: Person?, _ older: Person?) -> Person? {
        guard let newer, let older, newer.login == older.login else { return newer ?? older }
        return Person(login: newer.login, name: newer.name ?? older.name, avatarUrl: newer.avatarUrl ?? older.avatarUrl)
    }

    private static func merged(_ newer: [StoredLabel], _ older: [StoredLabel]) -> [StoredLabel] {
        newer.map { label in
            StoredLabel(name: label.name, color: label.color ?? older.first { $0.name == label.name }?.color)
        }
    }

    /// This issue's fields with `incoming`'s laid over them. When the held
    /// `updatedAt` is newer than the incoming one, the held fields win.
    func merged(with incoming: IssueCore) -> IssueCore {
        let incomingIsStale = updatedAt.map { held in incoming.updatedAt.map { held > $0 } ?? true } ?? false
        let (newer, older) = incomingIsStale ? (self, incoming) : (incoming, self)
        return IssueCore(
            id: id, number: newer.number, title: newer.title, url: newer.url, repo: newer.repo,
            author: Self.merged(newer.author, older.author), createdAt: newer.createdAt, closedAt: newer.closedAt,
            updatedAt: newer.updatedAt ?? older.updatedAt,
            assignees: Self.merged(newer.assignees, older.assignees), labels: Self.merged(newer.labels, older.labels)
        )
    }
}

/// What only the workload fetch reads, kept beside the core.
struct WorkloadIssueExtras: Codable, Hashable, Sendable {
    /// The issue's `updatedAt` when this was fetched (see `HistoryIssueExtras`).
    var updatedAt: Date?
    let linkedPullRequests: [LinkedItem]
}

/// What only the issue history fetch reads, kept beside the core.
struct HistoryIssueExtras: Codable, Hashable, Sendable {
    /// The issue's `updatedAt` when this was fetched. The core's is the newest
    /// any store has seen, so it can't say whether these are current.
    var updatedAt: Date?
    let issueType: String?
    let milestone: String?
    let parentID: String?
    let stateReason: String?
    var statusChanges: [IssueStatusChange]
    let assignedAt: [Date]
    let reopenedAt: [Date]
    let subIssuesAddedAt: [Date]
    let linkedPullRequests: [IssueLinkedPullRequest]
    let mentionedInPullRequests: [IssueLinkedPullRequest]?
    var projectFields: [IssueProjectFields]
}

/// What only the work log fetch reads, kept beside the core.
struct WorkLogIssueExtras: Codable, Hashable, Sendable {
    /// The issue's `updatedAt` when this was fetched (see `HistoryIssueExtras`).
    /// Nil on an issue carried over from an old cache, which is fetched once
    /// when the change feed next reports it changed.
    var updatedAt: Date?
    /// The last comments on it (up to 30), oldest first.
    let comments: [WorkLogIssueComment]
}

struct StoredIssue: Codable, Hashable, Identifiable, Sendable {
    /// The part of a stored issue one store owns.
    enum Slot { case workload, history, workLog }

    var core: IssueCore
    /// Nil until a workload refresh has fetched the issue.
    var workload: WorkloadIssueExtras?
    /// Nil until an issue history sync has fetched the issue.
    var history: HistoryIssueExtras?
    /// Nil until a work log sync has fetched the issue.
    var workLog: WorkLogIssueExtras?

    var id: String { core.id }
}

/// Every issue the app has fetched, per org and keyed by node ID, in one file
/// per org. The workload and the issue history write what they fetched
/// through `merge` and read what's held, rather than each keeping a copy.
final class SharedIssueStore {
    static let shared = SharedIssueStore()
    /// Bumped when the stored shape changes, so older files are dropped.
    nonisolated static let currentFormat = 1

    private nonisolated struct File: Codable, Sendable {
        var formatVersion: Int
        var issues: [String: StoredIssue]
    }

    private let cache: OrgJSONCache
    private let writer: AsyncFileWriter
    /// Set only from a read of the org's file, or by a merge that began from
    /// one, never from a placeholder: a store that held an empty copy and then
    /// saved would overwrite the file with less than it held.
    private var loaded: [String: [String: StoredIssue]] = [:]
    /// Bumped by `clear()`, so a `prepare` that began before it can't bring
    /// back what was cleared.
    private var epoch = 0
    /// Saves waiting for a burst of edits to end, by org.
    private var delayedSaves: [String: SaveCoalescer] = [:]

    init(folder: String = "StoredIssues") {
        cache = OrgJSONCache(folder: folder)
        writer = AsyncFileWriter(cache: cache)
    }

    var cacheDirectory: URL { cache.directory }

    func issues(org: String) -> [String: StoredIssue] {
        load(org)
    }

    /// Adds or updates issues. An issue held at a newer `updatedAt` than the
    /// one given keeps its core; a store's part is replaced only by that
    /// store's part.
    func merge(_ incoming: [StoredIssue], org: String) {
        var held = load(org)
        var changed = false
        for issue in incoming {
            var next = issue
            if let existing = held[issue.id] {
                next = existing.merged(with: issue)
                guard next != existing else { continue }
            }
            held[issue.id] = next
            changed = true
        }
        guard changed else { return }
        loaded[org] = held
        save(org)
    }

    /// Adds issues carried over from an old cache, which have no `updatedAt`,
    /// assignees, labels or `closedAt` of their own. A held issue keeps its
    /// core, since the incoming one could empty its lists when the held core
    /// has no `updatedAt` either; only the incoming work log part is laid over it.
    func mergeCarriedOver(_ incoming: [StoredIssue], org: String) {
        var held = load(org)
        var changed = false
        for issue in incoming {
            var next = issue
            if let existing = held[issue.id] {
                var workLogOnly = existing
                workLogOnly.workLog = issue.workLog
                next = existing.merged(with: workLogOnly)
                guard next != existing else { continue }
            }
            held[issue.id] = next
            changed = true
        }
        guard changed else { return }
        loaded[org] = held
        save(org)
    }

    /// Removes one store's part from the issues it no longer needs, and any
    /// issue left with nothing from a store.
    func prune(_ slot: StoredIssue.Slot, org: String, keeping ids: Set<String>) {
        var held = load(org)
        var changed = false
        for (id, var issue) in held where !ids.contains(id) && issue.has(slot) {
            issue.remove(slot)
            held[id] = issue.isEmpty ? nil : issue
            changed = true
        }
        guard changed else { return }
        loaded[org] = held
        save(org)
    }

    /// Changes a held issue from an edit made in the app, so it shows before
    /// the next fetch. The edit is the person's, not a fetch, so it isn't
    /// weighed against the held `updatedAt`. Saves once a burst of edits ends.
    func update(_ id: String, org: String, _ change: (inout StoredIssue) -> Void) {
        var held = load(org)
        guard var issue = held[id] else { return }
        let before = issue
        change(&issue)
        guard issue != before else { return }
        held[id] = issue
        loaded[org] = held
        saveSoon(org)
    }

    /// Hands any save still waiting to the writer and blocks until it has
    /// written everything handed over; at quit, where nothing can await.
    func flush() {
        delayedSaves.values.forEach { $0.flush() }
        writer.flush()
    }

    /// Reads `org`'s file away from the main actor, so the first use of its
    /// issues doesn't decode it there. Does nothing once the org is held, and
    /// drops what it read if the org was loaded meanwhile or the store was
    /// cleared.
    func prepare(_ org: String) async {
        guard loaded[org] == nil else { return }
        // A clear still removing the folder leaves nothing to read.
        if writer.isResetting {
            loaded[org] = [:]
            return
        }
        let started = epoch
        let cache = cache
        let held = await Task.detached { Self.read(cache, org) }.value
        guard epoch == started, loaded[org] == nil else { return }
        loaded[org] = held
    }

    func clear() {
        epoch += 1
        loaded = [:]
        delayedSaves.values.forEach { $0.cancel() }
        writer.reset()
    }

    /// Removes what one store fetched, in every org, and any issue left with
    /// nothing from a store. The other store's part stays.
    func clear(_ slot: StoredIssue.Slot) {
        // Orgs held but not yet written have no file to list.
        for org in Set(cache.orgs()).union(loaded.keys) {
            var held = load(org)
            var changed = false
            for (id, var issue) in held where issue.has(slot) {
                issue.remove(slot)
                held[id] = issue.isEmpty ? nil : issue
                changed = true
            }
            guard changed else { continue }
            loaded[org] = held
            save(org)
        }
    }

    /// Reads the file here if `prepare` hasn't, for callers that can't wait.
    /// The sync entry points of the issue history, work log and workload
    /// stores call `prepare` first; a reader with no async entry still
    /// decodes on the main actor if it comes first.
    private func load(_ org: String) -> [String: StoredIssue] {
        if let held = loaded[org] { return held }
        let held = writer.isResetting ? [:] : Self.read(cache, org)
        loaded[org] = held
        return held
    }

    private nonisolated static func read(_ cache: OrgJSONCache, _ org: String) -> [String: StoredIssue] {
        let file = cache.load(File.self, org: org)
        return file?.formatVersion == currentFormat ? file?.issues ?? [:] : [:]
    }

    private func save(_ org: String) {
        writer.save(File(formatVersion: Self.currentFormat, issues: loaded[org] ?? [:]), org: org)
    }

    private func saveSoon(_ org: String) {
        let saver = delayedSaves[org] ?? SaveCoalescer { [weak self] in self?.save(org) }
        delayedSaves[org] = saver
        saver.request()
    }
}

extension StoredIssue {
    mutating func remove(_ slot: Slot) {
        switch slot {
        case .workload: workload = nil
        case .history: history = nil
        case .workLog: workLog = nil
        }
    }

    func has(_ slot: Slot) -> Bool {
        switch slot {
        case .workload: workload != nil
        case .history: history != nil
        case .workLog: workLog != nil
        }
    }

    /// Whether no store has a part of it.
    var isEmpty: Bool { workload == nil && history == nil && workLog == nil }

    /// This issue with `incoming` laid over it: core field by field, and each
    /// store's part replaced only by a part fetched at least as recently.
    func merged(with incoming: StoredIssue) -> StoredIssue {
        var next = self
        next.core = core.merged(with: incoming.core)
        next.workload = Self.newer(workload, incoming.workload) { $0.updatedAt }
        next.history = Self.newer(history, incoming.history) { $0.updatedAt }
        next.workLog = Self.newer(workLog, incoming.workLog) { $0.updatedAt }
        return next
    }

    /// The incoming part, unless the held one was fetched at a newer `updatedAt`
    /// or the incoming one has none (carried over from an old cache).
    private static func newer<Extras>(_ held: Extras?, _ incoming: Extras?, stamp: (Extras) -> Date?) -> Extras? {
        guard let held, let incoming else { return incoming ?? held }
        if let heldAt = stamp(held), stamp(incoming).map({ heldAt > $0 }) ?? true { return held }
        return incoming
    }

    /// An issue as the workload fetch has it.
    init(workload issue: Issue) {
        core = IssueCore(
            id: issue.id, number: issue.number, title: issue.title, url: issue.url, repo: issue.repo, author: issue.author,
            createdAt: issue.createdAt, closedAt: issue.closedAt, updatedAt: issue.updatedAt,
            assignees: issue.assignees, labels: issue.labels.map { StoredLabel(name: $0.name, color: $0.color) }
        )
        workload = WorkloadIssueExtras(updatedAt: issue.updatedAt, linkedPullRequests: issue.linkedPullRequests)
    }

    /// Nil until a workload refresh has fetched it, or once it's closed.
    var workloadIssue: Issue? {
        guard let workload, core.closedAt == nil else { return nil }
        return Issue(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo, author: core.author,
            state: "OPEN", createdAt: core.createdAt, updatedAt: workload.updatedAt ?? core.updatedAt ?? core.createdAt,
            closedAt: nil, assignees: core.assignees,
            labels: core.labels.map { IssueLabel(name: $0.name, color: $0.color ?? Self.unknownLabelColor) },
            linkedPullRequests: workload.linkedPullRequests
        )
    }

    /// GitHub's grey, for a label only a names-only fetch has seen.
    static let unknownLabelColor = "ededed"

    /// The status changes and board field values `record` has after a local
    /// edit. Everything else in the record may be older than what the core
    /// holds from a newer workload fetch, so none of it is written back.
    mutating func applyHistoryEdits(of record: IssueRecord) {
        history?.statusChanges = record.statusChanges
        history?.projectFields = record.projectFields
    }

    /// The labels a label edit left on the issue; each keeps the colour
    /// already held for its name.
    mutating func setLabels(_ names: [String]) {
        core.labels = names.map { name in
            StoredLabel(name: name, color: core.labels.first { $0.name == name }?.color)
        }
    }

    /// The assignees an assignee edit left on the issue.
    mutating func setAssignees(_ people: [Person]) {
        core.assignees = people
    }

    /// An issue as the work log fetch has it. A log carried over from before
    /// issues were shared has no `updatedAt`, so its core never outranks one
    /// a fetch saved.
    init(workLog issue: WorkLogIssue) {
        core = IssueCore(
            id: issue.id, number: issue.number, title: issue.title, url: issue.url, repo: issue.repo,
            author: issue.author.map { Person(login: $0, name: nil, avatarUrl: nil) },
            createdAt: issue.createdAt, closedAt: issue.closedAt, updatedAt: issue.updatedAt,
            assignees: (issue.assignees ?? []).map { Person(login: $0, name: nil, avatarUrl: nil) },
            labels: (issue.labels ?? []).map { StoredLabel(name: $0, color: nil) }
        )
        workLog = WorkLogIssueExtras(updatedAt: issue.updatedAt, comments: issue.comments)
    }

    /// Nil until a work log sync has fetched it.
    var workLogIssue: WorkLogIssue? {
        guard let workLog else { return nil }
        return WorkLogIssue(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo,
            author: core.author?.login, createdAt: core.createdAt, comments: workLog.comments,
            closedAt: core.closedAt, updatedAt: workLog.updatedAt,
            assignees: core.assignees.map(\.login), labels: core.labels.map(\.name)
        )
    }

    /// An issue as the issue history fetch has it.
    init(history record: IssueRecord) {
        core = IssueCore(
            id: record.id, number: record.number, title: record.title, url: record.url, repo: record.repo,
            author: record.author.map { Person(login: $0, name: nil, avatarUrl: nil) },
            createdAt: record.createdAt, closedAt: record.closedAt, updatedAt: record.updatedAt,
            assignees: record.assignees.map { Person(login: $0, name: nil, avatarUrl: nil) },
            labels: record.labels.map { StoredLabel(name: $0, color: nil) }
        )
        history = HistoryIssueExtras(
            updatedAt: record.updatedAt, issueType: record.issueType, milestone: record.milestone, parentID: record.parentID,
            stateReason: record.stateReason, statusChanges: record.statusChanges, assignedAt: record.assignedAt,
            reopenedAt: record.reopenedAt, subIssuesAddedAt: record.subIssuesAddedAt,
            linkedPullRequests: record.linkedPullRequests, mentionedInPullRequests: record.mentionedInPullRequests,
            projectFields: record.projectFields
        )
    }

    /// Nil until an issue history sync has fetched it.
    var issueRecord: IssueRecord? {
        guard let history else { return nil }
        return IssueRecord(
            id: core.id, number: core.number, title: core.title, url: core.url, repo: core.repo,
            author: core.author?.login, assignees: core.assignees.map(\.login), labels: core.labels.map(\.name),
            issueType: history.issueType, milestone: history.milestone, parentID: history.parentID,
            createdAt: core.createdAt, closedAt: core.closedAt, stateReason: history.stateReason,
            statusChanges: history.statusChanges, assignedAt: history.assignedAt, reopenedAt: history.reopenedAt,
            subIssuesAddedAt: history.subIssuesAddedAt, linkedPullRequests: history.linkedPullRequests,
            mentionedInPullRequests: history.mentionedInPullRequests, projectFields: history.projectFields,
            updatedAt: history.updatedAt
        )
    }
}
