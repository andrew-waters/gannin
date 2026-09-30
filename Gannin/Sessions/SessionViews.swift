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
        let worktreePath = SessionStore.worktreePath(for: session)
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
                LabeledContent(session.isRemote ? "Worktree on the server" : "Worktree") {
                    Text(worktreePath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(worktreePath)
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
                    if let worktree {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([worktree])
                        }
                        .disabled(!FileManager.default.fileExists(atPath: worktree.path))
                    }
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
            Text("Claude is ended and Gannin forgets the session. The worktree stays at \(worktreePath)\(session.isRemote ? " on the server" : "") for you to remove with git worktree remove.")
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
    @State private var isPicking = false

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
            let blocked = unavailable
            Button {
                isPicking = true
            } label: {
                Label("Work on This", systemImage: "terminal")
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Work on this issue with Claude Code in the harness: pick the repository the code is in")
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                // The top suggestion is highlighted, so Return starts there.
                SearchableList(
                    choices: suggested.map { SearchableChoice(value: $0, title: $0, section: "Suggested") }
                        + others.map { SearchableChoice(value: $0, title: $0, section: suggested.isEmpty ? "Repositories" : "Other Repositories") },
                    selection: nil,
                    prompt: "Search repositories"
                ) { repo in
                    isPicking = false
                    if let repo { start(in: repo) }
                }
            }
        }
    }

    /// Why a session can't start, if it can't: sessions run in the org's
    /// harness, and on a server only once its checkout there is set.
    private var unavailable: String? {
        guard configs.config(for: reference.org).harness != nil else {
            return "Sessions run in the org's harness. Pick or create it in the org's Settings, under Harness."
        }
        if SessionStore.connectCommand != nil, SessionStore.remoteHarnessPath(org: reference.org) == nil {
            return "Sessions run on your server. Set where the harness is checked out there in the org's Settings, under Harness."
        }
        return nil
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
        guard let setup = configs.config(for: reference.org).harness,
              let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return }
        let index = harness.index(for: reference.org, setup)
        let session = sessions.start(reference, in: repo, harness: setup, harnessPath: path) { session in
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
                Label {
                    Text(session.issue.title).lineLimit(1)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(state.color)
                }
            }
            .buttonStyle(.plain)
            .badge(Text(state.label))
            .help("\(session.issue.reference): \(state.label)")
        }
    }
}

/// Settings > General: where Gannin clones a harness, and the server
/// sessions run on.
struct SessionSettingsSection: View {
    @AppStorage(SessionStore.workspaceKey) private var workspace = SessionStore.defaultWorkspace
    @AppStorage(SessionStore.connectKey) private var connect = ""

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
            Text("Sessions run in the org's harness, with each issue's code in a git worktree under its .worktrees folder. When the harness isn't checked out on this Mac, Work on This clones it here. Clones use gh if it's installed, else git with your credentials, and claude runs signed in as you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Connect with", text: $connect, prompt: Text("ssh -t devbox"))
            Text("To run sessions on a server, the command that reaches it, with {command} where the rest goes (else it goes at the end). Empty runs them on this Mac. Set where each org's harness is checked out there in the org's Settings. Sessions stay where they were made.")
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
        workspace = SessionStore.tildePath(url)
    }
}

/// The org's Settings › Harness, on the Mac: where its harness is checked out
/// here and on the server, for sessions to run in.
struct HarnessCheckoutSection: View {
    @AppStorage(SessionStore.connectKey) private var connect = ""
    @AppStorage private var localPath: String
    @AppStorage private var remotePath: String
    let org: String
    let repo: String

    init(org: String, repo: String) {
        self.org = org
        self.repo = repo
        _localPath = AppStorage(wrappedValue: "", SessionStore.harnessPathKey(org))
        _remotePath = AppStorage(wrappedValue: "", SessionStore.remoteHarnessPathKey(org))
    }

    var body: some View {
        let found = SessionStore.existingCheckout(of: repo)
        let local = localPath.isEmpty ? SessionStore.localHarnessPath(org: org, repo: repo) : localPath
        let exists = FileManager.default.fileExists(atPath: SessionStore.expanded(local).appending(path: ".git").path)
        Section {
            LabeledContent("On this Mac") {
                HStack {
                    Text(local)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(local)
                    Button("Choose", action: choose)
                    if !localPath.isEmpty {
                        Button("Default") { localPath = "" }
                            .help(found.map { "Use the checkout found at \($0)" } ?? "Clone it into the workspace, set in Settings")
                    }
                }
            }
            Text(exists
                 ? "Claude Code sessions for this org run here: each issue's code is a git worktree under .worktrees, beside the shared clones in projects."
                 : "Not checked out here yet. The first session clones \(repo) here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !connect.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("On the server", text: $remotePath, prompt: Text("~/\(org)-harness"))
                Text("Sessions run on the server Settings connects to (\(connect)). Where the harness is checked out there, as a path on that box; the first session clones it if it isn't there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Checkout")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose \(repo)'s checkout, or the folder to clone it into"
        panel.directoryURL = SessionStore.expanded(SessionStore.localHarnessPath(org: org, repo: repo)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = SessionStore.tildePath(url)
    }
}
#endif
