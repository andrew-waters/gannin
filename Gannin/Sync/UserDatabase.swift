import CoreData
import Foundation
import Observation
import SwiftData

// What you enter in Gannin, kept in SwiftData on this device. What the team
// shares (settings, people's dates) belongs in the org's harness, where
// everyone reads the same copy; what's here is your own, or the team's for
// an org that hasn't moved it there. GitHub caches are not here either.
//
// The store once synced through CloudKit, which allows no unique
// constraints and needs every property optional or defaulted, so records
// are keyed by plain fields (org, login, a UUID) with an `updatedAt`, and
// duplicates are merged when the data is loaded: newest wins, time off
// merges by its ID.

@Model
final class PersonRecord {
    var org: String = ""
    var login: String = ""
    var updatedAt: Date = Date.distantPast
    /// Their `PersonDates` less the time off, as JSON: dates, allowance,
    /// carry-over, holiday region, working pattern and time zone.
    var details: Data?
    @Relationship(deleteRule: .cascade, inverse: \AbsenceRecord.person)
    var absences: [AbsenceRecord]? = []

    init(org: String, login: String) {
        self.org = org
        self.login = login
    }
}

/// One stretch of time off, a record of its own so two devices adding time
/// off never touch the same record.
@Model
final class AbsenceRecord {
    var id: UUID = UUID()
    var kind: String = Absence.Kind.holiday.rawValue
    var start: Date = Date.distantPast
    var end: Date = Date.distantPast
    var half: String?
    var note: String = ""
    /// `requested` while waiting to be approved; nil once booked.
    var approval: String?
    var updatedAt: Date = Date.distantPast
    var person: PersonRecord?

    init(_ absence: Absence) {
        id = absence.id
        apply(absence)
    }

    func apply(_ absence: Absence) {
        kind = absence.kind.rawValue
        start = absence.start
        end = absence.end
        half = absence.half?.rawValue
        note = absence.note
        approval = absence.approval?.rawValue
        updatedAt = .now
    }

    var absence: Absence {
        Absence(
            id: id, kind: Absence.Kind(rawValue: kind) ?? .holiday, start: start, end: end, note: note,
            half: half.flatMap(Absence.HalfDay.init(rawValue:)), approval: approval.flatMap(Absence.Approval.init(rawValue:))
        )
    }
}

/// An org's settings, as its `OrgConfig` JSON: edited as a whole, so one
/// record is enough.
@Model
final class OrgConfigRecord {
    var org: String = ""
    var updatedAt: Date = Date.distantPast
    var config: Data?

    init(org: String) {
        self.org = org
    }
}

@Model
final class HiddenRecord {
    /// A PR or issue node ID, or an old `person:` key.
    var key: String = ""
    var createdAt: Date = Date.now

    init(key: String) {
        self.key = key
    }
}

@Model
final class StarRecord {
    var org: String = ""
    var createdAt: Date = Date.now

    init(org: String) {
        self.org = org
    }
}

