import Foundation
import Observation

/// Where the team's data sits in a harness: JSON under `.gannin/`, one
/// concern a file, so commits and conflicts stay small. Each project's
/// harness has its own project files; the org-wide ones (`isOrgWide`) are
/// read from and committed to the home project's.
enum TeamFile {
    static let views = ".gannin/views.json"
    static let investments = ".gannin/investments.json"
    static let workflow = ".gannin/workflow.json"
    static let workingWeek = ".gannin/working-week.json"
    static let leave = ".gannin/leave.json"
    static let exclusions = ".gannin/exclusions.json"
    static let goals = ".gannin/goals.json"
    static let authoring = ".gannin/authoring.json"
    static let recap = ".gannin/recap.json"
    static let scorecard = ".gannin/scorecard.json"
    /// Every project, when the org's harness held them; only read.
    static let repoProjects = ".gannin/repo-projects.json"
    static let project = ".gannin/project.json"
    static let prioritisation = ".gannin/prioritisation.json"
    static let fieldNotes = ".gannin/field-notes.json"
    static let peoplePrefix = ".gannin/people/"

    /// The org's, in the home harness, rather than each project's.
    static func isOrgWide(_ path: String) -> Bool {
        path.hasPrefix(peoplePrefix) || [views, workingWeek, leave, exclusions, authoring, fieldNotes].contains(path)
    }

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
        case goals: "delivery goals"
        case authoring: "prompts for drafting harness documents"
        case recap: "how often the team recaps"
        case scorecard: "the scorecard"
        case repoProjects: "projects"
        case project: "the project's name and repos"
        case prioritisation: "the committed date field"
        case fieldNotes: "notes from the field"
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

/// Prioritisation's settings, as the team keeps them.
struct TeamPrioritisation: Codable, Hashable {
    /// The board's date field that says an issue's committed to.
    var committedDateField: String
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
    var goals: MetricGoals?
    var authoring: [String: String]?
    var recap: RecapCadence?
    var scorecard: [Measurable]?
    var project: ProjectFile?
    var legacyProjects: [LegacyProject]?
    var prioritisation: TeamPrioritisation?
    var fieldNotes: [FieldNote]?
    var people: [String: PersonDates] = [:]

    init(files: [String: String]) {
        views = files[TeamFile.views].flatMap { TeamCoding.decode([FieldView].self, $0) }
        investments = files[TeamFile.investments].flatMap { TeamCoding.decode(InvestmentConfig.self, $0) }
        workflow = files[TeamFile.workflow].flatMap { TeamCoding.decode(IssueWorkflow.self, $0) }
        workWeek = files[TeamFile.workingWeek].flatMap { TeamCoding.decode(WorkWeek.self, $0) }
        leave = files[TeamFile.leave].flatMap { TeamCoding.decode(LeavePolicy.self, $0) }
        exclusions = files[TeamFile.exclusions].flatMap { TeamCoding.decode(TeamExclusions.self, $0) }
        goals = files[TeamFile.goals].flatMap { TeamCoding.decode(MetricGoals.self, $0) }
        authoring = files[TeamFile.authoring].flatMap { TeamCoding.decode([String: String].self, $0) }
        recap = files[TeamFile.recap].flatMap { TeamCoding.decode(RecapCadence.self, $0) }
        scorecard = files[TeamFile.scorecard].flatMap { TeamCoding.decode([Measurable].self, $0) }
        project = files[TeamFile.project].flatMap { TeamCoding.decode(ProjectFile.self, $0) }
        legacyProjects = files[TeamFile.repoProjects].flatMap { TeamCoding.decode([LegacyProject].self, $0) }
        prioritisation = files[TeamFile.prioritisation].flatMap { TeamCoding.decode(TeamPrioritisation.self, $0) }
        fieldNotes = files[TeamFile.fieldNotes].flatMap { TeamCoding.decode([FieldNote].self, $0) }
        for (path, text) in files {
            if let login = TeamFile.login(path), let dates = TeamCoding.decode(PersonDates.self, text) {
                people[login] = dates
            }
        }
    }

    /// The org-wide settings taken from here, the home harness's; the
    /// rest (which harnesses, for one) stays the user's own.
    func appliedOrgWide(to config: OrgConfig) -> OrgConfig {
        var config = config
        config.fieldViews = views ?? []
        config.workWeek = workWeek
        config.leave = leave
        config.excludedRepos = Set(exclusions?.repos ?? [])
        config.excludedAuthors = Set(exclusions?.people ?? [])
        config.includedAuthors = Set(exclusions?.includedPeople ?? [])
        config.reposWithoutReview = Set(exclusions?.reposWithoutReview ?? [])
        config.authoring = authoring
        return config
    }

