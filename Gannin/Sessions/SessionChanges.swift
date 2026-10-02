import Foundation
import Observation

/// A file a session has changed in one of its worktrees.
nonisolated struct ChangedFile: Identifiable, Hashable, Sendable {
    nonisolated enum Status: String, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case untracked = "?"
    }

    /// The worktree's path, then the file's within it.
    let worktree: String
    let path: String
    let status: Status
    /// Nil for a binary file.
    let added: Int?
    let removed: Int?
    /// In the index, ready to commit.
    var isStaged = false

    var id: String { worktree + "\n" + path }
}

/// One worktree's changes since the branch left its base.
nonisolated struct WorktreeChanges: Identifiable, Hashable, Sendable {
    let path: String
    /// The repo's folder name (`api`), for the list.
    let name: String
    /// What it's compared with: the merge base with `origin/HEAD`, else
    /// `HEAD` (uncommitted changes only).
    let base: String
    let baseLabel: String
    let files: [ChangedFile]
    /// Commits not on its upstream yet; nil before it's been pushed.
    var unpushed: Int? = nil
    var hasUpstream = false

    var id: String { path }
}

/// A line of a file's diff, coloured by what it is, with its numbers in the
/// file before and after.
nonisolated struct DiffLine: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Sendable { case added, removed, hunk, context, note }
    let id: Int
    let kind: Kind
    let text: String
    var oldLine: Int? = nil
    var newLine: Int? = nil

    /// The line a comment on it points at: the new file's, else the old's
    /// for a removed line.
    var anchor: (line: Int, isOld: Bool)? {
        if let newLine { return (newLine, false) }
        if let oldLine { return (oldLine, true) }
        return nil
    }
}

/// A comment on a line of a session's diff, waiting to be sent to claude.
struct DiffComment: Identifiable, Hashable {
    let id = UUID()
    /// The worktree's path, and its folder's name (the repo's).
    let worktree: String
    let worktreeName: String
    let path: String
    let line: Int
    /// On a removed line, numbered as the file was.
    let isOld: Bool
    let code: String
    let body: String

    func matches(_ file: ChangedFile, _ line: DiffLine) -> Bool {
        guard file.worktree == worktree, file.path == path, let anchor = line.anchor else { return false }
        return anchor.line == self.line && anchor.isOld == isOld
    }
}

/// A session's changes, read with git while its tab shows: every worktree
/// under the issue's folder (or the one worktree of an older session),
/// committed and not, against where the branch started. One small script
/// reads them all, run here with bash or, for a session on a server, through
/// its Connect with command over one shared ssh connection.
@Observable
final class SessionChanges {
    enum Mode: String, CaseIterable, Identifiable {
        /// Everything since the branch left the default branch.
        case branch
        /// What isn't committed yet: to stage, discard and commit.
        case uncommitted

        var id: String { rawValue }
        var title: String { self == .branch ? "Branch" : "Uncommitted" }
    }

    var mode: Mode = .branch {
        didSet { if mode != oldValue { worktrees = []; diff = []; loaded = false } }
    }
    private(set) var worktrees: [WorktreeChanges] = []
    /// The selected file's diff header, for making a patch of one hunk.
    private(set) var diffHeader: [String] = []
    @ObservationIgnored private var runner: Runner?
    private(set) var loaded = false
    /// Why the last read failed: ssh couldn't connect, say.
    private(set) var error: String?
    var selected: ChangedFile.ID? {
        didSet { if selected != oldValue { diff = [] } }
    }
    private(set) var diff: [DiffLine] = []
    /// Shown lines stop here, so a huge file doesn't stall the view.
    nonisolated static let lineLimit = 4000
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false

    var fileCount: Int { worktrees.reduce(0) { $0 + $1.files.count } }

    var selectedFile: ChangedFile? {
        guard let selected else { return nil }
        return worktrees.lazy.flatMap(\.files).first { $0.id == selected }
    }

    /// Reads the changes again, and the selected file's diff. A call while
    /// one runs makes it read once more when done, rather than both running.
    func refresh(_ session: CodeSession) async {
        guard !refreshing else {
            again = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            again = false
            await read(session)
        } while again
    }

    /// How to run git where the session is: here, or over ssh.
    static func runner(for session: CodeSession) -> Runner? {
        guard let connect = session.connect else { return .local }
        return sshArguments(connect).map { .ssh($0) }
    }