/// The SwiftData store behind the people, org config, hidden and star
/// stores. They keep their data in memory as before and write through here;
/// when the store changes underneath them, or the app comes to the front,
/// `onRemoteChange` tells them to load again.
@Observable
final class UserDatabase {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    @ObservationIgnored private var listeners: [() -> Void] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        let schema = Schema([PersonRecord.self, AbsenceRecord.self, OrgConfigRecord.self, HiddenRecord.self, StarRecord.self])
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        container = (try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)))
            ?? (try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        migrateFromUserDefaults()
        observeRemoteChanges()
    }

    /// The same file it was while it synced through CloudKit, so nothing
    /// moves.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "UserData", directoryHint: .isDirectory).appending(path: "Gannin.store")
    }

    /// Bytes on disk, the store and its journal files together.
    var storedBytes: Int {
        let directory = Self.storeURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
    }

    // MARK: Changes from other devices

    /// Called on the main actor after other devices' changes are imported
    /// (and when the app comes to the front), so stores can load again.
    func onRemoteChange(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    private func observeRemoteChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
        let active = NSNotification.Name("NSApplicationDidBecomeActiveNotification")
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        })
    }

    /// Imports come in bursts; load once they've settled.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            listeners.forEach { $0() }
        }
    }

    private func save() {
        try? context.save()
    }

    // MARK: People

    func loadPeople() -> [String: [String: PersonDates]] {
        let records = (try? context.fetch(FetchDescriptor<PersonRecord>())) ?? []
        var people: [String: [String: PersonDates]] = [:]
        for group in Dictionary(grouping: records, by: { "\($0.org)\u{1}\($0.login)" }).values {
            let record = merge(group)
            var dates = record.details.flatMap { try? JSONDecoder().decode(PersonDates.self, from: $0) } ?? PersonDates()
            dates.absences = (record.absences ?? []).map(\.absence).sorted { $0.start < $1.start }
            if !dates.isEmpty { people[record.org, default: [:]][record.login] = dates }
        }
        return people
    }

    /// Two devices made the same person: keep the newest details and every
    /// stretch of time off (newest copy of each), and delete the rest.
    private func merge(_ group: [PersonRecord]) -> PersonRecord {
        guard group.count > 1 else { return group[0] }
        let sorted = group.sorted { $0.updatedAt > $1.updatedAt }
        let keep = sorted[0]
        for copies in Dictionary(grouping: sorted.flatMap { $0.absences ?? [] }, by: \.id).values {
            guard let newest = copies.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            // Moved before the duplicates go, so the cascade doesn't take it.
            newest.person = keep
            for copy in copies where copy !== newest { context.delete(copy) }
        }
        sorted.dropFirst().forEach(context.delete)
        save()
        return keep
    }

    /// Writes one person's dates; nil or empty removes them.
    func savePerson(org: String, login: String, _ dates: PersonDates?) {
        let records = (try? context.fetch(FetchDescriptor<PersonRecord>(predicate: #Predicate { $0.org == org && $0.login == login }))) ?? []
        guard let dates, !dates.isEmpty else {
            records.forEach(context.delete)
            save()
            return
        }
        let record = records.isEmpty ? PersonRecord(org: org, login: login) : merge(records)
        if records.isEmpty { context.insert(record) }
        var details = dates
        details.absences = []
        record.details = try? JSONEncoder().encode(details)
        record.updatedAt = .now

        var existing = Dictionary((record.absences ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for absence in dates.absences {
            if let stored = existing.removeValue(forKey: absence.id) {
                if stored.absence != absence { stored.apply(absence) }
            } else {
                let stored = AbsenceRecord(absence)
                context.insert(stored)
                stored.person = record
            }
        }
        existing.values.forEach(context.delete)
        save()
    }

    func deleteAllPeople() {
        try? context.delete(model: AbsenceRecord.self)
        try? context.delete(model: PersonRecord.self)
        save()
    }

    // MARK: Org config

    func loadConfigs() -> [String: OrgConfig] {
        let records = (try? context.fetch(FetchDescriptor<OrgConfigRecord>())) ?? []
        var configs: [String: OrgConfig] = [:]
        for group in Dictionary(grouping: records, by: \.org).values {
            let sorted = group.sorted { $0.updatedAt > $1.updatedAt }
            sorted.dropFirst().forEach(context.delete)
            if let data = sorted[0].config, let config = try? JSONDecoder().decode(OrgConfig.self, from: data) {
                configs[sorted[0].org] = config
            }
        }
        if records.count != configs.count { save() }
        return configs
    }

    func saveConfig(org: String, _ config: OrgConfig?) {
        let records = (try? context.fetch(FetchDescriptor<OrgConfigRecord>(predicate: #Predicate { $0.org == org }))) ?? []
        guard let config else {
            records.forEach(context.delete)
            save()
            return
        }
        let record = records.first ?? OrgConfigRecord(org: org)
        if records.isEmpty { context.insert(record) }
        records.dropFirst().forEach(context.delete)
        record.config = try? JSONEncoder().encode(config)
        record.updatedAt = .now
        save()
    }

    func deleteAllConfigs() {
        try? context.delete(model: OrgConfigRecord.self)
        save()
    }

    // MARK: Hidden items and stars

    func loadHidden() -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<HiddenRecord>())) ?? []).map(\.key))
    }

    func setHidden(_ key: String, _ isHidden: Bool) {
        let records = (try? context.fetch(FetchDescriptor<HiddenRecord>(predicate: #Predicate { $0.key == key }))) ?? []
        if isHidden {
            if records.isEmpty { context.insert(HiddenRecord(key: key)) }
        } else {
            records.forEach(context.delete)
        }
        save()
    }

    func deleteAllHidden() {
        try? context.delete(model: HiddenRecord.self)
        save()
    }

    func loadStars() -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<StarRecord>())) ?? []).map(\.org))
    }

    func setStar(_ org: String, _ isStarred: Bool) {
        let records = (try? context.fetch(FetchDescriptor<StarRecord>(predicate: #Predicate { $0.org == org }))) ?? []
        if isStarred {
            if records.isEmpty { context.insert(StarRecord(org: org)) }
        } else {
            records.forEach(context.delete)
        }
        save()
    }

    func deleteAllStars() {
        try? context.delete(model: StarRecord.self)
        save()
    }

    // MARK: Migration

    private static let migratedKey = "userDataMigrated"

    /// Once per device: copies what was kept in `UserDefaults` before sync
    /// into the store. The old keys are left in place for now, in case of a
    /// rollback, but nothing reads them after this.
    private func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        if let data = defaults.data(forKey: "peopleDates"),
           let people = try? JSONDecoder().decode([String: [String: PersonDates]].self, from: data) {
            for (org, logins) in people {
                for (login, dates) in logins { savePerson(org: org, login: login, dates) }
            }
        }
        if let data = defaults.data(forKey: "orgConfigs"),
           let configs = try? JSONDecoder().decode([String: OrgConfig].self, from: data) {
            for (org, config) in configs { saveConfig(org: org, config) }
        }
        for key in defaults.stringArray(forKey: "hiddenItems") ?? [] { setHidden(key, true) }
        for org in defaults.stringArray(forKey: "starredOrgs") ?? [] { setStar(org, true) }
        defaults.set(true, forKey: Self.migratedKey)
    }
}
