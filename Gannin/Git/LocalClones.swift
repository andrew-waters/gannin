import Foundation

/// A clone's state at a glance, for On This Mac.
nonisolated struct CloneSummary: Hashable, Sendable {
    var branch: String?
    var changes = 0
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    var worktrees = 1
}

/// Where the org's repos are cloned on this Mac, and cloning them. The
/// window's project's harness keeps shared clones in `projects/<name>`, as
/// sessions do, so that's where a clone goes and the first place looked.
enum LocalClones {
    /// A clone's folder picked by hand (Add Existing, or Clone to a folder
    /// chosen), per repo.
    static func key(_ repo: String) -> String { "localRepository.\(repo)" }

    static func saved(_ repo: String) -> String? {
        let path = (UserDefaults.standard.string(forKey: key(repo)) ?? "").trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    static func save(_ path: String?, for repo: String) {
        UserDefaults.standard.set(path, forKey: key(repo))
    }

    /// Repos with a folder saved on this Mac.
    static var savedRepos: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("localRepository.") && $0.split(separator: "/").count == 2 }
            .map { String($0.dropFirst("localRepository.".count)) }
    }

    /// The harness checkouts on this Mac a clone may sit in, the window's
    /// project's first.
    private static func harnessCheckouts(org: String, config: OrgConfig) -> [(repo: String, path: String)] {
        var seen: Set<String> = []
        return (config.harnesses + config.allHarnesses)
            .filter { seen.insert($0.repo).inserted }
            .map { ($0.repo, SessionStore.localHarnessPath(org: org, repo: $0.repo)) }
    }

    /// The repo's clone here: the folder saved for it, else the harness
    /// itself when it's the repo, else a harness's `projects/<name>` (or
    /// `projects/<group>/<name>`), else one of the usual places.
    static func find(_ repo: String, org: String, config: OrgConfig) -> String? {
        if let saved = saved(repo), isGitFolder(saved) { return saved }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        for harness in harnessCheckouts(org: org, config: config) {
            if harness.repo.caseInsensitiveCompare(repo) == .orderedSame, isCheckout(harness.path, of: repo) { return harness.path }
            let projects = harness.path + "/projects"
            if isCheckout(projects + "/" + name, of: repo) { return projects + "/" + name }
            let groups = (try? FileManager.default.contentsOfDirectory(atPath: expand(projects))) ?? []
            for group in groups where !group.hasPrefix(".") {
                let candidate = "\(projects)/\(group)/\(name)"
                if isCheckout(candidate, of: repo) { return candidate }
            }
        }
        return SessionStore.existingCheckout(of: repo)
    }

    /// Where Clone puts it: the harness checkout when the repo is the
    /// harness, else its `projects/<name>`; with no harness checked out
    /// here, `<workspace>/<owner>/<name>`.
    static func destination(_ repo: String, org: String, config: OrgConfig) -> String {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        if let harness = config.harness(covering: [repo]) {
            let checkout = SessionStore.localHarnessPath(org: org, repo: harness.repo)
            if harness.repo.caseInsensitiveCompare(repo) == .orderedSame { return checkout }
            if isGitFolder(checkout) { return checkout + "/projects/" + name }
        }
        return SessionStore.tildePath(SessionStore.workspaceRoot) + "/" + repo
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// A git checkout or worktree is there.
    static func isGitFolder(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path) + "/.git")
    }

    /// A clone of the repo is there, judged by its remotes. The whole name
    /// must match: `gannin` mustn't match a clone of `gannin-legacy`.
    static func isCheckout(_ path: String, of repo: String) -> Bool {
        remotes(of: path).contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// The `owner/name` of each GitHub remote in the clone's config.
    static func remotes(of path: String) -> [String] {
        let config = URL(filePath: expand(path)).appending(path: ".git/config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { return nil }
            return gitHubRepo(parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// `owner/name` from a GitHub URL: https, ssh or `git@github.com:`.
    static func gitHubRepo(_ url: String) -> String? {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        guard let range = url.range(of: "github.com", options: .caseInsensitive) else {
            // `owner/name` as typed.
            let parts = url.split(separator: "/")
            return parts.count == 2 && !url.contains(":") ? url : nil
        }
        let rest = url[range.upperBound...].drop { $0 == "/" || $0 == ":" }
        let parts = rest.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }

    /// Clones with gh when it's installed (its protocol and login), else
    /// git over https (the credential helper's login). Nil when it worked.
    static func clone(_ repo: String, from url: String? = nil, to path: String) async -> String? {
        let target = SessionScript.shellPath(path)
        let parent = SessionScript.shellPath((path as NSString).deletingLastPathComponent)
        let source = SessionScript.quoted(url ?? "https://github.com/\(repo).git")
        let ghClone = url == nil ? "command -v gh >/dev/null 2>&1 && gh repo clone \(SessionScript.quoted(repo)) \(target) -- --quiet" : "false"
        let script = """
            mkdir -p \(parent) || exit 1
            if [ -e \(target) ] && [ -n "$(ls -A \(target) 2>/dev/null)" ]; then
              echo "Something's already in \(path.replacingOccurrences(of: "\"", with: "")). Add it as an existing clone instead." >&2; exit 1
            fi
            if \(ghClone); then exit 0; fi
            git clone --quiet \(source) \(target)
            """
        let result = await Task.detached { Shell.run(script, .local) }.value
        return result.ok ? nil : (result.failure.isEmpty ? "The clone didn't work." : result.failure)
    }

    /// Each clone's branch, changes, ahead and behind, and how many
    /// worktrees it has, read in one go.
    static func summaries(_ clones: [String: String]) async -> [String: CloneSummary] {
        guard !clones.isEmpty else { return [:] }
        var script = "export GIT_OPTIONAL_LOCKS=0\n"
        for (repo, path) in clones {
            script += """
                printf '\\036%s\\n' \(SessionScript.quoted(repo))
                (cd \(SessionScript.shellPath(path)) && git status --porcelain=v2 --branch && printf '# worktrees %s\\n' "$(git worktree list --porcelain | grep -c '^worktree ')") 2>/dev/null

                """
        }
        script += "exit 0\n"
        let output = await Task.detached { Shell.run(script, .local) }.value.output
        var summaries: [String: CloneSummary] = [:]
        var repo: String?
        var summary = CloneSummary()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("\u{1E}") {
                if let repo { summaries[repo] = summary }
                repo = String(line.dropFirst())
                summary = CloneSummary()
                continue
            }
            guard line.hasPrefix("# ") else {
                summary.changes += 1
                continue
            }
            let parts = line.dropFirst(2).split(separator: " ")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "branch.head": summary.branch = parts[1] == "(detached)" ? nil : String(parts[1])
            case "branch.upstream": summary.hasUpstream = true
            case "branch.ab":
                summary.ahead = Int(parts[1].dropFirst()) ?? 0
                summary.behind = parts.count > 2 ? Int(parts[2].dropFirst()) ?? 0 : 0
            case "worktrees": summary.worktrees = Int(parts[1]) ?? 1
            default: break
            }
        }
        if let repo { summaries[repo] = summary }
        return summaries
    }
}
