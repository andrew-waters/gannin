import SwiftUI

/// Rituals › Design and Refine: the org's sessions as a table, under way
/// first, each opening in the Claude Code window (on the screen in the
/// room), New Design and Refine, and Delete.
struct RefinePage: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Environment(OrgConfigStore.self) private var configs
    let org: String

    @State private var sort: StatsSort?
    /// Asking before a session is deleted.
    @State private var deleting: CodeSession?
    /// Its folder couldn't be removed: why, to delete it anyway.
    @State private var failed: (session: CodeSession, message: String)?

    private func showNew() {
        sessions.showNewRefine(org: org, harnessRepo: configs.config(for: org).harnesses.first?.repo, with: openWindow)
    }

    var body: some View {
        let all = sessions.refineSessions(for: org)
            .filter { $0.archivedAt == nil }
            .sorted { ($0.refine?.agreed == nil ? 0 : 1, $1.createdAt) < ($1.refine?.agreed == nil ? 0 : 1, $0.createdAt) }
        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No Design and Refine sessions", systemImage: "rectangle.and.pencil.and.ellipsis")
                } description: {
                    Text("Step through a web page together and note what to improve, with Claude looking at the code. What the room agrees becomes issues, and the session is recorded in the harness.")
                } actions: {
                    Button("New Design and Refine", action: showNew)
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
                Button(action: showNew) {
                    Label("New Design and Refine", systemImage: "plus")
                }
                .help("Step through a web page with the team")
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "this session")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
        } message: { session in
            Text(session.refine?.agreed == nil
                 ? "This stops the session and removes its folder, with its findings and screenshots. It can't be undone. Nothing has been written to the harness or GitHub yet."
                 : "This stops the session and removes its folder. It can't be undone. Its record and issues stay in the harness and on GitHub.")
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
            StatsColumn(id: "name", title: "Page", help: "What's being looked at, and its address", minWidth: 260,
                        sortKey: { .text($0.title) }, cell: { session in AnyView(nameCell(session)) }),
            StatsColumn(id: "findings", title: "Findings", help: "What the room noted", width: 90, alignment: .trailing,
                        sortKey: { .number(Double($0.refine?.findings.count ?? 0)) },
                        cell: { session in
                            let count = session.refine?.findings.count ?? 0
                            return AnyView(Text(count == 0 ? "" : "\(count)").monospacedDigit())
                        }),
            StatsColumn(id: "attendees", title: "Who's here", help: "Who's in the meeting", width: 200,
                        sortKey: { .text(attendees($0)) },
                        cell: { session in AnyView(Text(attendees(session)).lineLimit(1).foregroundStyle(.secondary)) }),
            StatsColumn(id: "started", title: "Started", help: "When the session started", width: 120,
                        sortKey: { .number($0.createdAt.timeIntervalSince1970) },
                        cell: { session in AnyView(Text(session.createdAt.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)) }),
            StatsColumn(id: "delete", title: "", help: "Delete the session", width: 44, alignment: .center,
                        sortKey: { _ in .number(0) },
                        cell: { session in AnyView(deleteButton(session)) }),
        ]
    }

    private func statusCell(_ session: CodeSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.refine?.agreed == nil ? sessions.state(session.id).color : ChartPalette.good)
                .frame(width: 8, height: 8)
            Text(status(session)).lineLimit(1)
        }
    }

    private func nameCell(_ session: CodeSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title).fontWeight(.medium).lineLimit(1)
            if let url = session.refine?.url {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .help("Delete this session")
        .accessibilityLabel("Delete \(session.title)")
    }

    @ViewBuilder
    private func menu(_ session: CodeSession) -> some View {
        Button("Open") { sessions.show(session.id, with: openWindow) }
        if let url = session.refine.flatMap({ URL(string: $0.url) }) {
            Link("Open Page in Browser", destination: url)
        }
        Divider()
        Button("Delete", role: .destructive) { deleting = session }
    }

    // MARK: Text

    private func status(_ session: CodeSession) -> String {
        guard let agreed = session.refine?.agreed else { return sessions.state(session.id).label }
        return "Agreed \(agreed.formatted(date: .abbreviated, time: .omitted))"
    }

    private func attendees(_ session: CodeSession) -> String {
        session.refine?.attendees.map(\.name).joined(separator: ", ") ?? ""
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