    /// A project's own settings taken from here, its harness's.
    func appliedProject(to config: OrgConfig) -> OrgConfig {
        var config = config
        config.investments = investments
        config.issueWorkflow = workflow
        config.goals = goals
        config.recap = recap
        config.scorecard = scorecard
        config.committedDateField = prioritisation?.committedDateField
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
        if before.goals != after.goals { files[TeamFile.goals] = after.goals.flatMap(TeamCoding.encode) }
        if before.authoring != after.authoring { files[TeamFile.authoring] = after.authoring.flatMap(TeamCoding.encode) }
        if before.recap != after.recap { files[TeamFile.recap] = after.recap.flatMap(TeamCoding.encode) }
        if before.scorecard != after.scorecard { files[TeamFile.scorecard] = after.scorecard.flatMap(TeamCoding.encode) }
        if before.leave != after.leave { files[TeamFile.leave] = after.leave.flatMap(TeamCoding.encode) }
        if before.committedDateField != after.committedDateField {
            files[TeamFile.prioritisation] = after.committedDateField.flatMap { TeamCoding.encode(TeamPrioritisation(committedDateField: $0)) }
        }
        if before.excludedRepos != after.excludedRepos || before.excludedAuthors != after.excludedAuthors || before.includedAuthors != after.includedAuthors
            || before.reposWithoutReview != after.reposWithoutReview {
            files[TeamFile.exclusions] = exclusionsFile(after)
        }
        return files
    }

    static func personFile(_ dates: PersonDates) -> String? {
        dates.isEmpty ? nil : TeamCoding.encode(dates)
    }

    static func fieldNotesFile(_ notes: [FieldNote]) -> String? {
        notes.isEmpty ? nil : TeamCoding.encode(notes)
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

/// The team's data for orgs with a harness, per harness: read from its
/// index, with edits applied at once and held as pending changes until
/// they're reviewed and committed (one commit a harness for however many
/// edits, so a run of tweaks isn't a run of commits). Pending changes are
/// kept on disk until then.
///
/// Each project's harness keeps the project's own files and the home
/// project's (the first) the org-wide ones, from the start: a concern with
/// no file is its default. `OrgConfigStore`, `PeopleDatesStore` and
/// `FieldNotesStore` only keep it on this device for an org with no
/// harness.
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

    /// By harness (`key`), then path.
    private(set) var pending: [String: [String: Pending]] = [:]
    /// By org.
    private(set) var committing: Set<String> = []
    /// By org.
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private var written: [String: Written] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var cache: [String: (key: String, data: HarnessTeamData)] = [:]

    let harness: HarnessStore
    /// The org's project harnesses, home first, from the user's own
    /// settings (not the team's, which come from here).
    @ObservationIgnored var harnesses: (String) -> [HarnessConfig] = { _ in [] }

    init(harness: HarnessStore) {
        self.harness = harness
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "~", with: "/")
            if key.contains("@"), let data = try? Data(contentsOf: file), let changes = try? JSONDecoder().decode([String: Pending].self, from: data) {
                pending[key] = changes
            }
        }
    }

    private static func key(_ org: String, _ setup: HarnessConfig) -> String { "\(org)@\(setup.repo)" }

    /// The home harness, where the org-wide data is kept.
    func home(_ org: String) -> HarnessConfig? { harnesses(org).first }

    /// Whether the org's team data is the harnesses': it has one.
    func keepsData(_ org: String) -> Bool { home(org) != nil }

