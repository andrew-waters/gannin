import SwiftUI

/// Rituals › Planning: the org's planning sessions as a table, under way
/// first, each opening its workspace in the Claude Code window (on the
/// screen in the room), New Planning Session, and Delete. Plan This on an
/// issue starts one about it.
struct PlanningPage: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    /// A new plan in the window's project's harness.
    private var draft: PlanningDraft {
        PlanningDraft(org: org, harnessRepo: configs.config(for: org).harnesses.first?.repo)
    }
    @State private var sort: StatsSort?
    /// Asking before a session is deleted.
    @State private var deleting: CodeSession?

    var body: some View {
        let all = sessions.sessions(for: org)
            .filter(\.isPlanning)
            .sorted { (Self.rank($0), $1.createdAt) < (Self.rank($1), $0.createdAt) }
        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No planning sessions", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("Plan a topic, or Plan This on an issue. Claude interviews the room one question at a time, looks at the code when a question needs it, and breaks the work down. When the room agrees, Gannin writes the plan to the harness and makes the sub-issues.")
                } actions: {
                    Button("New Plan") { sessions.showNewPlan(draft, with: openWindow) }
                }
            } else {
                ScrollView(.vertical) {
                    StatsTable(
                        rows: all, columns: columns, sort: $sort, selectedID: nil,
                        onSelect: { sessions.show($0.id, with: openWindow) },
                        contextMenu: { session in AnyView(menu(session)) }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    sessions.showNewPlan(draft, with: openWindow)
                } label: {
                    Label("New Plan", systemImage: "plus")
                }
                .help("Plan a topic with the team")
            }
        }
        .deletesPlanning($deleting)
    }

    // MARK: Columns

    private var columns: [StatsColumn<CodeSession>] {
        [
            StatsColumn(id: "status", title: "Status", help: "Under way, with what Claude is doing, agreed, or finished", width: 150,
                        sortKey: { .text(status($0)) }, cell: { session in AnyView(statusCell(session)) }),
            StatsColumn(id: "topic", title: "Topic", help: "What's being planned, and the issue it's about", minWidth: 260,
                        sortKey: { .text(title($0)) }, cell: { session in AnyView(topicCell(session)) }),
            count("tasks", "Tasks", "Sub-issues proposed, made when the room agrees") { $0.tasks.count },
            count("findings", "Findings", "What was found in the code") { $0.scouting.count },
            count("decisions", "Decisions", "Answers the room settled") { $0.decisions.count },
            StatsColumn(id: "agreedBy", title: "Agreed by", help: "Who was in the room when it was agreed", width: 170,
                        sortKey: { .text($0.planning?.agreed?.by.joined(separator: ", ") ?? "") },
                        cell: { session in AnyView(Text(session.planning?.agreed?.by.joined(separator: ", ") ?? "").lineLimit(1).foregroundStyle(.secondary)) }),
            StatsColumn(id: "started", title: "Started", help: "When the session started", width: 120,
                        sortKey: { .number($0.createdAt.timeIntervalSince1970) },
                        cell: { session in AnyView(Text(session.createdAt.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)) }),
            StatsColumn(id: "delete", title: "", help: "Delete the session", width: 44, alignment: .center,
                        sortKey: { _ in .number(0) },
                        cell: { session in AnyView(deleteButton(session)) }),
        ]
    }

    private func count(_ id: String, _ title: String, _ help: String, _ value: @escaping (PlanningState) -> Int) -> StatsColumn<CodeSession> {
        StatsColumn(id: id, title: title, help: help, width: 90, alignment: .trailing,
                    sortKey: { .number(Double($0.planning?.state.map(value) ?? 0)) },
                    cell: { session in
                        let count = session.planning?.state.map(value) ?? 0
                        return AnyView(Text(count == 0 ? "" : "\(count)").monospacedDigit())
                    })
    }

    /// Under way, then agreed, then finished.
    static func rank(_ session: CodeSession) -> Int {
        guard session.archivedAt == nil else { return 2 }
        return session.planning?.agreed == nil ? 0 : 1
    }

    private func dotColor(_ session: CodeSession) -> Color {
        guard session.archivedAt == nil else { return .secondary.opacity(0.5) }
        return session.planning?.agreed == nil ? sessions.state(session.id).color : ChartPalette.good
    }

    private func statusCell(_ session: CodeSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(session))
                .frame(width: 8, height: 8)
            Text(status(session)).lineLimit(1)
        }
    }

    private func topicCell(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(session)).fontWeight(.medium).lineLimit(1)
            if let issue = session.planning?.issue {
                Text("\(issue.reference): \(issue.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let summary = session.planning?.state?.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func deleteButton(_ session: CodeSession) -> some View {
        Button {
            deleting = session
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Delete this planning session")
        .accessibilityLabel("Delete \(title(session))")
    }

    @ViewBuilder
    private func menu(_ session: CodeSession) -> some View {
        Button("Open") { sessions.show(session.id, with: openWindow) }
        if let agreed = session.planning?.agreed, let repo = session.harnessRepo {
            if let path = agreed.planPath, let url = URL(string: "https://github.com/\(repo)/blob/HEAD/\(path)") {
                Link("Open Plan on GitHub", destination: url)
            }
            if let parent = agreed.parentURL {
                Link("Open \(agreed.parent ?? "Parent Issue")", destination: parent)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { deleting = session }
    }

    // MARK: Text

    static func title(_ session: CodeSession) -> String {
        session.planning?.state?.title ?? session.planning?.topic ?? session.title
    }

    private func title(_ session: CodeSession) -> String { Self.title(session) }

    private func status(_ session: CodeSession) -> String {
        guard session.archivedAt == nil else { return "Finished" }
        guard let agreed = session.planning?.agreed else { return sessions.state(session.id).label }
        return "Agreed \(agreed.at.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Confirms deleting the planning session in `session` (its folder goes),
/// offering Delete Anyway when the folder can't be removed.
private struct DeletePlanningModifier: ViewModifier {
    @Environment(SessionStore.self) private var sessions
    @Binding var session: CodeSession?
    /// Its folder couldn't be removed: why, to delete it anyway.
    @State private var failed: (session: CodeSession, message: String)?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete \(session.map(PlanningPage.title) ?? "this planning session")?",
                isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }),
                presenting: session
            ) { session in
                Button("Delete", role: .destructive) { delete(session) }
            } message: { session in
                Text(message(session))
            }
            .alert(
                "Couldn't remove its folder",
                isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } }),
                presenting: failed
            ) { failed in
                Button("Delete Anyway", role: .destructive) { sessions.remove(failed.session.id) }
                Button("Cancel", role: .cancel) {}
            } message: { failed in
                Text("\(failed.message) Delete Anyway forgets the session and leaves its folder where it is.")
            }
    }

    private func message(_ session: CodeSession) -> String {
        var text = "This stops the session and removes its folder, with any documents shared into it\(session.isRemote ? ", on your server" : ""). It can't be undone."
        let madeCount = (session.planning?.madeParent != nil ? 1 : 0) + (session.planning?.madeIssues?.count ?? 0)
        if session.planning?.agreed != nil {
            text += " The plan, the requirement and the issues stay in the harness and on GitHub."
        } else if madeCount > 0 {
            text += " An earlier Agree and Write made \(madeCount == 1 ? "an issue" : "\(madeCount) issues") on GitHub already; those stay."
        } else {
            text += " Nothing has been written to the harness or GitHub yet."
        }
        return text
    }

    private func delete(_ session: CodeSession) {
        Task {
            do {
                try await sessions.finish(session.id)
            } catch {
                failed = (session, error.localizedDescription)
            }
        }
    }
}

extension View {
    func deletesPlanning(_ session: Binding<CodeSession?>) -> some View {
        modifier(DeletePlanningModifier(session: session))
    }
}

/// A planning session's context menu in the sidebar (Open, Delete), with
/// the delete confirmation.
private struct PlanningContextMenuModifier: ViewModifier {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession
    @State private var deleting: CodeSession?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open") { sessions.show(session.id, with: openWindow) }
                Divider()
                Button("Delete", role: .destructive) { deleting = session }
            }
            .deletesPlanning($deleting)
    }
}

extension View {
    func planningContextMenu(_ session: CodeSession) -> some View {
        modifier(PlanningContextMenuModifier(session: session))
    }
}
