import Foundation

/// A file changed in a checkout: in the index, in the working tree, new, or
/// in conflict. A file staged and then changed again is two of these.
nonisolated struct GitFileChange: Identifiable, Hashable, Sendable {
    nonisolated enum Area: String, Sendable {
        case conflicted, staged, unstaged, untracked
    }

    let path: String
    let area: Area
    /// git's letter: M, A, D, T, U, or ? for a new file.
    let status: String
    var added: Int = 0
    var removed: Int = 0
    var isBinary = false

    var id: String { Self.id(area, path) }

    static func id(_ area: Area, _ path: String) -> String { area.rawValue + "\n" + path }

    /// The path an ID names, whichever area it's in.
    static func path(of id: String) -> String {
        id.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? id
    }

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Something git is part way through, waiting on conflicts or a continue.
nonisolated enum GitOperation: String, Sendable {
    case merge, rebase, cherryPick = "cherry-pick", revert

    var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }
}

nonisolated struct GitStash: Hashable, Sendable {
    let sha: String
    /// `On main: Gannin: left on main`.
    let subject: String
}

/// A checkout's state, from `git status --porcelain=v2 --branch`.
nonisolated struct GitStatus: Hashable, Sendable {
    /// Nil before the first commit.
    var head: String?
    /// Nil when detached.
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitFileChange] = []
    var stashes: [GitStash] = []
    var operation: GitOperation?

    func files(in area: GitFileChange.Area) -> [GitFileChange] {
        files.filter { $0.area == area }
    }

    /// Changes a switch of branch would have to deal with; new files
    /// simply come along.
    var hasTrackedChanges: Bool { files.contains { $0.area != .untracked } }

    /// Changes left on this branch when Gannin switched away from it.
    var leftHere: GitStash? {
        guard let branch else { return nil }
        return stashes.first { $0.subject.hasSuffix(GitStatus.leftMessage(branch)) }
    }

    static func leftMessage(_ branch: String) -> String { "Gannin: left on \(branch)" }
}

