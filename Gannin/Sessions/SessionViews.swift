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
                LabeledContent(session.isInHarness ? (session.isRemote ? "Folder on the server" : "Folder") : (session.isRemote ? "Worktree on the server" : "Worktree")) {
                    Text(worktreePath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(worktreePath)
                }
                if let folder = session.harnessFolder, let repo = session.harnessRepo,
                   let url = URL(string: "https://github.com/\(repo)/tree/HEAD/\(folder)") {
                    LabeledContent("In the harness") {
                        Link(folder, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let error = sessions.recordErrors[session.id] {
                    Text("Couldn't commit to the harness: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
            Text("Claude is ended and Gannin forgets the session. \(session.isInHarness ? "Its folder and worktrees stay" : "The worktree stays") at \(worktreePath)\(session.isRemote ? " on the server" : "") for you to remove with git worktree remove.")
        }
    }
}

/// Work on This: make (or open) the issue's session in the org's harness,
/// with a brief written from what Gannin knows about the issue and its plans
/// now. Claude works out which repos it touches.
struct StartSessionButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(IssueStore.self) private var issues
    @Environment(DetailStore.self) private var details
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow
    let reference: IssueReference
    /// While the harness commit is confirmed.
    @State private var confirming = false
    @AppStorage private var recordWithoutAsking: Bool

    init(reference: IssueReference) {
        self.reference = reference
        _recordWithoutAsking = AppStorage(wrappedValue: false, SessionStore.asksBeforeRecordingKey(reference.org))
    }

    var body: some View {
        if let existing = sessions.session(forIssue: reference.id) {
            Button {
                openWindow(value: SessionWindowID(id: existing.id))
            } label: {
                Label("Open Session", systemImage: "terminal")
            }
            .help("Show this issue's Claude Code session, in \(existing.repo)")
        } else {
            let blocked = unavailable
            Button {
                if recordWithoutAsking { start(recording: true) } else { confirming = true }
            } label: {
                Label("Work on This", systemImage: "terminal")
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Work on this issue with Claude Code, in the org's harness")
            .confirmationDialog("Record this session in the harness?", isPresented: $confirming) {
                Button("Commit to Harness") { start(recording: true) }
                Button("Don't Record") {
                    recordWithoutAsking = false
                    start(recording: false)
                }
                Button("Cancel", role: .cancel) { recordWithoutAsking = false }
            } message: {
                let harnessRepo = configs.config(for: reference.org).harness?.repo ?? "the harness"
                Text("Gannin commits \(SessionStore.harnessFolder(for: reference))/brief.md and session.json to \(harnessRepo), on its default branch, so the team can see the session and any box can start it. When Claude opens a pull request, it's added to session.json.")
            }
            .dialogSuppressionToggle("Don't ask again for \(reference.org)", isSuppressed: $recordWithoutAsking)
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

    private func start(recording: Bool) {
        let history = issues.history(for: reference.org)
        let record = history?.issues[reference.id]
        let parent = record?.parentID.flatMap { history?.issues[$0] }
        let detail = details.detail(for: reference.id)
        guard let setup = configs.config(for: reference.org).harness,
              let path = SessionStore.harnessPath(org: reference.org, repo: setup.repo) else { return }
        let index = harness.index(for: reference.org, setup)
        let session = sessions.start(reference, harness: setup, harnessPath: path) { session in
            SessionBrief.make(session: session, record: record, detail: detail, parent: parent, harness: index)
        }
        guard recording else {
            openWindow(value: SessionWindowID(id: session.id))
            return
        }
        // Committed before the terminal starts, so its pull brings the brief.
        let login = auth.viewer?.login
        Task {
            await sessions.record(session.id, startedBy: login)
            openWindow(value: SessionWindowID(id: session.id))
        }
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
    @AppStorage private var recordWithoutAsking: Bool
    let org: String
    let repo: String

    init(org: String, repo: String) {
        self.org = org
        self.repo = repo
        _localPath = AppStorage(wrappedValue: "", SessionStore.harnessPathKey(org))
        _remotePath = AppStorage(wrappedValue: "", SessionStore.remoteHarnessPathKey(org))
        _recordWithoutAsking = AppStorage(wrappedValue: false, SessionStore.asksBeforeRecordingKey(org))
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
            Toggle("Ask before recording a session", isOn: Binding(get: { !recordWithoutAsking }, set: { recordWithoutAsking = !$0 }))
            Text("Work on This commits the session's brief and a session.json to \(repo)'s sessions folder, and adds its pull request later. Off, it does so without asking.")
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
        panel.message = "Choose \(repo)'s checkout, or the folder to clone it into"
        panel.directoryURL = SessionStore.expanded(SessionStore.localHarnessPath(org: org, repo: repo)).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = SessionStore.tildePath(url)
    }
}
#endif
