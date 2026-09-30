#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftTerm

/// A Claude Code session on one issue, with claude running in a terminal
/// inside Gannin: in the org's harness checkout, the issue having its own
/// folder there (`.worktrees/<branch>/`) for a worktree of each repo it
/// touches, on a branch of its own.
struct CodeSession: Codable, Identifiable, Hashable {
    let id: UUID
    let issue: IssueReference
    /// `owner/name` of the repo the code is in, which needn't be the
    /// issue's: an org can keep its issues in a repo of their own. For a
    /// session in the harness, the harness itself, and claude works out the
    /// code repos.
    let repo: String
    /// A var so a name from an older build, with no worktree made yet, can
    /// be worked out again.
    var branch: String
    let createdAt: Date
    /// The PR claude opened, spotted in its `gh pr create`.
    var pullRequest: URL?
    /// The command that reaches the server it runs on (`ssh -t devbox`);
    /// nil for this Mac. Kept from when it was made, since that's where its
    /// worktree is.
    var connect: String? = nil
    /// The server's workspace, as a path there (`~/Gannin`), for sessions
    /// made before they ran in the harness.
    var remoteWorkspace: String? = nil
    /// The harness it runs in: `owner/name`, and its checkout on the box the
    /// session runs on (`~` allowed). Nil for sessions made before, which
    /// have one repo's worktree beside its clone in the workspace.
    var harnessRepo: String? = nil
    var harnessPath: String? = nil
    /// Its folder in the harness (`sessions/product-123`), once its brief
    /// and `session.json` are committed there; nil when they weren't.
    var harnessFolder: String? = nil

    var isRemote: Bool { connect != nil }
    var isInHarness: Bool { harnessPath != nil && harnessRepo != nil }

    var org: String { issue.org }
    /// Claude Code wants its session IDs in lower case.
    var claudeID: String { id.uuidString.lowercased() }
    /// How the PR should refer to the issue: with its repo when that's
    /// another one, so GitHub still links them.
    var closingReference: String { repo == issue.repo ? "#\(issue.number)" : issue.reference }
}

extension CodeSession {
    /// Sessions saved before `repo` worked in the issue's repo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        issue = try container.decode(IssueReference.self, forKey: .issue)
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? issue.repo
        branch = try container.decode(String.self, forKey: .branch)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pullRequest = try container.decodeIfPresent(URL.self, forKey: .pullRequest)
        connect = try container.decodeIfPresent(String.self, forKey: .connect)
        remoteWorkspace = try container.decodeIfPresent(String.self, forKey: .remoteWorkspace)
        harnessRepo = try container.decodeIfPresent(String.self, forKey: .harnessRepo)
        harnessPath = try container.decodeIfPresent(String.self, forKey: .harnessPath)
        harnessFolder = try container.decodeIfPresent(String.self, forKey: .harnessFolder)
    }
}

extension IssueReference {
    /// `owner/name#123`, as a plain string so the number isn't grouped.
    var reference: String { "\(repo)#\(number)" }
}

/// A session as the harness keeps it, in `sessions/<repo>-<number>/session.json`
/// beside its brief, so the team can see who's working on what, where.
struct SessionRecord: Codable {
    var issue: String
    var title: String
    var url: URL
    /// The code repos it has worktrees for.
    var repos: [String]
    var branch: String
    var startedBy: String?
    var startedAt: Date
    /// Where it runs: this Mac's name, or the Connect with command.
    var box: String
    var pullRequests: [URL]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var json: String { String(decoding: (try? Self.encoder.encode(self)) ?? Data(), as: UTF8.self) + "\n" }
}

/// A session's own window, by ID.
struct SessionWindowID: Codable, Hashable {
    let id: UUID
}

/// What a session's claude is doing, as its hooks last said.
enum SessionState: String {
    /// Cloning, making the worktree, or starting claude.
    case starting
    case working
    /// A permission prompt or a question: claude is waiting on you.
    case needsYou = "needs-you"
    /// Claude finished its turn.
    case idle
    /// Claude has exited; the shell is still open in the worktree.
    case exited
    /// Nothing is running: the terminal ended, or Gannin was quit.
    case stopped

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .idle: "Your turn"
        case .exited: "Claude exited"
        case .stopped: "Stopped"
        }
    }
}

