import Foundation
import Observation

nonisolated struct GitCommit: Identifiable, Hashable, Sendable {
    let sha: String
    let shortSHA: String
    let author: String
    let date: Date
    /// git's decorations: `HEAD -> main`, `origin/main`, `tag: v1.0.0`.
    let refs: [String]
    let parents: Int
    let subject: String

    var id: String { sha }

    var tags: [String] {
        refs.compactMap { $0.hasPrefix("tag: ") ? String($0.dropFirst(5)) : nil }
    }

    /// Branches pointing at it, HEAD's arrow taken off.
    var branches: [String] {
        refs.filter { !$0.hasPrefix("tag: ") && $0 != "HEAD" && !$0.hasSuffix("/HEAD") }
            .map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst(8)) : $0 }
    }
}

nonisolated struct GitCommitFile: Identifiable, Hashable, Sendable {
    let path: String
    let status: String
    var added = 0
    var removed = 0
    var isBinary = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// A branch's commits, newest first, a page at a time, and the selected
/// commit's message, files and a file's diff. A merge shows what it brought
/// in against its first parent.
@Observable
final class GitHistory {
    static let pageSize = 200

    private(set) var commits: [GitCommit] = []
    /// Commits not on the branch's upstream yet.
    private(set) var unpushed: Set<String> = []
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private var limit = pageSize

    var selected: GitCommit.ID? {
        didSet {
            if selected != oldValue {
                message = nil
                files = []
                selectedFile = nil
            }
        }
    }
    private(set) var message: String?
    private(set) var files: [GitCommitFile] = []
    var selectedFile: GitCommitFile.ID? {
        didSet { if selectedFile != oldValue { diff = [] } }
    }
    private(set) var diff: [DiffLine] = []

    var selectedCommit: GitCommit? {
        guard let selected else { return nil }
        return commits.first { $0.sha == selected }
    }

    /// Reads the branch's commits, as many as are shown already.
    func load(path: String, ref: String, upstream: String?) async {
        loading = true
        defer { loading = false }
        let quotedRef = SessionScript.quoted(ref)
        var body = """
            printf '\\036log\\n'
            git -c core.quotepath=off --no-pager log \(quotedRef) -n \(limit + 1) --format='%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%P%x1f%s%x1d' -- || exit 1
            """
        // Against the upstream when there is one; else whatever's on no
        // remote branch, as a new branch's commits are.
        let unpushedRange = upstream.map { "\(SessionScript.quoted($0))..\(quotedRef)" } ?? "\(quotedRef) --not --remotes"
        body += "\nprintf '\\036unpushed\\n'; git rev-list -n \(limit + 1) \(unpushedRange) 2>/dev/null"
        let script = LocalRepository.script(in: path, reading: true, body + "\nexit 0")
        let result = await Task.detached { Shell.run(script, .local) }.value
        guard result.ok else {
            error = result.failure.isEmpty ? "Couldn't read the history of \(ref)." : result.failure
            return
        }
        error = nil
        let limit = limit
        let (found, ahead) = await Task.detached { Self.parse(result.output) }.value
        hasMore = found.count > limit
        let shown = Array(found.prefix(limit))
        if shown != commits { commits = shown }
        if ahead != unpushed { unpushed = ahead }
        if let selected, !shown.contains(where: { $0.sha == selected }) { self.selected = nil }
    }

    func loadMore(path: String, ref: String, upstream: String?) async {
        limit += Self.pageSize
        await load(path: path, ref: ref, upstream: upstream)
    }

    /// Back to the first page, for another branch.
    func reset() {
        limit = Self.pageSize
        commits = []
        unpushed = []
        selected = nil
    }

    /// The selected commit's whole message and its files.
    func loadSelected(path: String) async {
        guard let sha = selected else { return }
        let commit = SessionScript.quoted(sha)
        let show = "git -c core.quotepath=off --no-pager show --format= --no-renames --diff-merges=first-parent"
        let script = LocalRepository.script(in: path, reading: true, """
            printf '\\036message\\n'; git --no-pager show -s --format=%B \(commit)
            printf '\\036status\\n'; \(show) --name-status \(commit)
            printf '\\036numstat\\n'; \(show) --numstat \(commit)
            exit 0
            """)
        let output = await Task.detached { Shell.run(script, .local) }.value.output
        guard selected == sha else { return }
        let (text, found) = await Task.detached { Self.parseCommit(output) }.value
        message = text
        files = found
        if selectedFile == nil { selectedFile = found.first?.id }
    }

    /// The selected file's diff in the selected commit.
    func loadDiff(path: String) async {
        guard let sha = selected, let file = selectedFile else { return }
        let script = LocalRepository.script(in: path, reading: true, """
            git -c core.quotepath=off --no-pager show --format= --no-renames --diff-merges=first-parent \(SessionScript.quoted(sha)) -- \(SessionScript.quoted(file))
            exit 0
            """)
        let output = await Task.detached { Shell.run(script, .local) }.value.output
        let (lines, _) = await Task.detached { GitDiff.lines(of: output) }.value
        guard selected == sha, selectedFile == file else { return }
        diff = lines
    }

    // MARK: Parsing

    nonisolated private static func parse(_ output: String) -> ([GitCommit], Set<String>) {
        var commits: [GitCommit] = []
        var unpushed: Set<String> = []
        var section = ""
        var log = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\u{1E}") {
                section = String(line.dropFirst())
                continue
            }
            switch section {
            case "log": log += line + "\n"
            case "unpushed": if !line.isEmpty { unpushed.insert(String(line)) }
            default: break
            }
        }
        for record in log.split(separator: "\u{1D}") {
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { continue }
            commits.append(GitCommit(
                sha: fields[0],
                shortSHA: fields[1],
                author: fields[2],
                date: Date(timeIntervalSince1970: Double(fields[3]) ?? 0),
                refs: fields[4].isEmpty ? [] : fields[4].components(separatedBy: ", "),
                parents: fields[5].split(separator: " ").count,
                subject: fields[6]
            ))
        }
        return (commits, unpushed)
    }

    nonisolated private static func parseCommit(_ output: String) -> (String, [GitCommitFile]) {
        var sections: [String: [Substring]] = [:]
        var section = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\u{1E}") {
                section = String(line.dropFirst())
                continue
            }
            sections[section, default: []].append(line)
        }
        let message = (sections["message"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var files: [GitCommitFile] = []
        for line in sections["status"] ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            files.append(GitCommitFile(path: GitParse.unquote(parts[1]), status: String(parts[0].prefix(1))))
        }
        for line in sections["numstat"] ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let index = files.firstIndex(where: { $0.path == GitParse.unquote(parts[2]) }) else { continue }
            files[index].added = Int(parts[0]) ?? 0
            files[index].removed = Int(parts[1]) ?? 0
            files[index].isBinary = Int(parts[0]) == nil
        }
        return (message, files)
    }
}
