import SwiftUI

/// Agents › Queue: the org's issues waiting for an agent, in the order
/// queue windows take them (R6), dragged to reorder and removed, with the
/// windows that drain it and the issues pinned to a time.
struct AgentQueuePage: View {
    @Environment(RoutineStore.self) private var routines
    @Environment(OrgConfigStore.self) private var configs
    @Environment(BankHolidayStore.self) private var holidays
    @Environment(\.navigate) private var navigate
    @Environment(\.showSidebarItem) private var showSidebarItem
    let org: String
    @State private var editing: EditedRoutine?

    var body: some View {
        let queue = routines.queue(for: org)
        let windows = routines.routines(for: org).filter { $0.kind == .issueQueue }
        let pins = routines.routines(for: org).filter { $0.kind == .pinned && $0.isEnabled }
        VStack(alignment: .leading, spacing: 0) {
            drains(windows)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            if queue.isEmpty && pins.isEmpty {
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
            Button("Routines") { showSidebarItem?.perform(.tab(.routines)) }
                .help("Add or change queue windows")
        }
        .font(.callout)
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
    @Environment(OrgConfigStore.self) private var configs
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
        }
    }

    private var help: String {
        if routines.isQueued(reference.id) { return "In the agent queue; a queue window starts it" }
        if let pin = routines.pin(for: reference.id) { return "Pinned to \(pin.schedule.summary)" }
        return "Have an agent work on this later: in the agent queue, or at a time"
    }
}

/// Marks an issue in the agent queue or pinned to a time, where the issue is
/// listed or shown; nothing when it's neither.
struct ScheduledForAgentPill: View {
    @Environment(RoutineStore.self) private var routines
    let issueID: String

    var body: some View {
        if let pin = routines.pin(for: issueID) {
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