/// Every Claude Code session, kept across launches so a session can be
/// resumed (`claude --resume`) in its worktree. The terminals live here, not
/// in the windows, so closing a session's window leaves claude running.
///
/// Each session has a folder holding its brief, the hooks claude reports
/// through (they write its state to a file, read here every second while
/// anything runs) and the script its terminal runs: clone or pull the
/// harness, clone the repo into its `projects/` if it isn't yet, add the
/// worktree under `.worktrees/`, copy the brief in, then start or resume
/// claude.
@Observable
final class SessionStore {
    /// Where Gannin clones a harness that isn't checked out on this Mac yet,
    /// as a path (`~` allowed).
    static let workspaceKey = "sessionsWorkspace"
    static let defaultWorkspace = "~/Gannin"
    /// Run sessions on a server: the command that gets there, such as
    /// `ssh -t devbox`, with `{command}` where the rest goes (else at the
    /// end). Empty runs them on this Mac.
    static let connectKey = "sessionsConnect"

    static var connectCommand: String? {
        let command = (UserDefaults.standard.string(forKey: connectKey) ?? "").trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }

    /// The org's harness checkout on this Mac, as set in its Settings.
    static func harnessPathKey(_ org: String) -> String { "sessionsHarnessPath.\(org)" }
    /// And on the server, which has no default: only you know that box.
    static func remoteHarnessPathKey(_ org: String) -> String { "sessionsRemoteHarnessPath.\(org)" }

