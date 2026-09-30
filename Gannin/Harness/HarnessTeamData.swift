import Foundation
import Observation

/// Where the team's data sits in the harness: JSON under `.gannin/`, one
/// concern a file, so commits and conflicts stay small.
enum TeamFile {
    static let views = ".gannin/views.json"
    static let investments = ".gannin/investments.json"
    static let workflow = ".gannin/workflow.json"
    static let workingWeek = ".gannin/working-week.json"
    static let leave = ".gannin/leave.json"
    static let exclusions = ".gannin/exclusions.json"
    static let peoplePrefix = ".gannin/people/"

    static func person(_ login: String) -> String { "\(peoplePrefix)\(login).json" }

    static func login(_ path: String) -> String? {
        guard path.hasPrefix(peoplePrefix), path.hasSuffix(".json") else { return nil }
        return String(path.dropFirst(peoplePrefix.count).dropLast(5))
    }

    /// What a file holds, for commit messages and the review.
    static func name(_ path: String) -> String {
        switch path {
        case views: "views"
        case investments: "investment categories"
        case workflow: "issue workflow"
        case workingWeek: "working week"
        case leave: "leave policy"
        case exclusions: "repos and people left out, and repos without review"
        default: login(path).map { "dates for \($0)" } ?? path
        }
    }
}

/// Repos and people left out of the workload and stats, as the team keeps
/// them: sorted lists, so the file only changes when they do.
struct TeamExclusions: Codable, Hashable {
    var repos: [String]
    var people: [String]
    /// Bot-looking logins counted anyway.
    var includedPeople: [String]
    /// Repos whose PRs don't need a review.
    var reposWithoutReview: [String]?
}

/// The team's data as the harness has it (with what's waiting to be
/// committed on top). A concern whose file is missing is the default.
struct HarnessTeamData {
    var views: [FieldView]?
    var investments: InvestmentConfig?
    var workflow: IssueWorkflow?
    var workWeek: WorkWeek?
    var leave: LeavePolicy?
    var exclusions: TeamExclusions?
    var people: [String: PersonDates] = [:]

    init(files: [String: String]) {
        views = files[TeamFile.views].flatMap { TeamCoding.decode([FieldView].self, $0) }
        investments = files[TeamFile.investments].flatMap { TeamCoding.decode(InvestmentConfig.self, $0) }
        workflow = files[TeamFile.workflow].flatMap { TeamCoding.decode(IssueWorkflow.self, $0) }
        workWeek = files[TeamFile.workingWeek].flatMap { TeamCoding.decode(WorkWeek.self, $0) }
        leave = files[TeamFile.leave].flatMap { TeamCoding.decode(LeavePolicy.self, $0) }
        exclusions = files[TeamFile.exclusions].flatMap { TeamCoding.decode(TeamExclusions.self, $0) }
        for (path, text) in files {
            if let login = TeamFile.login(path), let dates = TeamCoding.decode(PersonDates.self, text) {
                people[login] = dates
            }
        }
    }

    /// The org's settings with the team's parts taken from here; the rest
    /// (which harness, for one) stays the user's own.
    func applied(to config: OrgConfig) -> OrgConfig {
        var config = config
        config.fieldViews = views ?? []
        config.investments = investments
        config.issueWorkflow = workflow
        config.workWeek = workWeek
        config.leave = leave
        config.excludedRepos = Set(exclusions?.repos ?? [])
        config.excludedAuthors = Set(exclusions?.people ?? [])
        config.includedAuthors = Set(exclusions?.includedPeople ?? [])
        config.reposWithoutReview = Set(exclusions?.reposWithoutReview ?? [])
        return config
    }

    /// The files that differ between two versions of the settings: new
    /// text, or nil to remove one and go back to the default.
    static func changedFiles(from before: OrgConfig, to after: OrgConfig) -> [String: String?] {
        var files: [String: String?] = [:]
        if before.fieldViews != after.fieldViews {
            files[TeamFile.views] = after.fieldViews.isEmpty ? nil : TeamCoding.encode(after.fieldViews)
        }
        if before.investments != after.investments { files[TeamFile.investments] = after.investments.flatMap(TeamCoding.encode) }
        if before.issueWorkflow != after.issueWorkflow { files[TeamFile.workflow] = after.issueWorkflow.flatMap(TeamCoding.encode) }
        if before.workWeek != after.workWeek { files[TeamFile.workingWeek] = after.workWeek.flatMap(TeamCoding.encode) }
        if before.leave != after.leave { files[TeamFile.leave] = after.leave.flatMap(TeamCoding.encode) }
        if before.excludedRepos != after.excludedRepos || before.excludedAuthors != after.excludedAuthors || before.includedAuthors != after.includedAuthors
            || before.reposWithoutReview != after.reposWithoutReview {
            files[TeamFile.exclusions] = exclusionsFile(after)
        }
        return files
    }