    private func read(_ session: CodeSession) async {
        guard let runner = Self.runner(for: session) else {
            error = "Changes on a server are read over ssh, and this session connects with \(session.connect ?? "")."
            loaded = true
            return
        }
        self.runner = runner
        let folder = SessionStore.worktreePath(for: session)
        let inHarness = session.isInHarness
        let mode = mode
        let list = Self.listScript(folder: SessionScript.shellPath(folder), inHarness: inHarness, uncommitted: mode == .uncommitted)
        let result = await Task.detached { Self.run(list, runner) }.value
        loaded = true
        guard result.ok else {
            error = result.error.isEmpty ? "Couldn't read the changes." : result.error
            return
        }
        error = nil
        // Switched while git ran: that read is for the other mode.
        guard mode == self.mode else { return }
        let found = Self.parse(result.output, folder: folder, inHarness: inHarness)
        if found != worktrees { worktrees = found }

        guard let file = selectedFile, let worktree = worktrees.first(where: { $0.path == file.worktree }) else {
            // The file was reverted.
            if selected != nil { selected = nil }
            return
        }
        let script = Self.diffScript(file, worktree: SessionScript.shellPath(worktree.path), base: worktree.base)
        let output = await Task.detached { Self.run(script, runner) }.value.output
        let (lines, header) = await Task.detached { Self.lines(of: output) }.value
        // The selection may have moved on while git ran.
        if selectedFile?.id == file.id, lines != diff {
            diff = lines
            diffHeader = header
        }
    }

    // MARK: Changing them

    /// Runs git in the file's worktree, then reads everything again.
    private func git(_ command: String, in worktree: String, session: CodeSession) async -> String? {
        guard let runner = runner ?? Self.runner(for: session) else { return "Not reachable from here." }
        let script = """
            cd \(SessionScript.shellPath(worktree)) || exit 1
            \(command)
            """
        let result = await Task.detached { Self.run(script, runner) }.value
        await refresh(session)
        return result.ok ? nil : (result.error.isEmpty ? "git didn't do it." : result.error)
    }

    func stage(_ file: ChangedFile, session: CodeSession) async -> String? {
        await git("git add -- \(SessionScript.quoted(file.path))", in: file.worktree, session: session)
    }

    func unstage(_ file: ChangedFile, session: CodeSession) async -> String? {
        await git("git restore --staged -- \(SessionScript.quoted(file.path))", in: file.worktree, session: session)
    }

    /// Back to the last commit, or gone for a new file.
    func discard(_ file: ChangedFile, session: CodeSession) async -> String? {
        let path = SessionScript.quoted(file.path)
        let command = file.status == .untracked ? "rm -f -- \(path)" : "git restore --source=HEAD --staged --worktree -- \(path)"
        return await git(command, in: file.worktree, session: session)
    }

    /// Undoes one hunk of an uncommitted diff, from the hunk's header line.
    func discardHunk(at hunk: DiffLine.ID, session: CodeSession) async -> String? {
        guard mode == .uncommitted, let file = selectedFile, file.status != .untracked,
              let start = diff.firstIndex(where: { $0.id == hunk }), diff[start].kind == .hunk, !diffHeader.isEmpty else { return nil }
        var patch = diffHeader + [diff[start].text]
        for line in diff[(start + 1)...] {
            if line.kind == .hunk { break }
            patch.append(line.text)
        }
        let encoded = Data((patch.joined(separator: "\n") + "\n").utf8).base64EncodedString()
        return await git("printf %s \(encoded) | base64 -d | git apply -R -", in: file.worktree, session: session)
    }

    /// Commits what's staged in the worktree.
    func commit(_ worktree: WorktreeChanges, message: String, session: CodeSession) async -> String? {
        await git("git commit -m \(SessionScript.quoted(message))", in: worktree.path, session: session)
    }

    func push(_ worktree: WorktreeChanges, session: CodeSession) async -> String? {
        await git(worktree.hasUpstream ? "git push" : "git push -u origin HEAD", in: worktree.path, session: session)
    }

    // MARK: Scripts

