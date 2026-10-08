import SwiftUI

/// Rituals › Planning: the org's planning sessions as a table, under way
/// first, each opening its workspace in the Claude Code window (on the
/// screen in the room), New Planning Session, and Delete. Plan This on an
/// issue starts one about it.
struct PlanningPage: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String
    @State private var starting = false
    @State private var sort: StatsSort?
    /// Asking before a session is deleted.
    @State private var deleting: CodeSession?
    /// Its folder couldn't be removed: why, to delete it anyway.
    @State private var failed: (session: CodeSession, message: String)?

    var body: some View {
        let all = sessions.sessions(for: org)
            .filter { $0.isPlanning && $0.archivedAt == nil }
            .sorted { ($0.planning?.agreed == nil ? 0 : 1, $1.createdAt) < ($1.planning?.agreed == nil ? 0 : 1, $0.createdAt) }
        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No planning sessions", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("Plan a topic, or Plan This on an issue. Claude interviews the room one question at a time, looks at the code when a question needs it, and breaks the work down. When the room agrees, Gannin writes the plan to the harness and makes the sub-issues.")
                } actions: {
                    Button("New Planning Session") { starting = true }
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
                    starting = true
                } label: {
                    Label("New Planning Session", systemImage: "plus")
                }
                .help("Plan a topic with the team")
            }
        }
        .sheet(isPresented: $starting) { NewPlanningSheet(org: org) }
        .confirmationDialog(
            "Delete \(deleting.map(title) ?? "this planning session")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
        } message: { session in
            Text(deleteMessage(session))
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

    // MARK: Columns

    private var columns: [StatsColumn<CodeSession>] {
        [
            StatsColumn(id: "status", title: "Status", help: "Under way, with what Claude is doing, or agreed", width: 150,
                        sortKey: { .text(status($0)) }, cell: { session in AnyView(statusCell(session)) }),
            StatsColumn(id: "topic", title: "Topic", help: "What's being planned, and the issue it's about", minWidth: 260,
                        sortKey: { .text(title($0)) }, cell: { session in AnyView(topicCell(session)) }),
            count("pieces", "Pieces", "Sub-issues proposed, made when the room agrees") { $0.breakdown.count },
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

    private func statusCell(_ session: CodeSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.planning?.agreed == nil ? sessions.state(session.id).color : ChartPalette.good)
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

    private func title(_ session: CodeSession) -> String {
        session.planning?.state?.title ?? session.planning?.topic ?? session.title
    }

    private func status(_ session: CodeSession) -> String {
        guard let agreed = session.planning?.agreed else { return sessions.state(session.id).label }
        return "Agreed \(agreed.at.formatted(date: .abbreviated, time: .omitted))"
    }

    private func deleteMessage(_ session: CodeSession) -> String {
        var text = "This stops the session and removes its folder, with any documents shared into it\(session.isRemote ? ", on your server" : ""). It can't be undone."
        if session.planning?.agreed != nil {
            text += " The plan, the requirement and the issues stay in the harness and on GitHub."
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