    /// Everything, for moving an org's data into its harness.
    static func allFiles(config: OrgConfig, people: [String: PersonDates]) -> [String: String] {
        var files: [String: String?] = [
            TeamFile.views: config.fieldViews.isEmpty ? nil : TeamCoding.encode(config.fieldViews),
            TeamFile.investments: TeamCoding.encode(config.investmentConfig),
            TeamFile.workflow: TeamCoding.encode(config.workflow),
            TeamFile.workingWeek: TeamCoding.encode(config.week),
            TeamFile.leave: TeamCoding.encode(config.leavePolicy),
            TeamFile.exclusions: exclusionsFile(config),
        ]
        for (login, dates) in people where !dates.isEmpty {
            files[TeamFile.person(login)] = TeamCoding.encode(dates)
        }
        return files.compactMapValues { $0 }
    }

    static func personFile(_ dates: PersonDates) -> String? {
        dates.isEmpty ? nil : TeamCoding.encode(dates)
    }

    private static func exclusionsFile(_ config: OrgConfig) -> String? {
        let exclusions = TeamExclusions(
            repos: config.excludedRepos.sorted(), people: config.excludedAuthors.sorted(), includedPeople: config.includedAuthors.sorted(),
            reposWithoutReview: config.reposWithoutReview.isEmpty ? nil : config.reposWithoutReview.sorted()
        )
        return exclusions.repos.isEmpty && exclusions.people.isEmpty && exclusions.includedPeople.isEmpty && exclusions.reposWithoutReview == nil
            ? nil : TeamCoding.encode(exclusions)
    }
}

// MARK: - Coding

/// The harness's JSON: keys sorted and pretty printed so diffs read well,
/// and calendar days (dates at local midnight, like time off) as
/// `2026-10-03`, so a teammate in another time zone reads the same day.
enum TeamCoding {
    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return serialize(object)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? decoder.decode(type, from: Data(text.utf8))
    }

    static func serialize(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// A three-way merge of JSON texts: what we changed from `base` applied
    /// to `theirs`, the newer copy. Objects merge key by key, lists of
    /// objects with an `id` (time off, views, categories) item by item, and
    /// where both changed the same value, ours wins. Nil is no file.
    static func merge(base: String?, ours: String?, theirs: String?) -> String? {
        func parse(_ text: String?) -> Any? {
            text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        }
        guard let merged = merge(base: parse(base), ours: parse(ours), theirs: parse(theirs)) else { return nil }
        return serialize(merged)
    }

    static func merge(base: Any?, ours: Any?, theirs: Any?) -> Any? {
        if same(ours, base) { return theirs }
        if same(theirs, base) || same(ours, theirs) { return ours }
        if let ours = ours as? [String: Any], let theirs = theirs as? [String: Any] {
            let base = base as? [String: Any] ?? [:]
            var merged: [String: Any] = [:]
            for key in Set(ours.keys).union(theirs.keys).union(base.keys) {
                if let value = merge(base: base[key], ours: ours[key], theirs: theirs[key]) { merged[key] = value }
            }
            return merged
        }
        if let ours = (ours as? [Any]).flatMap(identified), let theirs = (theirs as? [Any]).flatMap(identified) {
            let base = Dictionary(((base as? [Any]).flatMap(identified) ?? []), uniquingKeysWith: { first, _ in first })
            let ourItems = Dictionary(ours, uniquingKeysWith: { first, _ in first })
            let theirItems = Dictionary(theirs, uniquingKeysWith: { first, _ in first })
            var seen: Set<String> = []
            var merged: [Any] = []
            // Their order, then what we added.
            for (id, _) in theirs + ours where seen.insert(id).inserted {
                if let value = merge(base: base[id], ours: ourItems[id], theirs: theirItems[id]) { merged.append(value) }
            }
            return merged
        }
        return ours
    }

    /// A list's items by their `id`, if every one is an object with one.
    private static func identified(_ list: [Any]) -> [(String, Any)]? {
        var items: [(String, Any)] = []
        for item in list {
            guard let object = item as? [String: Any], let id = object["id"] as? String else { return nil }
            items.append((id, item))
        }
        return items
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b as AnyObject)
        default: false
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let calendar = Calendar.current
            if calendar.startOfDay(for: date) == date {
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                try container.encode(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            } else {
                try container.encode(date.formatted(.iso8601))
            }
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if text.count == 10, parts.count == 3,
               let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                return day
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(text)")
        }
        return decoder
    }()
}

// MARK: - The store