    /// Prints each worktree's base and changes, in sections marked with a
    /// record separator (`\036`): its name, base and base's name, then
    /// `--name-status`, `--numstat` and the untracked files with their line
    /// counts (`-` for binary). Git takes no optional locks, so claude's own
    /// git never finds the index locked.
    private static func listScript(folder: String, inHarness: Bool, uncommitted: Bool) -> String {
        let base = uncommitted
            ? "base=HEAD; label="
            : "if base=$(g merge-base HEAD origin/HEAD); then label=$(g rev-parse --abbrev-ref origin/HEAD); else base=HEAD; label=; fi"
        let each = inHarness
            ? #"for d in */; do d=${d%/}; [ -e "$d/.git" ] && (cd "$d" && report "$d"); done"#
            : #"[ -e .git ] && report ."#
        return """
            export GIT_OPTIONAL_LOCKS=0
            cd \(folder) 2>/dev/null || exit 0
            g() { git -c core.quotepath=off --no-pager "$@" 2>/dev/null; }
            report() {
              printf '\\036worktree\\t%s\\n' "$1"
              \(base)
              printf '\\036base\\t%s\\t%s\\n' "$base" "$label"
              if up=$(g rev-list --count @{u}..HEAD); then printf '\\036push\\t%s\\n' "$up"; else printf '\\036push\\t-\\n'; fi
              printf '\\036staged\\n'; g diff --cached --no-renames --name-only
              printf '\\036status\\n'; g diff --no-renames --name-status "$base"
              printf '\\036numstat\\n'; g diff --no-renames --numstat "$base"
              printf '\\036untracked\\n'
              g ls-files --others --exclude-standard | while IFS= read -r f; do
                if [ -s "$f" ] && ! grep -Iq . "$f"; then printf -- '-\\t%s\\n' "$f"
                else printf '%s\\t%s\\n' "$(wc -l < "$f" | tr -d ' ')" "$f"; fi
              done
            }
            \(each)
            exit 0
            """
    }

    private static func diffScript(_ file: ChangedFile, worktree: String, base: String) -> String {
        let path = SessionScript.quoted(file.path)
        let diff = file.status == .untracked
            ? "diff --no-index -- /dev/null \(path)"
            : "diff --no-renames \(SessionScript.quoted(base)) -- \(path)"
        return """
            export GIT_OPTIONAL_LOCKS=0
            cd \(worktree) || exit 1
            git -c core.quotepath=off --no-pager \(diff)
            exit 0
            """
    }

    // MARK: Running, off the main thread

    nonisolated enum Runner: Sendable {
        case local
        /// ssh's arguments, the remote command still to add.
        case ssh([String])
    }

