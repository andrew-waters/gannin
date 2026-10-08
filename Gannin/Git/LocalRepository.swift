import AppKit
import Observation

/// A binary file's sizes before and after, and the pictures when it's an
/// image.
nonisolated struct BinaryChange: Hashable, Sendable {
    var oldSize: Int?
    var newSize: Int?
    var oldImage: Data?
    var newImage: Data?
}

/// One repo's clone on this Mac, read and changed with the git CLI: its
/// status, branches, worktrees and tags, and the selected file's diff. The
/// page works in one worktree at a time (`path`), the clone itself until
/// another is picked. Everything runs as you, with your git config, hooks,
/// signing and credentials, and nothing can prompt.
@Observable
final class LocalRepository {
    /// `owner/name`.
    let repo: String
    /// The clone: the main worktree.
    let root: String
    /// The worktree the page works in.
    private(set) var path: String
    private(set) var snapshot: GitSnapshot?
    /// Tags on origin by name, read when the tags are looked at.
    private(set) var remoteTags: Set<String>?
    private(set) var loaded = false
    /// Why the last read failed.
    private(set) var error: String?
    /// What's running, as a word for the toolbar: Fetching, Pushing.
    private(set) var busy: String?
    private(set) var lastFetched: Date?
    /// Why the last background fetch failed, shown quietly.
    private(set) var fetchError: String?

    var selected: GitFileChange.ID? {
        didSet {
            if selected != oldValue {
                diff = []
                diffHeader = []
                binary = nil
            }
        }
    }
    private(set) var diff: [DiffLine] = []
    private(set) var diffHeader: [String] = []
    private(set) var binary: BinaryChange?
    /// Reading the diff with whitespace ignored: easier to read, but its
    /// hunks wouldn't apply, so they can't be staged.
    var ignoresWhitespace = false {
        didSet { if ignoresWhitespace != oldValue { diff = []; Task { await refresh() } } }
    }

    // What the page is asking about, set by the toolbar and its parts.
    /// A switch to this branch, waiting on what to do with the changes.
    var switching: GitBranch?
    var creatingBranch: CreateBranchRequest?
    var creatingWorktree: CreateWorktreeRequest?
    var creatingTag: CreateTagRequest?
    var actionError: String?
    /// A pull git wouldn't do without being told to merge or rebase.
    var reconciling = false
    var confirmingForcePush = false

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false

    init(repo: String, root: String, worktree: String? = nil) {
        self.repo = repo
        self.root = root
        path = worktree ?? root
    }

    var status: GitStatus? { snapshot?.status }
    var branches: [GitBranch] { snapshot?.branches ?? [] }
    var worktrees: [GitWorktree] { snapshot?.worktrees ?? [] }
    var tags: [GitTag] { snapshot?.tags ?? [] }

    var selectedFile: GitFileChange? {
        guard let selected else { return nil }
        return status?.files.first { $0.id == selected }
    }

    var currentWorktree: GitWorktree? {
        worktrees.first { Self.samePath($0.path, path) }
    }

    /// Works in another of the clone's worktrees.
    func use(worktree: String) {
        guard !Self.samePath(worktree, path) else { return }
        path = worktree
        snapshot = nil
        loaded = false
        selected = nil
        error = nil
        UserDefaults.standard.set(Self.samePath(worktree, root) ? nil : worktree, forKey: Self.worktreeKey(repo))
        Task { await refresh() }
    }

    /// The worktree last worked in, kept per repo on this Mac.
    static func worktreeKey(_ repo: String) -> String { "localRepositoryWorktree.\(repo)" }

    static func samePath(_ a: String, _ b: String) -> Bool {
        let expand = { (path: String) in URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL.path }
        return expand(a) == expand(b)
    }

    // MARK: Reading

    /// Reads everything again, and the selected file's diff. A call while
    /// one runs makes it read once more when done, rather than both running.
    func refresh() async {
        guard !refreshing else {
            again = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            again = false
            await read()
        } while again
    }