    /// A harness's team data files as they stand here: the index's (none
    /// until it's loaded), then what was just committed, then what's
    /// pending.
    private func files(for key: String, index: HarnessIndex?) -> [String: String] {
        var files = Dictionary((index?.dataFiles ?? []).map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        if let written = written[key] {
            if let commit = index?.commit, !written.before.contains(commit) {
                self.written[key] = nil
            } else {
                for (path, text) in written.files { files[path] = text }
            }
        }
        for (path, change) in pending[key] ?? [:] { files[path] = change.ours }
        return files
    }

    /// The home harness's team data, for an org with a harness.
    func data(for org: String) -> HarnessTeamData? {
        home(org).map { data(for: org, in: $0) }
    }

    /// One harness's team data.
    func data(for org: String, in setup: HarnessConfig) -> HarnessTeamData {
        let key = Self.key(org, setup)
        let index = harness.index(for: org, setup)
        let stamp = "\(index?.commit ?? "")|\(index?.fetchedAt.timeIntervalSince1970 ?? 0)|\(revision)|\(pending[key]?.count ?? 0)"
        if let cached = cache[key], cached.key == stamp { return cached.data }
        let data = HarnessTeamData(files: files(for: key, index: index))
        cache[key] = (stamp, data)
        return data
    }

    // MARK: Changing

    /// Applies changed files at once, pending until committed: org-wide
    /// ones in the home harness, the rest in `project` (home when nil). A
    /// file changed back to what the harness has is no longer pending.
    func stage(org: String, project: HarnessConfig? = nil, _ changes: [String: String?]) {
        guard let home = home(org) else { return }
        let orgWide = changes.filter { TeamFile.isOrgWide($0.key) }
        stage(org: org, in: home, orgWide)
        stage(org: org, in: project ?? home, changes.filter { !TeamFile.isOrgWide($0.key) })
    }

    private func stage(org: String, in setup: HarnessConfig, _ changes: [String: String?]) {
        guard !changes.isEmpty else { return }
        let key = Self.key(org, setup)
        let index = harness.index(for: org, setup)
        var current = Dictionary((index?.dataFiles ?? []).map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        if let written = written[key], index.map({ written.before.contains($0.commit) }) ?? true {
            for (path, text) in written.files { current[path] = text }
        }
        var files = pending[key] ?? [:]
        for (path, text) in changes {
            let base = files[path]?.base ?? current[path]
            files[path] = text == base ? nil : Pending(base: base, ours: text)
        }
        pending[key] = files.isEmpty ? nil : files
        revision += 1
        save(key)
    }

    /// What's pending for the org, a harness at a time, home first. A
    /// harness that's no longer one of its projects is left out.
    func changes(org: String) -> [(setup: HarnessConfig, changes: [String: Pending])] {
        harnesses(org).compactMap { setup in
            pending[Self.key(org, setup)].flatMap { $0.isEmpty ? nil : (setup, $0) }
        }
    }

    func discard(org: String) {
        for key in pending.keys where key.hasPrefix("\(org)@") {
            pending[key] = nil
            save(key)
        }
        errors[org] = nil
        revision += 1
    }

    /// Every org's pending changes, as Delete Your Data removes them. What's
    /// committed is the team's, and stays in the harness.
    func discardAll() {
        for key in pending.keys {
            pending[key] = nil
            save(key)
        }
        errors = [:]
        revision += 1
    }

    /// Commits what's pending, one commit a harness, on top of whatever
    /// each has now: a file someone else changed meanwhile gets our change
    /// merged into their copy. Called once the user has confirmed.
    func commit(org: String) async {
        guard !committing.contains(org) else { return }
        committing.insert(org)
        defer { committing.remove(org) }
        errors[org] = nil
        for (setup, changes) in changes(org: org) {
            do {
                try await commit(org: org, setup: setup, changes: changes)
            } catch {
                errors[org] = "\(setup.repo): \(error.localizedDescription)"
                return
            }
        }
    }

    private func commit(org: String, setup: HarnessConfig, changes: [String: Pending]) async throws {
        let key = Self.key(org, setup)
        let message = Self.message(Self.notes(changes))
        let before = harness.index(for: org, setup)?.commit
        var head: String?
        var committed: [String: String?] = [:]
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
        written[key] = Written(files: committed, before: Set([before, head].compactMap { $0 }))
        // Edits made while committing stay pending.
        var remaining = pending[key] ?? [:]
        for (path, change) in changes where remaining[path] == change {
            remaining[path] = nil
        }
        pending[key] = remaining.isEmpty ? nil : remaining
        revision += 1
        save(key)
    }

    /// Copies the org-wide data as committed into another project's
    /// harness, in one commit, for making it home. The caller then makes
    /// it home; the old copy stays where it was.
    func moveOrgWideData(org: String, to target: HarnessConfig) async throws {
        guard let current = home(org), current.repo != target.repo,
              let files = harness.index(for: org, current)?.dataFiles?.filter({ TeamFile.isOrgWide($0.path) }), !files.isEmpty else { return }
        let texts = Dictionary(files.map { ($0.path, Optional($0.text)) }, uniquingKeysWith: { first, _ in first })
        let before = harness.index(for: org, target)?.commit
        var head: String?
        try await harness.commit(org: org, setup: target) { commit in
            head = commit
            return HarnessChange(
                message: "Gannin: the org's settings and people's dates\n\nMoved from \(current.repo), where they were kept before.",
                files: texts
            )
        }
        written[Self.key(org, target)] = Written(files: texts, before: Set([before, head].compactMap { $0 }))
        revision += 1
    }

    // MARK: Describing

    /// What's pending, a line each: "time off for alex, 3 to 5 Oct".
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

    /// `Gannin: time off for alex, 3 to 5 Oct`, with every note in the body
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
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.gannin", directoryHint: .isDirectory)
            .appending(path: "HarnessPending", directoryHint: .isDirectory)
    }

    private func save(_ key: String) {
        let file = Self.directory.appending(path: "\(key.replacingOccurrences(of: "/", with: "~")).json")
        guard let changes = pending[key] else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(changes) { try? data.write(to: file, options: .atomic) }
    }
}
