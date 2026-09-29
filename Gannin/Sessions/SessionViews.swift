#if os(macOS)
import AppKit
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .starting, .working: ChartPalette.blue
        case .needsYou: .orange
        case .idle: .green
        case .exited, .stopped: .secondary.opacity(0.5)
        }
    }
}

/// A session's window: the terminal claude runs in, and beside it the issue
/// with its board fields, so the ticket can be moved without leaving.
struct SessionWindow: View {
    @Environment(SessionStore.self) private var sessions
    let id: UUID

    var body: some View {
        if let session = sessions.sessions[id] {
            HStack(spacing: 0) {
                TerminalHost(session: session)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SessionPanel(session: session)
                    .frame(width: 340)
            }
            .frame(minHeight: 480)
            .navigationTitle(session.issue.reference)
            .windowSubtitle(session.issue.title)
        } else {
            ContentUnavailableView("No session", systemImage: "terminal", description: Text("It was removed."))
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Hosts the store's terminal view, launching it when first shown.
private struct TerminalHost: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var view: NSView?

    var body: some View {
        Group {
            if let view {
                TerminalRepresentable(view: view)
            } else {
                Color.clear
            }
        }
        .onAppear {
            view = sessions.open(session)
            sessions.terminal(session.id)?.focus()
        }
        // Restart swaps the terminal inside the same container, so only the
        // keyboard needs putting back.
        .onChange(of: sessions.state(session.id)) { _, state in
            if state == .starting { sessions.terminal(session.id)?.focus() }
        }
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        // Moved from a window that was closed, or first shown.
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct SessionPanel: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let session: CodeSession
    @State private var confirmingRemove = false

    var body: some View {
        let state = sessions.state(session.id)
        let worktree = SessionStore.worktree(for: session)
        Form {
            Section("Issue") {
                Text(session.issue.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(session.issue.reference, destination: session.issue.url)
                    Spacer()
                    Button("Open Issue") { openWindow(value: session.issue) }
                }
            }
            Section("Claude Code") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(state.color).frame(width: 8, height: 8)
                        Text(state.label)
                    }
                }
                LabeledContent("Branch") {
                    Text(session.branch)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let pullRequest = session.pullRequest {
                    LabeledContent("Pull request") {
                        Link(pullRequest.lastPathComponent.isEmpty ? "Open" : "#\(pullRequest.lastPathComponent)", destination: pullRequest)
                    }
                    Text("Claude opened a pull request. Move the issue along on its board below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([worktree])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: worktree.path))
                    Spacer()
                    if sessions.isRunning(session.id) {
                        Button("End") { sessions.end(session.id) }
                            .help("End claude and the shell it runs in. The worktree stays, and Restart resumes the conversation.")
                    } else {
                        Button("Restart") { _ = sessions.open(session) }
                            .help("Start the terminal again, resuming claude's conversation")
                    }
                    Button("Remove", role: .destructive) { confirmingRemove = true }
                }
            }
            ProjectFieldsSections(org: session.org, issueID: session.issue.id)
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this session?", isPresented: $confirmingRemove) {
            Button("Remove Session", role: .destructive) { sessions.remove(session.id) }
        } message: {
            Text("Claude is ended and Gannin forgets the session. The worktree stays at \(worktree.path) for you to remove with git worktree remove.")
        }
    }
}

/// Work on This: make (or open) the issue's session, in a code repo picked
/// from the org's (those with PRs, so not an issues-only repo), with a brief
/// written from what Gannin knows about the issue and its plans now.
struct StartSessionButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(IssueStore.self) private var issues
    @Environment(DetailStore.self) private var details
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metrics
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(\.openWindow) private var openWindow
    let reference: IssueReference

    var body: some View {
        if let existing = sessions.session(forIssue: reference.id) {
            Button {
                openWindow(value: SessionWindowID(id: existing.id))
            } label: {
                Label("Open Session", systemImage: "terminal")
            }
            .help("Show this issue's Claude Code session, in \(existing.repo)")
        } else {
            let (suggested, others) = repositories
            if let first = suggested.first {
                Menu {
                    menuItems(suggested: suggested, others: others)
                } label: {
                    Label("Work on This", systemImage: "terminal")
                } primaryAction: {
                    start(in: first)
                }
                .help("Work on this issue with Claude Code in \(first), or pick another repository from the menu")
            } else {
                Menu {
                    menuItems(suggested: suggested, others: others)
                } label: {
                    Label("Work on This", systemImage: "terminal")
                }
                .help("Pick the repository to work on this issue in with Claude Code")
            }
        }
    }

    @ViewBuilder
    private func menuItems(suggested: [String], others: [String]) -> some View {
        if !suggested.isEmpty {
            Section("Suggested") {
                ForEach(suggested, id: \.self) { repo in Button(repo) { start(in: repo) } }
            }
        }
        Section(suggested.isEmpty ? "Repositories" : "Other Repositories") {
            ForEach(others, id: \.self) { repo in Button(repo) { start(in: repo) } }
        }
    }

    /// Suggested: where the issue's linked PRs were opened, then repos the
    /// org's sessions have used. Others: every repo with PRs, less excluded
    /// ones and the harness.
    private var repositories: (suggested: [String], others: [String]) {
        let config = configs.config(for: reference.org)
        let code = OrgSettingsView.repositories(snapshot: orgs.snapshot(for: reference.org), history: metrics.history(for: reference.org))
            .filter { $0.openPullRequests + $0.merged > 0 }
            .map(\.name)
            .filter { !config.excludedRepos.contains($0) && $0 != config.harness?.repo }
        let linked = (issues.history(for: reference.org)?.issues[reference.id]?.linkedPullRequests ?? [])
            .compactMap { pr -> String? in
                let parts = pr.url.pathComponents.filter { $0 != "/" }
                return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
            }
        var seen: Set<String> = []
        let suggested = (linked + sessions.recentRepos(for: reference.org).filter(code.contains))
            .filter { seen.insert($0).inserted }
            .prefix(3)
        return (Array(suggested), code.filter { !suggested.contains($0) })
    }

    private func start(in repo: String) {
        let history = issues.history(for: reference.org)
        let record = history?.issues[reference.id]
        let parent = record?.parentID.flatMap { history?.issues[$0] }
        let detail = details.detail(for: reference.id)
        let index = configs.config(for: reference.org).harness.flatMap { harness.index(for: reference.org, $0) }
        let session = sessions.start(reference, in: repo) { session in
            SessionBrief.make(session: session, record: record, detail: detail, parent: parent, harness: index)
        }
        openWindow(value: SessionWindowID(id: session.id))
    }
}

/// The org's sessions, for the sidebar: each opens its window.
struct SessionSidebarRows: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String

    var body: some View {
        ForEach(sessions.sessions(for: org)) { session in
            let state = sessions.state(session.id)
            Button {
                openWindow(value: SessionWindowID(id: session.id))
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(state.color).frame(width: 8, height: 8).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.issue.title).lineLimit(1)
                        Text(verbatim: "#\(session.issue.number) · \(state.label)")
                            .font(.caption)
                            .foregroundStyle(state == .needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.issue.reference)
        }
    }
}

/// Settings > General: where sessions clone repos.
struct SessionSettingsSection: View {
    @AppStorage(SessionStore.workspaceKey) private var workspace = SessionStore.defaultWorkspace

    var body: some View {
        Section {
            LabeledContent("Workspace") {
                HStack {
                    Text(workspace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose", action: choose)
                }
            }
            Text("Work on This clones an issue's repo here (as owner/name) the first time, then gives each issue a git worktree beside it. Clones use gh if it's installed, else git with your credentials, and claude runs signed in as you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SessionStore.workspaceRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        workspace = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
#endif