/// The team's data for orgs that keep it in their harness: read from the
/// harness index, with edits applied at once and held as pending changes
/// until they're reviewed and committed (one commit for however many edits,
/// so a run of tweaks isn't a run of commits). Pending changes are kept on
/// disk until then.
///
/// An org keeps its data in the harness once `.gannin/` has any of it (after
/// Move to Harness); until then `OrgConfigStore` and `PeopleDatesStore` keep
/// using what's synced through iCloud.
@Observable
final class HarnessTeamStore {
    struct Pending: Codable, Equatable {
        /// The file as the harness had it when first changed; nil if it
        /// wasn't there. What a merge takes our change from.
        var base: String?
        /// The file now; nil to remove it.
        var ours: String?
    }

    /// Committed, and shown until the index has caught up with the commit.
    private struct Written {
        var files: [String: String?]
        /// Index commits from before it: while the index is at one of these
        /// it doesn't have the change yet.
        var before: Set<String>
    }

    private(set) var pending: [String: [String: Pending]] = [:]
    private(set) var committing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private var written: [String: Written] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var cache: [String: (key: String, data: HarnessTeamData)] = [:]

    let harness: HarnessStore
    /// The org's harness, from its own settings (not the team's, which come
    /// from here).
    @ObservationIgnored var setup: (String) -> HarnessConfig? = { _ in nil }

