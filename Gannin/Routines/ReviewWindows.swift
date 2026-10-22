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

    /// Whether the windows in force are known: this Mac's own, or the
    /// person's once they're signed in and, for an org with a harness, its
    /// team data has loaded. Until then an empty list would read as "no
    /// windows" and let reviews start anywhere.
    var isLoaded: Bool {
        if isOverridden { return true }
        guard login != nil else { return false }
        return people.team?.hasLoaded(org) ?? true
    }

    /// The windows in force, or nil while they aren't known (`isLoaded`).
    var windowsIfKnown: [Routine]? { isLoaded ? windows : nil }

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

/// Whether an automatic review (a request Auto review picks up, or a
/// watched review's Look Again) may start now or waits in the review queue.
/// Reviews started by hand never ask.
enum ReviewGate {
    enum Decision: Equatable {
        /// Start it, while fewer than `limit` automatic reviews run.
        case start(limit: Int)
        case queue
        /// The windows aren't known yet (just launched, not signed in, the
        /// harness not loaded): neither start nor queue, but ask again later.
        case unknown
    }

    /// With no windows (none on), start as before, up to
    /// `AutoReview.maxRunning` (R11). With windows, start only while one is
    /// open and `running` (every automatic review on this Mac, whatever its
    /// org) is under its reviews at once (R5); otherwise, or while routines
    /// are paused, queue it (R3, R4). Nil `windows` (not known yet) never
    /// starts anything.
    static func decide(now: Date, windows: [Routine]?, running: Int, paused: Bool, calendar: Calendar = .current,
                       isWorkingDay: RoutineSchedule.WorkingDays = RoutineSchedule.everyWeekday) -> Decision {
        guard let windows = windows?.filter(\.isEnabled) else { return .unknown }
        guard !windows.isEmpty else { return .start(limit: AutoReview.maxRunning) }
        guard !paused,
              let room = windows.filter({ $0.schedule.isOpen(at: now, calendar: calendar, isWorkingDay: isWorkingDay) }).map(\.concurrency).max(),
              running < room else { return .queue }
        return .start(limit: room)
    }
}

/// What a queued review's turn comes to before anything starts (R7): why
/// it's skipped, that it can't start yet, or nil to go ahead.
enum QueuedReviewCheck {
    /// What's known about the queued review when its turn comes.
    struct Facts {
        /// The PR on GitHub now; nil if it's gone.
        var pullRequest: PullRequestState?
        /// PRs asking for your review, less those you dismissed; nil if not
        /// looked yet.
        var requested: Set<String>?
        var hasReview = false
        var isStarting = false
        var autoReviewIsOn = true
        /// A Look Again's review: whether it's still watching its PR, and
        /// whether its claude is busy.
        var reviewIsWatching = false
        var reviewIsBusy = false
    }

    static func verdict(_ queued: QueuedReview, _ facts: Facts) -> RoutineStart? {
        guard let found = facts.pullRequest else { return .skipped("The PR is gone.") }
        switch found.state {
        case "MERGED": return .skipped("It was merged while it waited.")
        case "CLOSED": return .skipped("It was closed while it waited.")
        default: break
        }
        if found.isDraft { return .skipped("It was made a draft while it waited.") }
        if queued.lookAgain != nil {
            guard facts.reviewIsWatching else { return .skipped("Its review was finished, or stopped watching the PR.") }
            if facts.reviewIsBusy { return .notYet("Its review was busy, so it waits for the next turn.") }
            return nil
        }
        if let requested = facts.requested, !requested.contains(queued.id) { return .skipped("It no longer asks for your review, or you dismissed it.") }
        if facts.hasReview { return .skipped("It already has a review.") }
        if facts.isStarting { return .notYet("Its review was already being started.") }
        guard facts.autoReviewIsOn else { return .skipped("Auto review is off for \(queued.pullRequest.org).") }
        return nil
    }
}
