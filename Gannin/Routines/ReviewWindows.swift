import Foundation

/// A review window as the person's own file keeps it (`people/<login>.json`
/// in the home harness), so the same windows reach each of their Macs.
struct ReviewWindow: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var start: TimeOfDay
    var end: TimeOfDay
    /// `Calendar` weekdays it opens on, sorted so the file reads the same
    /// each time; nil for the org's working days.
    var days: [Int]?
    var reviewsAtOnce: Int

    init(_ routine: Routine) {
        id = routine.id
        name = routine.name
        if case .window(let window) = routine.schedule {
            start = window.start
            end = window.end
            days = window.days?.sorted()
        } else {
            start = TimeOfDay(hour: 12)
            end = TimeOfDay(hour: 13)
            days = nil
        }
        reviewsAtOnce = max(1, routine.concurrency)
    }

    /// As the routine the scheduler, the editor and the board work with.
    func routine(org: String, harnessRepo: String = "") -> Routine {
        Routine(
            id: id, name: name, org: org, harnessRepo: harnessRepo, kind: .reviewQueue,
            schedule: .window(RoutineWindow(start: start, end: end, days: days.map(Set.init))),
            concurrency: max(1, reviewsAtOnce), createdAt: .distantPast
        )
    }
}

/// An org's review windows: this Mac's own (`reviewQueue` routines) when it
/// overrides them, else the person's synced ones (R2).
enum ReviewWindows {
    static func resolved(org: String, overridden: Bool, local: [Routine], synced: [ReviewWindow]) -> [Routine] {
        if overridden { return local.filter { $0.org == org && $0.kind == .reviewQueue } }
        return synced.map { $0.routine(org: org) }
    }
}

/// Where an org's review windows are read and changed: the signed-in
/// person's file (staged in the home harness for an org with one, so the
/// change is pending until it's committed), or this Mac's override.
struct ReviewWindowBook {
    let org: String
    let login: String?
    let routines: RoutineStore
    let people: PeopleDatesStore

    var isOverridden: Bool { routines.overridesReviewWindows(org) }

    var synced: [ReviewWindow] {
        login.map { people.dates(for: $0, in: org).reviewWindows ?? [] } ?? []
    }

    /// The windows in force here, by name.
    var windows: [Routine] {
        ReviewWindows.resolved(org: org, overridden: isOverridden, local: routines.routines, synced: synced)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether there's somewhere to keep a window: an override, or someone
    /// signed in whose file it goes in.
    var canEdit: Bool { isOverridden || login != nil }

    func save(_ window: Routine) {
        if isOverridden {
            routines.save(window)
            return
        }
        updateSynced { windows in
            let saved = ReviewWindow(window)
            if let index = windows.firstIndex(where: { $0.id == saved.id }) {
                windows[index] = saved
            } else {
                windows.append(saved)
            }
        }
    }

    func remove(_ id: UUID) {
        if isOverridden {
            routines.remove(id)
        } else {
            updateSynced { $0.removeAll { $0.id == id } }
        }
    }

    /// Turned on with no windows of its own yet, this Mac starts from a copy
    /// of the synced ones.
    func setOverridden(_ on: Bool) {
        if on, !routines.routines.contains(where: { $0.org == org && $0.kind == .reviewQueue }) {
            for window in synced {
                var copy = window
                copy.id = UUID()
                routines.save(copy.routine(org: org))
            }
        }
        routines.setOverridesReviewWindows(org, on)
    }

    private func updateSynced(_ change: (inout [ReviewWindow]) -> Void) {
        guard let login else { return }
        people.update(login, in: org) { dates in
            var windows = dates.reviewWindows ?? []
            change(&windows)
            dates.reviewWindows = windows.isEmpty ? nil : windows
        }
    }
}