    /// The Connect with command as ssh's arguments for running a command
    /// with no terminal: `-t` dropped, never prompting, and the connection
    /// shared between reads (`ControlMaster`), so each is a few milliseconds
    /// once the first has connected. Nil when it isn't ssh.
    static func sshArguments(_ connect: String) -> [String]? {
        var words = connect.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first == "ssh" || first.hasSuffix("/ssh") else { return nil }
        words.removeFirst()
        words.removeAll { $0 == "-t" || $0 == "-tt" }
        let options = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            // Short, as a socket's path must be.
            "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/gannin-ssh-%C", "-o", "ControlPersist=120",
        ]
        return [first] + options + words
    }

    /// Runs the script with bash, here or over ssh, where it travels as
    /// base64 so no quoting can break it.
    nonisolated struct ShellResult: Sendable {
        let ok: Bool
        let data: Data
        let error: String

        var output: String { String(decoding: data, as: UTF8.self) }
    }

    nonisolated static func run(_ script: String, _ runner: Runner) -> ShellResult {
        let process = Process()
        switch runner {
        case .local:
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = ["-c", script]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        case .ssh(var arguments):
            let ssh = arguments.removeFirst()
            let remote = #"bash -c "$(printf %s "# + Data(script.utf8).base64EncodedString() + #" | base64 -d)""#
            if let index = arguments.firstIndex(of: "{command}") {
                arguments[index] = remote
            } else {
                arguments.append(remote)
            }
            process.executableURL = URL(filePath: ssh.hasPrefix("/") ? ssh : "/usr/bin/ssh")
            process.arguments = arguments
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ShellResult(ok: false, data: Data(), error: error.localizedDescription) }
        // Read before waiting, so a big diff can't fill the pipe and stall.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errorData, as: UTF8.self)
            .split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return ShellResult(ok: process.terminationStatus == 0, data: data, error: message)
    }

    // MARK: Parsing

    private static func parse(_ output: String, folder: String, inHarness: Bool) -> [WorktreeChanges] {
        var worktrees: [WorktreeChanges] = []
        var name = "", base = "HEAD", label = ""
        var unpushed: Int?
        var hasUpstream = false
        var staged: Set<String> = []
        var section = ""
        var statuses: [String: ChangedFile.Status] = [:]
        var files: [ChangedFile] = []
        var path: String { inHarness ? "\(folder)/\(name)" : folder }

        func finish() {
            guard !name.isEmpty else { return }
            files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let baseLabel = base == "HEAD" ? "the last commit" : label.isEmpty ? "the default branch" : label
            let shown = inHarness ? name : ((folder as NSString).lastPathComponent)
            for index in files.indices { files[index].isStaged = staged.contains(files[index].path) }
            worktrees.append(WorktreeChanges(path: path, name: shown, base: base, baseLabel: baseLabel, files: files, unpushed: unpushed, hasUpstream: hasUpstream))
            statuses = [:]
            files = []
            staged = []
            unpushed = nil
            hasUpstream = false
        }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("\u{1E}") {
                let parts = line.dropFirst().split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                switch parts.first {
                case "worktree":
                    finish()
                    name = parts.count > 1 ? parts[1] : ""
                    base = "HEAD"
                    label = ""
                case "base":
                    base = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "HEAD"
                    label = parts.count > 2 ? parts[2] : ""
                case "push":
                    let value = parts.count > 1 ? parts[1] : "-"
                    hasUpstream = value != "-"
                    unpushed = Int(value)
                default:
                    section = parts.first ?? ""
                }
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: section == "numstat" ? 2 : 1).map(String.init)
            switch section {
            case "staged":
                staged.insert(String(line))
            case "status" where parts.count == 2:
                statuses[parts[1]] = ChangedFile.Status(rawValue: String(parts[0].prefix(1))) ?? .modified
            case "numstat" where parts.count == 3:
                files.append(ChangedFile(worktree: path, path: parts[2], status: statuses[parts[2]] ?? .modified, added: Int(parts[0]), removed: Int(parts[1])))
            case "untracked" where parts.count == 2:
                let lines = Int(parts[0])
                files.append(ChangedFile(worktree: path, path: parts[1], status: .untracked, added: lines, removed: lines == nil ? nil : 0))
            default:
                break
            }
        }
        finish()
        return worktrees
    }

    /// The diff's lines, numbered, and its header (for a patch of a hunk).
    nonisolated static func lines(of output: String) -> ([DiffLine], [String]) {
        var lines: [DiffLine] = []
        var header: [String] = []
        var inHeader = true
        var old = 0, new = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHeader = false
                // `@@ -12,7 +12,9 @@`: where each side's lines start.
                let ranges = line.split(separator: " ").dropFirst().prefix(2)
                for range in ranges {
                    let start = Int(range.dropFirst().split(separator: ",").first ?? "") ?? 0
                    if range.hasPrefix("-") { old = start } else if range.hasPrefix("+") { new = start }
                }
            }
            let kind: DiffLine.Kind
            if inHeader {
                // The file's header says nothing the list doesn't, except
                // for a binary file.
                guard line.hasPrefix("Binary files") else {
                    if !line.isEmpty { header.append(line) }
                    continue
                }
                kind = .note
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else if line.hasPrefix("\\") {
                kind = .note
            } else {
                kind = .context
            }
            if lines.count == lineLimit {
                lines.append(DiffLine(id: lines.count, kind: .note, text: "Only the first \(lineLimit) lines are shown."))
                break
            }
            var numbered = DiffLine(id: lines.count, kind: kind, text: line)
            switch kind {
            case .added:
                numbered.newLine = new
                new += 1
            case .removed:
                numbered.oldLine = old
                old += 1
            case .context:
                numbered.oldLine = old
                numbered.newLine = new
                old += 1
                new += 1
            default:
                break
            }
            lines.append(numbered)
        }
        if lines.last?.kind == .context, lines.last?.text.isEmpty == true { lines.removeLast() }
        return (lines, header)
    }
}