nonisolated struct GitBranch: Identifiable, Hashable, Sendable {
    /// `main`, or `origin/main` for a remote one.
    let name: String
    let isRemote: Bool
    let sha: String
    let upstream: String?
    var ahead = 0
    var behind = 0
    /// Its upstream was deleted on the remote.
    var upstreamGone = false
    let date: Date
    /// The worktree it's checked out in, if any.
    let worktree: String?
    let subject: String

    var id: String { (isRemote ? "remote:" : "local:") + name }

    /// The name a local branch for it has: `main` for `origin/main`.
    var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

nonisolated struct GitWorktree: Identifiable, Hashable, Sendable {
    let path: String
    let head: String?
    /// Nil when detached.
    let branch: String?
    /// The main checkout, the clone itself.
    let isMain: Bool
    /// Its folder's gone.
    let isPrunable: Bool
    let isLocked: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

nonisolated struct GitTag: Identifiable, Hashable, Sendable {
    let name: String
    /// The commit it points at.
    let sha: String
    let isAnnotated: Bool
    let date: Date?
    let subject: String

    var id: String { name }
}

/// The parts of a checkout a page shows, read in one go.
nonisolated struct GitSnapshot: Hashable, Sendable {
    var status = GitStatus()
    var branches: [GitBranch] = []
    var worktrees: [GitWorktree] = []
    var tags: [GitTag] = []
    /// `origin/HEAD`'s branch, `main`.
    var defaultBranch: String?
}

/// Reading what git prints.
nonisolated enum GitParse {
    /// Prints the snapshot's sections, each after a record separator line.
    static let snapshotScript = #"""
        printf '\036status\n'; g status --porcelain=v2 --branch --no-renames --untracked-files=all
        printf '\036staged\n'; g diff --cached --no-renames --numstat
        printf '\036unstaged\n'; g diff --no-renames --numstat
        printf '\036untracked\n'
        g ls-files --others --exclude-standard | while IFS= read -r f; do
          if [ -s "$f" ] && ! grep -Iq . "$f"; then printf -- '-\t%s\n' "$f"
          else printf '%s\t%s\n' "$(wc -l < "$f" | tr -d ' ')" "$f"; fi
        done
        printf '\036stashes\n'; g stash list --format='%H%x09%gs'
        printf '\036operation\n'
        gd=$(g rev-parse --git-dir)
        if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then echo rebase
        elif [ -e "$gd/MERGE_HEAD" ]; then echo merge
        elif [ -e "$gd/CHERRY_PICK_HEAD" ]; then echo cherry-pick
        elif [ -e "$gd/REVERT_HEAD" ]; then echo revert; fi
        printf '\036branches\n'
        g for-each-ref --sort=-committerdate --format='%(refname)%09%(objectname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)%09%(worktreepath)%09%(contents:subject)' refs/heads refs/remotes
        printf '\036worktrees\n'; g worktree list --porcelain
        printf '\036default\n'; g symbolic-ref --short refs/remotes/origin/HEAD
        printf '\036tags\n'
        g for-each-ref --sort=-creatordate --format='%(refname:short)%09%(objecttype)%09%(objectname:short)%09%(*objectname:short)%09%(creatordate:unix)%09%(contents:subject)' refs/tags
        """#

    static func snapshot(_ output: String) -> GitSnapshot {
        var snapshot = GitSnapshot()
        var sections: [String: [Substring]] = [:]
        var section = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\u{1E}") {
                section = String(line.dropFirst())
                continue
            }
            sections[section, default: []].append(line)
        }

        var status = GitStatus()
        var tracked: [GitFileChange] = []
        for line in sections["status"] ?? [] {
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": status.head = parts[1] == "(initial)" ? nil : String(parts[1].prefix(9))
                case "branch.head": status.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    status.ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    status.behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
                continue
            }
            let kind = line.first
            switch kind {
            case "1":
                let fields = line.split(separator: " ", maxSplits: 8)
                guard fields.count == 9 else { continue }
                let xy = Array(fields[1])
                let path = unquote(String(fields[8]))
                if xy[0] != "." { tracked.append(GitFileChange(path: path, area: .staged, status: String(xy[0]))) }
                if xy[1] != "." { tracked.append(GitFileChange(path: path, area: .unstaged, status: String(xy[1]))) }
            case "2":
                // Renames, should git report one: the new path, then the old.
                let fields = line.split(separator: " ", maxSplits: 9)
                guard fields.count == 10 else { continue }
                let xy = Array(fields[1])
                let path = unquote(String(fields[9].split(separator: "\t").first ?? fields[9]))
                if xy[0] != "." { tracked.append(GitFileChange(path: path, area: .staged, status: "M")) }
                if xy[1] != "." { tracked.append(GitFileChange(path: path, area: .unstaged, status: "M")) }
            case "u":
                let fields = line.split(separator: " ", maxSplits: 10)
                guard fields.count == 11 else { continue }
                tracked.append(GitFileChange(path: unquote(String(fields[10])), area: .conflicted, status: "U"))
            default:
                break
            }
        }
        let staged = numstat(sections["staged"] ?? [])
        let unstaged = numstat(sections["unstaged"] ?? [])
        for index in tracked.indices {
            let counts = tracked[index].area == .staged ? staged[tracked[index].path] : unstaged[tracked[index].path]
            if let counts {
                tracked[index].added = counts.added ?? 0
                tracked[index].removed = counts.removed ?? 0
                tracked[index].isBinary = counts.added == nil
            }
        }
        for line in sections["untracked"] ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let lines = Int(parts[0])
            tracked.append(GitFileChange(path: unquote(parts[1]), area: .untracked, status: "?", added: lines ?? 0, isBinary: lines == nil))
        }
        status.files = tracked.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.stashes = (sections["stashes"] ?? []).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? GitStash(sha: parts[0], subject: parts[1]) : nil
        }
        status.operation = (sections["operation"] ?? []).lazy.compactMap { GitOperation(rawValue: String($0)) }.first
        snapshot.status = status

        snapshot.worktrees = worktrees(sections["worktrees"] ?? [])
        snapshot.branches = branches(sections["branches"] ?? [])
        snapshot.defaultBranch = (sections["default"] ?? []).first.flatMap { line in
            line.isEmpty ? nil : GitBranch(name: String(line), isRemote: true, sha: "", upstream: nil, date: .distantPast, worktree: nil, subject: "").localName
        }
        snapshot.tags = (sections["tags"] ?? []).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6, !parts[0].isEmpty else { return nil }
            let annotated = parts[1] == "tag"
            return GitTag(
                name: parts[0],
                sha: annotated && !parts[3].isEmpty ? parts[3] : parts[2],
                isAnnotated: annotated,
                date: Double(parts[4]).map { Date(timeIntervalSince1970: $0) },
                subject: parts[5]
            )
        }
        return snapshot
    }

    /// `--numstat` by path: nil counts for a binary file.
    private static func numstat(_ lines: [Substring]) -> [String: (added: Int?, removed: Int?)] {
        var counts: [String: (added: Int?, removed: Int?)] = [:]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            counts[unquote(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        return counts
    }

    private static func branches(_ lines: [Substring]) -> [GitBranch] {
        lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 7 else { return nil }
            let ref = parts[0]
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name = String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            // `origin/HEAD` points at a branch listed anyway.
            if isRemote, name.hasSuffix("/HEAD") || !name.contains("/") { return nil }
            var branch = GitBranch(
                name: name,
                isRemote: isRemote,
                sha: parts[1],
                upstream: parts[2].isEmpty ? nil : parts[2],
                date: Date(timeIntervalSince1970: Double(parts[4]) ?? 0),
                worktree: parts[5].isEmpty ? nil : parts[5],
                subject: parts[6]
            )
            // `[ahead 2, behind 1]`, or `[gone]`.
            let track = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            for piece in track.split(separator: ",") {
                let words = piece.split(separator: " ")
                if words.first == "gone" { branch.upstreamGone = true }
                if words.count == 2, let count = Int(words[1]) {
                    if words[0] == "ahead" { branch.ahead = count } else if words[0] == "behind" { branch.behind = count }
                }
            }
            return branch
        }
    }

    private static func worktrees(_ lines: [Substring]) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var prunable = false
        var locked = false
        func finish() {
            if let path {
                worktrees.append(GitWorktree(path: path, head: head, branch: branch, isMain: worktrees.isEmpty, isPrunable: prunable, isLocked: locked))
            }
            path = nil; head = nil; branch = nil; prunable = false; locked = false
        }
        for line in lines {
            if line.isEmpty {
                finish()
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "worktree":
                finish()
                path = parts.count > 1 ? parts[1] : nil
            case "HEAD": head = parts.count > 1 ? String(parts[1].prefix(9)) : nil
            case "branch": branch = parts.count > 1 ? String(parts[1].dropFirst("refs/heads/".count)) : nil
            case "prunable": prunable = true
            case "locked": locked = true
            default: break
            }
        }
        finish()
        return worktrees
    }

    /// Names in `git ls-remote --tags`.
    static func remoteTags(_ output: String) -> Set<String> {
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { continue }
            var name = String(ref.dropFirst("refs/tags/".count))
            if name.hasSuffix("^{}") { name.removeLast(3) }
            names.insert(name)
        }
        return names
    }

    /// A path git quoted for holding a quote, a backslash or a control
    /// character (`core.quotepath=off` leaves other characters be).
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var result = ""
        var escaping = false
        for character in path.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