    private func read() async {
        let path = path
        let script = Self.script(in: path, reading: true, "git rev-parse --git-dir >/dev/null || exit 1\n" + GitParse.snapshotScript + "\nexit 0")
        let result = await Task.detached { Shell.run(script, .local) }.value
        guard path == self.path else { return }
        loaded = true
        guard result.ok else {
            error = result.failure.isEmpty ? "Couldn't read \(path)." : result.failure
            snapshot = nil
            return
        }
        error = nil
        let found = await Task.detached { GitParse.snapshot(result.output) }.value
        if found != snapshot { snapshot = found }
        await readDiff()
    }

    private func readDiff() async {
        guard let selected else { return }
        // A file that moved between staged and not stays selected.
        guard let file = selectedFile ?? status?.files.first(where: { $0.path == GitFileChange.path(of: selected) }) else {
            self.selected = nil
            return
        }
        if file.id != selected { self.selected = file.id }
        let path = SessionScript.quoted(file.path)
        let whitespace = ignoresWhitespace ? " -w" : ""
        let command = switch file.area {
        case .staged: "g diff --cached --no-renames\(whitespace) -- \(path)"
        case .unstaged: "g diff --no-renames\(whitespace) -- \(path)"
        case .conflicted: "g diff -- \(path)"
        case .untracked: "g diff --no-index\(whitespace) -- /dev/null \(path)"
        }
        let script = Self.script(in: self.path, reading: true, command + "\nexit 0")
        let output = await Task.detached { Shell.run(script, .local) }.value.output
        let (lines, header) = await Task.detached { GitDiff.lines(of: output) }.value
        guard selectedFile?.id == file.id else { return }
        if lines != diff {
            diff = lines
            diffHeader = header
        }
        if file.isBinary {
            let change = await binaryChange(file)
            if change != binary { binary = change }
        } else if binary != nil {
            binary = nil
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "ico", "icns", "pdf"]

    /// Sizes from git for the side it holds and from disk for the working
    /// file, and both pictures for an image.
    private func binaryChange(_ file: GitFileChange) async -> BinaryChange {
        // Each side as git names it: HEAD's copy, the index's (`:path`),
        // or nil for the file on disk.
        let (old, new): (String?, String?) = switch file.area {
        case .staged: ("HEAD:" + file.path, ":" + file.path)
        case .unstaged: (":" + file.path, nil)
        case .untracked, .conflicted: (nil, nil)
        }
        let isImage = Self.imageExtensions.contains((file.path as NSString).pathExtension.lowercased())
        let disk = URL(filePath: (path as NSString).expandingTildeInPath).appending(path: file.path)
        var change = BinaryChange()
        func blob(_ name: String) async -> Data? {
            let script = Self.script(in: path, reading: true, "git cat-file -p \(SessionScript.quoted(name))")
            let result = await Task.detached { Shell.run(script, .local) }.value
            return result.ok ? result.data : nil
        }
        if file.area != .untracked, let old {
            let data = await blob(old)
            change.oldSize = data?.count
            if isImage { change.oldImage = data }
        }
        if file.status != "D" {
            if let new {
                let data = await blob(new)
                change.newSize = data?.count
                if isImage { change.newImage = data }
            } else {
                let data = try? Data(contentsOf: disk)
                change.newSize = data?.count
                if isImage { change.newImage = data }
            }
        }
        return change
    }

    /// Tags on origin, for which are only here.
    func loadRemoteTags() async {
        let script = Self.script(in: path, reading: true, "git ls-remote --tags origin")
        let result = await Task.detached { Shell.run(script, .local) }.value
        if result.ok { remoteTags = GitParse.remoteTags(result.output) }
    }

    /// The last commit's message, as summary and description.
    func lastCommitMessage() async -> (summary: String, description: String) {
        let script = Self.script(in: path, reading: true, "git log -1 --format=%B")
        let output = await Task.detached { Shell.run(script, .local) }.value.output
        return Self.splitMessage(output)
    }

    static func splitMessage(_ message: String) -> (summary: String, description: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }
        return (String(trimmed[..<newline]), trimmed[newline...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Changing it

    /// Runs git in the worktree, then reads everything again. Nil when it
    /// worked, else what git said.
    @discardableResult
    private func git(_ command: String, doing: String? = nil) async -> String? {
        if let doing { busy = doing }
        let script = Self.script(in: path, reading: false, command)
        let result = await Task.detached { Shell.run(script, .local) }.value
        if doing != nil { busy = nil }
        await refresh()
        return result.ok ? nil : (result.failure.isEmpty ? "git didn't do it." : result.failure)
    }

    /// Runs it and shows what went wrong, for actions with nothing more to
    /// say.
    private func act(_ command: String, doing: String? = nil) async {
        if let failure = await git(command, doing: doing) { actionError = failure }
    }

    private func quoted(_ file: GitFileChange) -> String { SessionScript.quoted(file.path) }

    func stage(_ file: GitFileChange) async {
        await act("git add -- \(quoted(file))")
    }

    func unstage(_ file: GitFileChange) async {
        await act(Self.unstageCommand(quoted(file)))
    }

    func stageAll() async { await act("git add -A") }

    func unstageAll() async { await act(Self.unstageCommand(".")) }

    /// Before the first commit there's no HEAD to restore from.
    private static func unstageCommand(_ paths: String) -> String {
        "if git rev-parse -q --verify HEAD >/dev/null; then git restore --staged -- \(paths); else git rm --cached -r -q -- \(paths); fi"
    }

    /// Back to the last commit for a staged file, to the index for an
    /// unstaged one, or gone for a new one.
    func discard(_ file: GitFileChange) async {
        let path = quoted(file)
        let command = switch file.area {
        case .untracked: "rm -f -- \(path)"
        case .unstaged: "git restore --worktree -- \(path)"
        case .staged where file.status == "A": "git rm -f -q -- \(path)"
        case .staged, .conflicted: "git restore --source=HEAD --staged --worktree -- \(path)"
        }
        await act(command)
    }

    /// Whether the shown diff's hunks can be staged, unstaged or discarded.
    var hunksApply: Bool {
        guard let file = selectedFile, !ignoresWhitespace, !GitDiff.isCut(diff) else { return false }
        return file.area == .staged || file.area == .unstaged
    }

    func stageHunk(_ hunk: DiffLine.ID) async { await apply(hunk, "--cached") }
    func unstageHunk(_ hunk: DiffLine.ID) async { await apply(hunk, "--cached -R") }
    func discardHunk(_ hunk: DiffLine.ID) async { await apply(hunk, "-R") }

    private func apply(_ hunk: DiffLine.ID, _ options: String) async {
        guard hunksApply, let patch = GitDiff.patch(hunk: hunk, in: diff, header: diffHeader) else { return }
        await act("\(Shell.piped(patch)) | git apply \(options) -")
    }

    /// Commits what's staged, or amends the last commit with it. Nil when it
    /// worked, else what git or a hook said.
    func commit(summary: String, description: String, amend: Bool) async -> String? {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = summary.trimmingCharacters(in: .whitespacesAndNewlines) + (description.isEmpty ? "" : "\n\n" + description)
        return await git("\(Shell.piped(message)) | git commit\(amend ? " --amend" : "") -F -", doing: "Committing")
    }

    /// Takes the last commit back, keeping its changes staged; nil when it
    /// couldn't. Only for a commit that isn't pushed.
    func undoLastCommit() async -> (summary: String, description: String)? {
        let message = await lastCommitMessage()
        if let failure = await git("git reset --soft HEAD~1") {
            actionError = failure
            return nil
        }
        return message
    }

    /// Whether the last commit can be taken back: there's one before it,
    /// and it isn't on the upstream.
    var canUndoLastCommit: Bool {
        guard let status, status.head != nil, status.operation == nil else { return false }
        return status.upstream == nil || status.ahead > 0
    }

    // MARK: Syncing

    /// Fetches from every remote. A background fetch keeps quiet about
    /// failing, but says so in the toolbar's help.
    func fetch(quietly: Bool = false) async {
        guard busy == nil || quietly else { return }
        let failure = await git("git fetch --all --prune --quiet", doing: quietly ? nil : "Fetching")
        lastFetched = .now
        fetchError = failure
        if let failure, !quietly { actionError = failure }
    }

    /// Pulls as your git config says; when git wants telling how to
    /// reconcile divergent branches, asks.
    func pull(rebase: Bool? = nil) async {
        let option = rebase.map { $0 ? " --rebase" : " --no-rebase" } ?? ""
        guard let failure = await git("git pull\(option)", doing: "Pulling") else { return }
        if rebase == nil, failure.contains("divergent") || failure.contains("how to reconcile") {
            reconciling = true
        } else {
            actionError = failure
        }
    }

    /// Pushes the branch, publishing it to origin first time.
    func push(force: Bool = false) async {
        guard let status else { return }
        let command = status.upstream == nil
            ? "git push -u origin HEAD"
            : force ? "git push --force-with-lease" : "git push"
        await act(command, doing: "Pushing")
    }

    /// Push, pull, publish or fetch: the one most wanted now, as the toolbar
    /// offers it.
    enum SyncAction { case publish, pull, push, fetch }

    var syncAction: SyncAction {
        guard let status, status.branch != nil else { return .fetch }
        if status.upstream == nil { return .publish }
        if status.behind > 0 { return .pull }
        if status.ahead > 0 { return .push }
        return .fetch
    }

    func sync() async {
        switch syncAction {
        case .publish, .push: await push()
        case .pull: await pull()
        case .fetch: await fetch()
        }
    }

    // MARK: Branches

    /// Switches, asking first when there are changes and saying why not
    /// when the branch is out in another worktree.
    func requestSwitch(to branch: GitBranch) {
        if let worktree = worktree(holding: branch) {
            actionError = "\(branch.localName) is checked out in \(SessionStore.tildePath(URL(filePath: worktree))). Open that worktree to work on it."
            return
        }
        if status?.hasTrackedChanges == true {
            switching = branch
        } else {
            Task { await switchTo(branch, leavingChanges: false) }
        }
    }

    /// The worktree, other than this one, a branch is checked out in.
    func worktree(holding branch: GitBranch) -> String? {
        let name = branch.localName
        let local = branch.isRemote ? branches.first { !$0.isRemote && $0.name == name } : branch
        guard let path = local?.worktree, !Self.samePath(path, self.path) else { return nil }
        return path
    }

    /// Switches branch, leaving the changes stashed on this one (they're
    /// offered back on returning) or bringing them along.
    func switchTo(_ branch: GitBranch, leavingChanges: Bool) async {
        var command = ""
        if leavingChanges, let current = status?.branch {
            command += "git stash push -u -m \(SessionScript.quoted(GitStatus.leftMessage(current))) && "
        }
        let name = branch.localName
        let hasLocal = branches.contains { !$0.isRemote && $0.name == name }
        command += branch.isRemote && !hasLocal
            ? "git switch --track \(SessionScript.quoted(branch.name))"
            : "git switch \(SessionScript.quoted(name))"
        await act(command, doing: "Switching")
    }

    /// Applies the changes left on this branch, then drops them from the
    /// stash by SHA, so another session's stash is never touched.
    func restoreLeftChanges() async {
        guard let stash = status?.leftHere else { return }
        let sha = SessionScript.quoted(stash.sha)
        await act("""
            git stash apply \(sha) && ref=$(git stash list --format='%H %gd' | awk -v s=\(sha) '$1==s {print $2; exit}') && [ -n "$ref" ] && git stash drop -q "$ref"
            """)
    }

    func dropLeftChanges() async {
        guard let stash = status?.leftHere else { return }
        let sha = SessionScript.quoted(stash.sha)
        await act("""
            ref=$(git stash list --format='%H %gd' | awk -v s=\(sha) '$1==s {print $2; exit}') && [ -n "$ref" ] && git stash drop -q "$ref"
            """)
    }

    /// A new branch from `base`, not tracking it, so its first push
    /// publishes it under its own name.
    func createBranch(_ name: String, from base: String, switching: Bool) async -> String? {
        let name = SessionScript.quoted(name)
        let base = SessionScript.quoted(base)
        return await git(switching ? "git switch --no-track -c \(name) \(base)" : "git branch --no-track \(name) \(base)")
    }

    func renameBranch(_ branch: GitBranch, to name: String) async -> String? {
        await git("git branch -m \(SessionScript.quoted(branch.name)) \(SessionScript.quoted(name))")
    }

    func publish(_ branch: GitBranch) async {
        await act("git push -u origin \(SessionScript.quoted(branch.name))", doing: "Publishing")
    }

    /// Deletes a branch here, on origin, or both. Nil when it worked; a
    /// branch with unmerged commits needs `force`.
    func deleteBranch(_ branch: GitBranch, here: Bool, onOrigin: Bool, force: Bool = false) async -> String? {
        var commands: [String] = []
        if here, !branch.isRemote { commands.append("git branch \(force ? "-D" : "-d") \(SessionScript.quoted(branch.name))") }
        if onOrigin { commands.append("git push origin --delete \(SessionScript.quoted(branch.localName))") }
        guard !commands.isEmpty else { return nil }
        return await git(commands.joined(separator: " && "), doing: onOrigin ? "Deleting" : nil)
    }

    // MARK: Worktrees

    /// Where a new worktree for the branch goes: beside the session ones,
    /// `<harness>/.worktrees/<branch>/<name>`, for a clone in a harness's
    /// `projects/`; else `<clone>.worktrees/<branch>`.
    func suggestedWorktreePath(branch: String) -> String {
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        let clone = root as NSString
        let parent = clone.deletingLastPathComponent as NSString
        if parent.lastPathComponent == "projects" {
            return "\(parent.deletingLastPathComponent)/.worktrees/\(folder)/\(clone.lastPathComponent)"
        }
        return "\(root).worktrees/\(folder)"
    }

    /// Adds a worktree for an existing branch, a branch on origin, or a new
    /// one from `base`, then works in it.
    func addWorktree(at path: String, branch: String, newFrom base: String?) async -> String? {
        let target = SessionScript.shellPath(path)
        let name = SessionScript.quoted(branch)
        let command: String
        if let base {
            command = "git worktree add --no-track -b \(name) \(target) \(SessionScript.quoted(base))"
        } else if let remote = branches.first(where: { $0.isRemote && $0.localName == branch }), !branches.contains(where: { !$0.isRemote && $0.name == branch }) {
            command = "git worktree add --track -b \(name) \(target) \(SessionScript.quoted(remote.name))"
        } else {
            command = "git worktree add \(target) \(name)"
        }
        let parent = SessionScript.shellPath((path as NSString).deletingLastPathComponent)
        if let failure = await git("mkdir -p \(parent) && \(command)") { return failure }
        use(worktree: (path as NSString).expandingTildeInPath)
        return nil
    }

    /// Removes a worktree; `force` throws away its changes too.
    func removeWorktree(_ worktree: GitWorktree, force: Bool) async -> String? {
        if Self.samePath(worktree.path, path) { use(worktree: root) }
        return await git("git worktree remove \(force ? "--force " : "")\(SessionScript.quoted(worktree.path))")
    }

    func pruneWorktrees() async { await act("git worktree prune") }

    // MARK: Tags

    /// A tag on `target`: annotated when there's a message.
    func createTag(_ name: String, target: String, message: String, push: Bool) async -> String? {
        let quotedName = SessionScript.quoted(name)
        let target = SessionScript.quoted(target.isEmpty ? "HEAD" : target)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var command = message.isEmpty
            ? "git tag \(quotedName) \(target)"
            : "\(Shell.piped(message)) | git tag -a \(quotedName) -F - \(target)"
        if push { command += " && git push origin \(SessionScript.quoted("refs/tags/" + name))" }
        let failure = await git(command, doing: push ? "Pushing" : nil)
        if push { await loadRemoteTags() }
        return failure
    }

    func pushTag(_ tag: GitTag) async {
        await act("git push origin \(SessionScript.quoted("refs/tags/" + tag.name))", doing: "Pushing")
        await loadRemoteTags()
    }

    func pushAllTags() async {
        await act("git push origin --tags", doing: "Pushing")
        await loadRemoteTags()
    }

    func deleteTag(_ name: String, here: Bool, onOrigin: Bool) async {
        var commands: [String] = []
        if here { commands.append("git tag -d \(SessionScript.quoted(name))") }
        if onOrigin { commands.append("git push origin --delete \(SessionScript.quoted("refs/tags/" + name))") }
        guard !commands.isEmpty else { return }
        await act(commands.joined(separator: " && "), doing: onOrigin ? "Deleting" : nil)
        if onOrigin { await loadRemoteTags() }
    }

    // MARK: Conflicts

    func takeOurs(_ file: GitFileChange) async {
        await act("git checkout --ours -- \(quoted(file)) && git add -- \(quoted(file))")
    }

    func takeTheirs(_ file: GitFileChange) async {
        await act("git checkout --theirs -- \(quoted(file)) && git add -- \(quoted(file))")
    }

    func markResolved(_ file: GitFileChange) async {
        await act("git add -- \(quoted(file))")
    }

    /// Goes on with the merge or rebase, keeping git's own message.
    func continueOperation() async {
        guard let operation = status?.operation else { return }
        await act("GIT_EDITOR=true git \(operation.rawValue) --continue", doing: "Continuing")
    }

    func abortOperation() async {
        guard let operation = status?.operation else { return }
        await act("git \(operation.rawValue) --abort")
    }

    // MARK: Opening

    func openInEditor(_ file: GitFileChange? = nil, line: Int? = nil) {
        let base = (path as NSString).expandingTildeInPath
        CodeEditor.chosen.open(file.map { base + "/" + $0.path } ?? base, line: line, host: nil)
    }

    func revealInFinder(_ file: GitFileChange? = nil) {
        let base = URL(filePath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([file.map { base.appending(path: $0.path) } ?? base])
    }

    func openInTerminal() {
        let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Scripts

    /// A script run in `folder`, with `g` as git that never pages or quotes
    /// paths. Reads take no optional locks, so claude's own git never finds
    /// the index locked.
    nonisolated static func script(in folder: String, reading: Bool, _ body: String) -> String {
        """
        \(reading ? "export GIT_OPTIONAL_LOCKS=0" : "")
        cd \(shellPath(folder)) || exit 1
        g() { git -c core.quotepath=off --no-pager "$@" 2>/dev/null; }
        \(body)
        """
    }

    nonisolated private static func shellPath(_ path: String) -> String {
        if path == "~" { return #""$HOME""# }
        if path.hasPrefix("~/") { return #""$HOME"/"# + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    nonisolated private static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What a sheet for a new branch starts from.
struct CreateBranchRequest: Identifiable {
    let id = UUID()
    var base: String
}

struct CreateWorktreeRequest: Identifiable {
    let id = UUID()
    /// An existing branch to check out, else a new one is made.
    var branch: GitBranch?
}

struct CreateTagRequest: Identifiable {
    let id = UUID()
    var target: String = "HEAD"
}