    init(harness: HarnessStore) {
        self.harness = harness
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let changes = try? JSONDecoder().decode([String: Pending].self, from: data) {
                pending[file.deletingPathExtension().lastPathComponent] = changes
            }
        }
    }

    /// The org's team data files as they stand here: the index's, then
    /// what was just committed, then what's pending. Nil when the org keeps
    /// none in its harness.
    private func files(for org: String) -> [String: String]? {
        guard let setup = setup(org), let index = harness.index(for: org, setup) else { return nil }
        var files = Dictionary((index.dataFiles ?? []).map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        if let written = written[org] {
            if written.before.contains(index.commit) {
                for (path, text) in written.files { files[path] = text }
            } else {
                self.written[org] = nil
            }
        }
        for (path, change) in pending[org] ?? [:] { files[path] = change.ours }
        return files.isEmpty ? nil : files
    }

    /// The team's data, when the org keeps it in its harness.
    func data(for org: String) -> HarnessTeamData? {
        guard let setup = setup(org), let index = harness.index(for: org, setup) else { return nil }
        let key = "\(index.commit)|\(index.fetchedAt.timeIntervalSince1970)|\(revision)|\(pending[org]?.count ?? 0)"
        if let cached = cache[org], cached.key == key { return cached.data }
        guard let files = files(for: org) else {
            cache[org] = nil
            return nil
        }
        let data = HarnessTeamData(files: files)
        cache[org] = (key, data)
        return data
    }

    func keepsData(_ org: String) -> Bool { data(for: org) != nil }

    // MARK: Changing

    /// Applies changed files at once, pending until committed. A file
    /// changed back to what the harness has is no longer pending.
    func stage(org: String, _ changes: [String: String?]) {
        guard !changes.isEmpty, let setup = setup(org), let index = harness.index(for: org, setup) else { return }
        var current = Dictionary((index.dataFiles ?? []).map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        if let written = written[org], written.before.contains(index.commit) {
            for (path, text) in written.files { current[path] = text }
        }
        var files = pending[org] ?? [:]
        for (path, text) in changes {
            let base = files[path]?.base ?? current[path]
            files[path] = text == base ? nil : Pending(base: base, ours: text)
        }
        pending[org] = files.isEmpty ? nil : files
        revision += 1
        save(org)
    }

    func discard(org: String) {
        pending[org] = nil
        errors[org] = nil
        revision += 1
        save(org)
    }

    /// Every org's pending changes, as Delete Your Data removes them. What's
    /// committed is the team's, and stays in the harness.
    func discardAll() {
        for org in pending.keys { discard(org: org) }
    }

    /// Commits what's pending in one commit, on top of whatever the harness
    /// has now: a file someone else changed meanwhile gets our change merged
    /// into their copy. Called once the user has confirmed.
    func commit(org: String) async {
        guard let setup = setup(org), let changes = pending[org], !changes.isEmpty, !committing.contains(org) else { return }
        committing.insert(org)
        defer { committing.remove(org) }
        let message = Self.message(Self.notes(changes))
        let before = harness.index(for: org, setup)?.commit
        var head: String?
        var committed: [String: String?] = [:]
        do {
            try await harness.commit(org: org, setup: setup) { commit in
                head = commit
                let paths = Array(changes.keys)
                let theirs = try await self.harness.files(setup: setup, at: commit, paths: paths)
                var files: [String: String?] = [:]
                for (path, change) in changes {
                    let current = theirs[path] ?? nil
                    let merged = current == change.base ? change.ours : TeamCoding.merge(base: change.base, ours: change.ours, theirs: current)
                    if merged != current { files[path] = merged }
                }
                committed = files
                return files.isEmpty ? nil : HarnessChange(message: message, files: files)
            }
            written[org] = Written(files: committed, before: Set([before, head].compactMap { $0 }))
            // Edits made while committing stay pending.
            var remaining = pending[org] ?? [:]
            for (path, change) in changes where remaining[path] == change {
                remaining[path] = nil
            }
            pending[org] = remaining.isEmpty ? nil : remaining
            errors[org] = nil
            revision += 1
            save(org)
        } catch {
            errors[org] = error.localizedDescription
        }
    }

    /// Copies the org's settings and people's dates from iCloud into the
    /// harness in one commit; from then on they're read from there.
    func moveIn(org: String, config: OrgConfig, people: [String: PersonDates]) async throws {
        guard let setup = setup(org) else { return }
        let files = HarnessTeamData.allFiles(config: config, people: people)
        let before = harness.index(for: org, setup)?.commit
        var head: String?
        try await harness.commit(org: org, setup: setup) { commit in
            head = commit
            return HarnessChange(
                message: "Gannin: the team's settings and people's dates\n\nMoved from Gannin into .gannin/, where Gannin reads and commits them from now on.",
                files: files.mapValues { Optional($0) }
            )
        }
        written[org] = Written(files: files.mapValues { Optional($0) }, before: Set([before, head].compactMap { $0 }))
        revision += 1
        // Something to show straight away, while the index catches up.
        pending[org] = pending[org]
    }

    // MARK: Describing

    /// What's pending, a line each: "time off for ian, 3 to 5 Oct".
    static func notes(_ changes: [String: Pending]) -> [String] {
        changes.keys.sorted().flatMap { path -> [String] in
            let change = changes[path]!
            guard let login = TeamFile.login(path) else {
                return [change.ours == nil ? "\(TeamFile.name(path)) back to the default" : TeamFile.name(path)]
            }
            let before = change.base.flatMap { TeamCoding.decode(PersonDates.self, $0) } ?? PersonDates()
            let after = change.ours.flatMap { TeamCoding.decode(PersonDates.self, $0) } ?? PersonDates()
            return personNotes(login, before: before, after: after)
        }
    }

    private static func personNotes(_ login: String, before: PersonDates, after: PersonDates) -> [String] {
        let old = Dictionary(before.absences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.absences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var notes: [String] = []
        for absence in after.absences {
            let what = absence.kind == .sick ? "sick" : "time off"
            if let was = old[absence.id] {
                guard was != absence else { continue }
                if was.isRequested && !absence.isRequested && was.start == absence.start && was.end == absence.end {
                    notes.append("time off approved for \(login), \(range(absence))")
                } else {
                    notes.append("\(what) changed for \(login), \(range(absence))")
                }
            } else {
                notes.append("\(absence.isRequested ? "time off requested" : what) for \(login), \(range(absence))")
            }
        }
        for absence in before.absences where new[absence.id] == nil {
            notes.append("\(absence.kind == .sick ? "sick" : "time off") removed for \(login), \(range(absence))")
        }
        var otherBefore = before
        var otherAfter = after
        otherBefore.absences = []
        otherAfter.absences = []
        if otherBefore != otherAfter { notes.append("dates for \(login)") }
        return notes
    }

    /// `3 to 5 Oct`, `30 Sep to 2 Oct`, `3 Oct`.
    static func range(_ absence: Absence) -> String {
        let calendar = Calendar.current
        let day = Date.FormatStyle().day().month(.abbreviated)
        if calendar.isDate(absence.start, inSameDayAs: absence.end) { return absence.start.formatted(day) }
        let sameMonth = calendar.isDate(absence.start, equalTo: absence.end, toGranularity: .month)
        let first = sameMonth ? absence.start.formatted(.dateTime.day()) : absence.start.formatted(day)
        return "\(first) to \(absence.end.formatted(day))"
    }

    /// `Gannin: time off for ian, 3 to 5 Oct`, with every note in the body
    /// when there's more than one.
    static func message(_ notes: [String]) -> String {
        guard let first = notes.first else { return "Gannin: team data" }
        if notes.count == 1 { return "Gannin: \(first)" }
        let joined = "Gannin: " + notes.joined(separator: "; ")
        let headline = joined.count <= 72 ? joined : "Gannin: \(first), and \(notes.count - 1) more"
        return headline + "\n\n" + notes.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: Disk

    private static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.getgannin", directoryHint: .isDirectory)
            .appending(path: "HarnessPending", directoryHint: .isDirectory)
    }

    private func save(_ org: String) {
        let file = Self.directory.appending(path: "\(org).json")
        guard let changes = pending[org] else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(changes) { try? data.write(to: file, options: .atomic) }
    }
}
