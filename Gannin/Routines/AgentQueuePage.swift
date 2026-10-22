import SwiftUI

/// Agents › Queue: the org's issues waiting for an agent, in the order
/// queue windows take them (R6), dragged to reorder and removed, with the
/// windows that drain it and the issues pinned to a time; and the reviews
/// waiting for a review window, with what review windows ran lately (R9,
/// R10). Board lays them over the coming week (`ScheduleBoard`); List is
/// each queue in order.
struct AgentQueuePage: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(RoutineScheduler.self) private var scheduler
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(AuthStore.self) private var auth
    @Environment(\.navigate) private var navigate
    @Environment(\.showSidebarItem) private var showSidebarItem
    let org: String
    @State private var editing: EditedRoutine?
    @AppStorage("agentQueueLayout") private var layout = "board"

    var body: some View {
        let queue = routines.queue(for: org)
        let windows = routines.routines(for: org).filter { $0.kind == .issueQueue }
        let pins = routines.routines(for: org).filter { $0.kind == .pinned && $0.isEnabled }
        let reviews = routines.reviewQueue(for: org)
        let reviewRuns = Array(routines.runs.filter { $0.pullRequest?.org == org }.sorted { $0.scheduledAt > $1.scheduledAt }.prefix(10))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                drains(windows)
                reviewWindowsNote
                    .font(.callout)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if layout == "board" {
                ScheduleBoard(org: org)
            } else if queue.isEmpty && pins.isEmpty && reviews.isEmpty && reviewRuns.isEmpty {
                ContentUnavailableView(
                    "Nothing queued",
                    systemImage: "tray",
                    description: Text("Add issues with Schedule for Agent on an issue, beside Work on This. A queue window starts them in this order, as Work on This would, each in the project covering its repos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !queue.isEmpty {
                        Section("Queued, in order") {
                            ForEach(queue) { item in
                                QueuedIssueRow(item: item, position: (queue.firstIndex(of: item) ?? 0) + 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { navigate?.perform(.issueReference(item.issue)) }
                                    .contextMenu {
                                        Button("Open") { navigate?.perform(.issueReference(item.issue)) }
                                        Button("Move to Top") { routines.move(item.issue.id, toFront: true) }
                                        Button("Move to Bottom") { routines.move(item.issue.id, toFront: false) }
                                        Divider()
                                        Button("Remove from Queue") { routines.dequeue(item.issue.id) }
                                    }
                            }
                            .onMove { source, destination in routines.move(in: org, fromOffsets: source, toOffset: destination) }
                            .onDelete { offsets in
                                for offset in offsets { routines.dequeue(queue[offset].issue.id) }
                            }
                        }
                    }
                    if !reviews.isEmpty {
                        Section("Reviews waiting for a review window, in order") {
                            ForEach(reviews) { item in
                                QueuedReviewRow(item: item, position: (reviews.firstIndex(of: item) ?? 0) + 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { navigate?.perform(.pullRequestReference(item.pullRequest)) }
                                    .contextMenu {
                                        Button("Open Pull Request") { navigate?.perform(.pullRequestReference(item.pullRequest)) }
                                        QueuedReviewMenu(review: item, routines: routines, scheduler: scheduler)
                                    }
                            }
                            .onMove { source, destination in routines.moveReviews(in: org, fromOffsets: source, toOffset: destination) }
                            .onDelete { offsets in
                                for offset in offsets { routines.dequeueReview(reviews[offset].id) }
                            }
                        }
                    }
                    if !reviewRuns.isEmpty {
                        Section("Reviews review windows started") {
                            ForEach(reviewRuns) { run in
                                ReviewRunRow(run: run)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        if let pr = run.pullRequest { navigate?.perform(.pullRequestReference(pr)) }
                                    }
                            }
                        }
                    }
                    if !pins.isEmpty {
                        Section("Pinned to a time") {
                            ForEach(pins) { pin in
                                PinnedIssueRow(routine: pin)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { navigate?.perform(.routine(id: pin.id, name: pin.name)) }
                                    .contextMenu {
                                        if let issue = pin.issue {
                                            Button("Open Issue") { navigate?.perform(.issueReference(issue)) }
                                        }
                                        Button("Change Time…") { editing = EditedRoutine(routine: pin, isNew: false) }
                                        Divider()
                                        Button("Unpin") { routines.remove(pin.id) }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { edited in
            RoutineEditor(routine: edited.routine, isNew: edited.isNew)
                .environment(routines)
                .environment(sessions)
                .environment(configs)
                .environment(holidays)
        }
    }

    /// Which windows take from the queue, and when next; or how to add one.
    @ViewBuilder
    private func drains(_ windows: [Routine]) -> some View {
        let days = RoutineScheduleContext.workingDays(org: org, configs: configs, holidays: holidays)
        let on = windows.filter(\.isEnabled)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            if on.isEmpty {
                Text("No queue window is on, so nothing here starts by itself.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(on) { window in
                        let open = window.schedule.isOpen(at: .now, isWorkingDay: days)
                        let next = window.schedule.nextTimes(after: .now, count: 1, isWorkingDay: days).first
                        Text("\(window.name): \(window.schedule.summary), \(window.concurrency) at once, \(window.limit.label). ")
                            + Text(open ? "Open now." : next.map { "Opens \($0.formatted(.relative(presentation: .named)))." } ?? "")
                            .foregroundStyle(open ? ChartPalette.good : .secondary)
                    }
                    if routines.isPaused {
                        Text("Routines are paused.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Picker("Layout", selection: $layout) {
                Text("Board").tag("board")
                Text("List").tag("list")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Button("Routines") { showSidebarItem?.perform(.tab(.routines)) }
                .help("Add or change queue windows")
        }
        .font(.callout)
    }

    /// When queued reviews start: the review windows, open or next, or none.
    @ViewBuilder
    private var reviewWindowsNote: some View {
        let days = RoutineScheduleContext.workingDays(org: org, configs: configs, holidays: holidays)
        // Nil until they're known, while the queue is held (`windowsIfKnown`).
        let known = ReviewWindowBook(org: org, login: auth.viewer?.login, routines: routines, people: peopleDates).windowsIfKnown?.filter(\.isEnabled)
        let windows = known ?? []
        let waiting = routines.reviewQueue(for: org).count
        if !windows.isEmpty || waiting > 0 {
            let open = windows.first { $0.schedule.isOpen(at: .now, isWorkingDay: days) }
            let next = windows.compactMap { $0.schedule.nextTimes(after: .now, count: 1, isWorkingDay: days).first }.min()
            let when: String = if known == nil {
                "Checking your review windows, so none start yet."
            } else if windows.isEmpty {
                "No review window, so they start as Auto review would."
            } else {
                open.map { "\($0.name) is open now." } ?? next.map { "Next review window opens \($0.formatted(.relative(presentation: .named)))." } ?? ""
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: RoutineKind.reviewQueue.systemImage)
                    .foregroundStyle(.secondary)
                Text("\(waiting) review\(waiting == 1 ? "" : "s") waiting. ")
                    + Text(when)
                    .foregroundStyle(open != nil ? ChartPalette.good : .secondary)
            }
        }
    }
}

/// Run Now, moving and removing a review waiting for a review window. Its
/// stores are parameters, as it's built in context menus.
struct QueuedReviewMenu: View {
    let review: QueuedReview
    let routines: RoutineStore
    let scheduler: RoutineScheduler

    var body: some View {
        Button("Run Now") { scheduler.runReviewNow(review) }
            .help("Start this review now, whether or not a review window is open")
        Button("Move to Top") { routines.moveReview(review.id, toFront: true) }
        Button("Move to Bottom") { routines.moveReview(review.id, toFront: false) }
        Divider()
        Button("Remove from Queue") { routines.dequeueReview(review.id) }
    }
}

private struct QueuedReviewRow: View {
    let item: QueuedReview
    let position: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.pullRequest.title)
                    .lineLimit(1)
                Text("\(item.pullRequest.repo)#\(item.pullRequest.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.lookAgain.map { "Look again: \($0.reasons)" } ?? "Review requested")
                .font(.caption)
                .lineLimit(1)
            Text("Queued \(item.queuedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ReviewRunRow: View {
    let run: RoutineRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RoutineKind.reviewQueue.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.pullRequest?.title ?? "")
                    .lineLimit(1)
                Text(run.pullRequest.map { "\($0.repo)#\($0.number)" } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                RunOutcomeLabel(run: run)
                    .font(.caption)
                if let note = run.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(run.scheduledAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct QueuedIssueRow: View {
    let item: QueuedIssue
    let position: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.issue.title)
                    .lineLimit(1)
                Text(item.issue.reference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Added \(item.addedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PinnedIssueRow: View {
    let routine: Routine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.issue?.title ?? routine.name)
                    .lineLimit(1)
                Text(routine.issue?.reference ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(routine.schedule.summary)
                .font(.caption)
            Text(routine.limit.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Schedule for Agent beside Work on This: add the issue to the agent
/// queue (or take it off), or pin it to a time (R6, R8).
struct ScheduleForAgentButton: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(IssueStore.self) private var issues
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    let reference: IssueReference
    @State private var editing: EditedRoutine?

    var body: some View {
        Menu {
            ScheduleForAgentItems(reference: reference, editing: $editing)
        } label: {
            Label("Schedule for Agent", systemImage: routines.isQueued(reference.id) || routines.pin(for: reference.id) != nil ? "clock.badge.checkmark" : "clock")
        }
        .help(help)
        .disabled(configs.config(for: reference.org).allHarnesses.isEmpty)
        .sheet(item: $editing) { edited in
            RoutineEditor(routine: edited.routine, isNew: edited.isNew)
                .environment(routines)
                .environment(sessions)
                .environment(configs)
                .environment(holidays)
        }
    }

    private var help: String {
        if routines.isQueued(reference.id) { return "In the agent queue; a queue window starts it" }
        if let pin = routines.pin(for: reference.id) { return "Pinned to \(pin.schedule.summary)" }
        return "Have an agent work on this later: in the agent queue, or at a time"
    }
}

/// Marks an issue in the agent queue, pinned to a time, or with a scheduled
/// session going, where the issue is listed or shown; nothing otherwise. The store is passed in rather
/// than read from the environment: a table's cells, rebuilt when it sorts or
/// a row expands, don't always get the page's environment objects.
struct ScheduledForAgentPill: View {
    let routines: RoutineStore
    let issueID: String

    var body: some View {
        if let run = routines.activeRuns.first(where: { $0.issue?.id == issueID }) {
            if run.outcome == .needsYou {
                pill("Agent Needs You", help: "Its scheduled session is waiting on you")
            } else {
                pill("Agent Working", help: "Its scheduled session is running")
            }
        } else if let pin = routines.pin(for: issueID) {
            pill("Pinned for Agent", help: "Pinned to \(pin.schedule.summary)")
        } else if let queued = routines.queue.first(where: { $0.issue.id == issueID }) {
            let position = (routines.queue(for: queued.issue.org).firstIndex { $0.id == issueID } ?? 0) + 1
            pill("Queued for Agent", help: "Number \(position) in the agent queue; a queue window starts it")
        }
    }

    private func pill(_ text: String, help: String) -> some View {
        Pill(text: text, color: .teal, systemImage: "clock.badge.checkmark")
            .fixedSize()
            .help(help)
    }
}

/// The items of Schedule for Agent, for its menu and context menus. Pin to
/// a Time sets `editing`, whose sheet is on the list, not the row.
struct ScheduleForAgentItems: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(IssueStore.self) private var issues
    @Environment(OrgConfigStore.self) private var configs
    let reference: IssueReference
    @Binding var editing: EditedRoutine?

    var body: some View {
        if routines.isQueued(reference.id) {
            Button("Remove from Agent Queue") { routines.dequeue(reference.id) }
        } else {
            Button("Add to Agent Queue") { routines.enqueue(reference) }
        }
        if let pin = routines.pin(for: reference.id) {
            Button("Change Pinned Time…") { editing = EditedRoutine(routine: pin, isNew: false) }
            Button("Unpin") { routines.remove(pin.id) }
        } else {
            Button("Pin to a Time…") {
                let repo = configs.config(for: reference.org).harness(covering: WorkOnThisLauncher.repos(reference, issues: issues))?.repo
                    ?? configs.config(for: reference.org).allHarnesses.first?.repo ?? ""
                editing = EditedRoutine(routine: Routine.new(org: reference.org, harnessRepo: repo, kind: .pinned, issue: reference), isNew: true)
            }
        }
    }
}