    /// The harness checkout on this Mac: the one set, else a checkout you
    /// already have, else `<workspace>/<org>-harness` for Gannin to clone.
    static func localHarnessPath(org: String, repo: String) -> String {
        let saved = (UserDefaults.standard.string(forKey: harnessPathKey(org)) ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return existingCheckout(of: repo) ?? defaultHarnessPath(org: org)
    }

    static func defaultHarnessPath(org: String) -> String {
        let workspace = UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace
        return workspace + "/\(org)-harness"
    }

    static func remoteHarnessPath(org: String) -> String? {
        let path = (UserDefaults.standard.string(forKey: remoteHarnessPathKey(org)) ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// Where new sessions for the org run their harness: on the server when
    /// there's a Connect with command, else on this Mac. Nil when that's the
    /// server and its checkout hasn't been set.
    static func harnessPath(org: String, repo: String) -> String? {
        connectCommand == nil ? localHarnessPath(org: org, repo: repo) : remoteHarnessPath(org: org)
    }

    /// A checkout of the repo in one of the usual places, found by its
    /// origin: `~/Code/<owner>/<name>` (as Ctrl Hub keeps its harness), and
    /// the like.
    static func existingCheckout(of repo: String) -> String? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let (owner, name) = (parts[0], parts[1])
        let candidates = ["Code", "Developer", "Projects", "src", "code", "dev"]
            .flatMap { ["~/\($0)/\(owner)/\(name)", "~/\($0)/\(name)"] }
            + ["~/\(owner)/\(name)", "~/\(name)", defaultWorkspace + "/\(owner)/\(name)"]
        return candidates.first { candidate in
            let config = URL(filePath: (candidate as NSString).expandingTildeInPath).appending(path: ".git/config")
            guard let text = (try? String(contentsOf: config, encoding: .utf8))?.lowercased() else { return false }
            let target = "\(owner)/\(name)".lowercased()
            return text.contains("github.com/\(target)") || text.contains("github.com:\(target)")
        }
    }

    /// Whether Work on This asks before committing a session's brief and
    /// record to the org's harness; off once "Don't ask again" is ticked.
    static func asksBeforeRecordingKey(_ org: String) -> String { "sessionsRecordWithoutAsking.\(org)" }

    private(set) var sessions: [UUID: CodeSession] = [:]
    private(set) var states: [UUID: SessionState] = [:]
    /// Why a session's last commit to the harness failed, to show on it.
    private(set) var recordErrors: [UUID: String] = [:]
    @ObservationIgnored private var terminals: [UUID: SessionTerminal] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let harness: HarnessStore

    init(harness: HarnessStore) {
        self.harness = harness
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([CodeSession].self, from: data) {
            sessions = Dictionary(uniqueKeysWithValues: saved.map { session in
                var session = session
                if !session.isRemote, let worktree = Self.worktree(for: session), !FileManager.default.fileExists(atPath: worktree.path) {
                    session.branch = Self.branchName(session.issue)
                }
                return (session.id, session)
            })
        }
    }

    func sessions(for org: String) -> [CodeSession] {
        sessions.values.filter { $0.org == org }.sorted { $0.createdAt > $1.createdAt }
    }

    func session(forIssue id: String) -> CodeSession? {
        sessions.values.first { $0.issue.id == id }
    }

    func state(_ id: UUID) -> SessionState { states[id] ?? .stopped }

    /// The issue's session, made in the harness checkout at `harnessPath` if
    /// it has none, with its brief written afresh from what Gannin knows now.
    func start(_ issue: IssueReference, harness: HarnessConfig, harnessPath: String, brief: (CodeSession) -> String) -> CodeSession {
        let session = session(forIssue: issue.id)
            ?? CodeSession(
                id: UUID(), issue: issue, repo: harness.repo, branch: Self.branchName(issue), createdAt: .now,
                connect: Self.connectCommand, harnessRepo: harness.repo, harnessPath: harnessPath
            )
        sessions[session.id] = session
        save()
        let directory = Self.directory(for: session.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(brief(session).utf8).write(to: directory.appending(path: "brief.md"))
        return session
    }

    // MARK: In the harness

    /// `sessions/<repo>-<number>`, by the issue's repo, whose number it is.
    static func harnessFolder(for issue: IssueReference) -> String {
        let name = issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo
        return "sessions/\(name)-\(issue.number)"
    }

    /// Commits the session's brief and `session.json` to the harness's
    /// default branch, so its checkout on any box has them. Confirmed by the
    /// caller. The session keeps where they went, so its PR is added later
    /// and a server session reads its brief from the harness.
    func record(_ id: UUID, startedBy: String?) async {
        guard let session = sessions[id], let repo = session.harnessRepo else { return }
        let folder = Self.harnessFolder(for: session.issue)
        let brief = (try? String(contentsOf: Self.directory(for: id).appending(path: "brief.md"), encoding: .utf8)) ?? ""
        let record = SessionRecord(
            issue: session.issue.reference, title: session.issue.title, url: session.issue.url,
            repos: session.isInHarness ? [] : [session.repo], branch: session.branch, startedBy: startedBy, startedAt: session.createdAt,
            box: session.connect ?? (Host.current().localizedName ?? "Mac"), pullRequests: session.pullRequest.map { [$0] } ?? []
        )
        do {
            try await harness.commit(org: session.org, setup: HarnessConfig(repo: repo), refreshing: false) { _ in
                HarnessChange(
                    message: "Gannin: session on \(session.issue.reference)\n\n\(session.issue.title), on \(session.branch).",
                    files: ["\(folder)/brief.md": brief, "\(folder)/session.json": record.json]
                )
            }
            sessions[id]?.harnessFolder = folder
            recordErrors[id] = nil
            save()
        } catch {
            recordErrors[id] = error.localizedDescription
        }
    }

    /// Adds the PR claude opened to the session's `session.json`, on top of
    /// whatever the harness has now.
    private func recordPullRequest(_ url: URL, for id: UUID) {
        guard let session = sessions[id], let repo = session.harnessRepo, let folder = session.harnessFolder else { return }
        let setup = HarnessConfig(repo: repo)
        let path = "\(folder)/session.json"
        Task {
            do {
                try await harness.commit(org: session.org, setup: setup, refreshing: false) { head in
                    let text = try await self.harness.files(setup: setup, at: head, paths: [path])[path] ?? nil
                    guard let text, var record = try? SessionRecord.decoder.decode(SessionRecord.self, from: Data(text.utf8)) else { return nil }
                    guard !record.pullRequests.contains(url) else { return nil }
                    record.pullRequests.append(url)
                    return HarnessChange(message: "Gannin: \(session.issue.reference) has a pull request\n\n\(url.absoluteString)", files: [path: record.json])
                }
                recordErrors[id] = nil
            } catch {
                recordErrors[id] = error.localizedDescription
            }
        }
    }

    // MARK: Terminals

    /// The view the session's terminal draws in, launching it if nothing is
    /// running. Call from an event or `onAppear`, not from a view's body.
    func open(_ session: CodeSession) -> NSView {
        let terminal = terminals[session.id] ?? SessionTerminal { [weak self] in
            self?.terminated(session.id)
        } onSignal: { [weak self] signal in
            self?.received(signal, for: session.id)
        }
        terminals[session.id] = terminal
        if !terminal.isRunning { launch(session, in: terminal) }
        return terminal.container
    }

    /// The session's terminal, if it has been opened since launch.
    func terminal(_ id: UUID) -> SessionTerminal? { terminals[id] }

    func isRunning(_ id: UUID) -> Bool { terminals[id]?.isRunning == true }

    /// Ends claude and the shell it runs in. The worktree stays.
    func end(_ id: UUID) {
        terminals[id]?.terminate()
    }

    /// Ends the session and forgets it. The clone and worktree stay on disk.
    func remove(_ id: UUID) {
        terminals[id]?.terminate()
        terminals[id] = nil
        sessions[id] = nil
        states[id] = nil
        save()
        try? FileManager.default.removeItem(at: Self.directory(for: id))
    }

    private func launch(_ session: CodeSession, in terminal: SessionTerminal) {
        let directory = Self.directory(for: session.id)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(SessionState.starting.rawValue.utf8).write(to: directory.appending(path: "state"))
        states[session.id] = .starting

        // What the login shell runs: the script here, or the Connect with
        // command carrying it to the server.
        let command: String
        if let connect = session.connect {
            let remoteDirectory = #""$HOME"/.gannin/sessions/"# + session.id.uuidString
            // A brief in the harness comes with its pull; only one that
            // isn't travels in the command.
            let brief = session.harnessFolder == nil ? (try? String(contentsOf: directory.appending(path: "brief.md"), encoding: .utf8)) ?? "" : nil
            let remote = SessionScript.remoteCommand(
                directory: remoteDirectory,
                script: SessionScript.start(session, root: SessionScript.shellPath(session.harnessPath ?? session.remoteWorkspace ?? Self.defaultWorkspace), directory: remoteDirectory),
                brief: brief,
                settings: SessionScript.settings(directory: remoteDirectory)
            )
            command = SessionScript.connecting(connect, to: remote)
        } else {
            let root = session.harnessPath.map(Self.expanded) ?? Self.workspaceRoot
            // The harness is cloned into it, when it isn't there yet.
            try? fm.createDirectory(at: session.harnessPath == nil ? root : root.deletingLastPathComponent(), withIntermediateDirectories: true)
            let local = SessionScript.quoted(directory.path)
            try? Data(SessionScript.settings(directory: local).utf8).write(to: directory.appending(path: "settings.json"))
            let script = directory.appending(path: "start.sh")
            try? Data(SessionScript.start(session, root: SessionScript.quoted(root.path), directory: local).utf8).write(to: script)
            command = "bash \(SessionScript.quoted(script.path))"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Gannin started from inside a Claude Code session (a build and run,
        // say) inherits its markers, and claude then won't save transcripts,
        // so there'd be nothing to resume.
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            environment[key] = nil
        }
        // Your login, interactive shell, so the PATH, ssh config and tools
        // are yours.
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        terminal.launch(
            executable: shell,
            args: ["-l", "-i", "-c", command],
            environment: environment.map { "\($0.key)=\($0.value)" },
            directory: session.isRemote || session.harnessPath != nil ? FileManager.default.homeDirectoryForCurrentUser.path : Self.workspaceRoot.path
        )
        startPolling()
    }

    /// What a hook sent through the terminal: `state:working`, `pr:<url>`.
    private func received(_ signal: String, for id: UUID) {
        if signal.hasPrefix("state:"), let state = SessionState(rawValue: String(signal.dropFirst(6))) {
            if states[id] != state { states[id] = state }
        } else if signal.hasPrefix("pr:"), sessions[id]?.pullRequest == nil,
                  let url = URL(string: String(signal.dropFirst(3))), url.scheme == "https" {
            opened(url, for: id)
        }
    }

    /// Claude's `gh pr create`, spotted by a hook.
    private func opened(_ url: URL, for id: UUID) {
        sessions[id]?.pullRequest = url
        save()
        recordPullRequest(url, for: id)
    }

    private func terminated(_ id: UUID) {
        states[id] = .stopped
    }

    // MARK: Hook state

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.poll() else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.polling = nil
        }
    }

    /// Reads what the running sessions' hooks wrote. False once nothing runs.
    private func poll() -> Bool {
        var anyRunning = false
        for (id, terminal) in terminals where terminal.isRunning {
            anyRunning = true
            let directory = Self.directory(for: id)
            if let raw = try? String(contentsOf: directory.appending(path: "state"), encoding: .utf8),
               let state = SessionState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               states[id] != state {
                states[id] = state
            }
            if sessions[id]?.pullRequest == nil,
               let raw = try? String(contentsOf: directory.appending(path: "pr"), encoding: .utf8),
               let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" {
                opened(url, for: id)
            }
        }
        return anyRunning
    }

    // MARK: Places

    static var workspaceRoot: URL {
        expanded(UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace)
    }

    /// A folder as a path to keep: under your home as `~/Code/x`.
    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func expanded(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// Where the session's work is on its box, as a path there: in the
    /// harness, the issue's folder `<harness>/.worktrees/<branch>`, holding a
    /// worktree per repo; before that, one repo's worktree beside its clone,
    /// `<workspace>/<owner>/<name>.worktrees/<branch>`.
    static func worktreePath(for session: CodeSession) -> String {
        if let harness = session.harnessPath {
            return "\(harness)/.worktrees/\(session.branch)"
        }
        let workspace = session.remoteWorkspace ?? (UserDefaults.standard.string(forKey: workspaceKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultWorkspace)
        return "\(workspace)/\(session.repo).worktrees/\(session.branch)"
    }

    /// The worktree on this Mac; nil for a session on a server.
    static func worktree(for session: CodeSession) -> URL? {
        session.isRemote ? nil : expanded(worktreePath(for: session))
    }

    /// `123-short-title`, from the issue's number and title.
    static func branchName(_ issue: IssueReference) -> String {
        let words = String(issue.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
            .split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 40 { break }
            slug = next
        }
        return slug.isEmpty ? "issue-\(issue.number)" : "\(issue.number)-\(slug)"
    }

    /// Gannin's own folder, so the unsandboxed app doesn't write loose into
    /// the shared Application Support.
    private static var baseDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.getgannin", directoryHint: .isDirectory)
            .appending(path: "Sessions", directoryHint: .isDirectory)
    }

    static func directory(for id: UUID) -> URL {
        baseDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static var fileURL: URL { baseDirectory.appending(path: "Sessions.json") }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.baseDirectory, withIntermediateDirectories: true)
        let ordered = sessions.values.sorted { $0.createdAt < $1.createdAt }
        if let data = try? JSONEncoder().encode(ordered) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// One session's terminal: a container that stays put while the terminal
/// view inside it is replaced on each launch.
final class SessionTerminal: NSObject, LocalProcessTerminalViewDelegate {
    let container = NSView()
    private(set) var view: LocalProcessTerminalView?
    private(set) var isRunning = false
    private let onTerminate: () -> Void
    private let onSignal: (String) -> Void

    init(onTerminate: @escaping () -> Void, onSignal: @escaping (String) -> Void) {
        self.onTerminate = onTerminate
        self.onSignal = onSignal
    }

    func launch(executable: String, args: [String], environment: [String], directory: String) {
        view?.removeFromSuperview()
        let view = LocalProcessTerminalView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.processDelegate = self
        // The hooks' state, sent as an escape code so it reaches here from
        // a server too. SwiftTerm parses on the main queue.
        let onSignal = onSignal
        view.terminal.registerOscHandler(code: SessionScript.signalCode) { data in
            let text = String(decoding: data, as: UTF8.self)
            MainActor.assumeIsolated { onSignal(text) }
        }
        container.addSubview(view)
        self.view = view
        isRunning = true
        view.startProcess(executable: executable, args: args, environment: environment, execName: "zsh", currentDirectory: directory)
        focus()
    }

    func terminate() {
        guard isRunning else { return }
        view?.terminate()
    }

    /// Puts the keyboard in the terminal.
    func focus() {
        guard let view else { return }
        Task { @MainActor in view.window?.makeFirstResponder(view) }
    }

    // SwiftTerm calls these on the main queue.

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ended = ObjectIdentifier(source)
        MainActor.assumeIsolated {
            // Only the current launch's end counts.
            guard view.map(ObjectIdentifier.init) == ended else { return }
            isRunning = false
            onTerminate()
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
#endif
