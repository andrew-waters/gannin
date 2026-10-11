import Foundation

/// A commit Gannin makes to the harness through the GitHub API, never
/// through a checkout: files added or replaced by path (nil removes one),
/// and files added as they are, byte for byte, which needn't be text.
struct HarnessChange {
    var message: String
    var files: [String: String?]
    var data: [String: Data] = [:]

    /// The most a file added as data can be. `createCommitOnBranch` takes
    /// the whole commit in one request, base64 encoded, so a larger one is
    /// refused here with a reason rather than by GitHub.
    nonisolated static let maxDataBytes = 5 * 1024 * 1024
}

extension HarnessChange {
    /// The commit message's first line, and the rest trimmed: GitHub's
    /// separate headline and body, or a pull request's title and body.
    var titleAndBody: (title: String, body: String) {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (String(lines.first ?? "Gannin"), body)
    }
}

enum HarnessWriteError: LocalizedError {
    /// Someone committed in between, twice.
    case headMoved(String)
    case invalidRepo(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .headMoved(let repo): "\(repo) changed while Gannin was writing to it, twice. Try again."
        case .invalidRepo(let repo): "\(repo) isn't owner/name."
        case .tooLarge(let path): "\(path) is over \(ByteCountFormatter.string(fromByteCount: Int64(HarnessChange.maxDataBytes), countStyle: .file)), more than Gannin commits through GitHub's API."
        }
    }
}

extension HarnessStore {
    /// Commits to the harness's branch (the default when none is picked),
    /// or, when its rules require a pull request, to a new branch with a
    /// pull request to it, merged right away if GitHub will have it;
    /// otherwise the PR is left for a look (`onPullRequestOpened`) and the
    /// commit isn't on the branch until it's merged by hand.
    /// `change` is given the head commit to build on; when the branch moves
    /// before the commit lands, it's asked again against the newer head and
    /// retried once. Callers confirm with the user first. The index is
    /// fetched again after (unless `refreshing` is off, for files it doesn't
    /// index, or the commit is still only on a pull request's branch), so
    /// what was written shows. Returns the new commit's ID, or nil when
    /// `change` found nothing to write.
    @discardableResult
    func commit(org: String, setup: HarnessConfig, refreshing: Bool = true, change: (_ head: String) async throws -> HarnessChange?) async throws -> String? {
        guard let api = auth.api else { throw APIError.unauthorized }
        let parts = setup.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw HarnessWriteError.invalidRepo(setup.repo) }
        for attempt in 0..<2 {
            let head = try await api.harnessHead(owner: parts[0], name: parts[1], branch: setup.branch)
            guard let planned = try await change(head.commit) else { return nil }
            do {
                var viaPullRequest = await requiresPullRequest(api: api, repo: setup.repo, branch: head.branch)
                if !viaPullRequest {
                    do {
                        let commit = try await api.createCommit(repo: setup.repo, branch: head.branch, expectedHead: head.commit, change: planned)
                        if refreshing { Task { await load(org: org, setup: setup, force: true, expecting: commit) } }
                        return commit
                    } catch let error as APIError where error.requiresPullRequest {
                        // Classic branch protection, or a ruleset added since
                        // the lookup, which the rules endpoint doesn't show.
                        pullRequestRequired["\(setup.repo)@\(head.branch)"] = true
                        viaPullRequest = true
                    }
                }
                let result = try await commitViaPullRequest(api: api, setup: setup, base: head, change: planned)
                if refreshing, result.onBase { Task { await load(org: org, setup: setup, force: true, expecting: result.commit) } }
                return result.commit
            } catch let error as APIError where error.isStaleHead && attempt == 0 {
                continue
            }
        }
        throw HarnessWriteError.headMoved(setup.repo)
    }

    /// Whether the branch's rules require changes through a pull request, so
    /// a direct commit would be refused; cached for the app's run. The
    /// lookup is advisory: when it fails for a reason other than the session
    /// or the rate limit (no permission to read rules, a network blip) a
    /// direct commit is tried, which reports GitHub's reason if it's refused,
    /// and the failure isn't cached.
    private func requiresPullRequest(api: GitHubAPI, repo: String, branch: String) async -> Bool {
        let key = "\(repo)@\(branch)"
        if let cached = pullRequestRequired[key] { return cached }
        guard let required = try? await api.branchRequiresPullRequest(repo: repo, branch: branch) else { return false }
        pullRequestRequired[key] = required
        return required
    }

    /// A new branch at `base`'s commit, the change committed to it, a pull
    /// request to `base.branch`, and an attempt to merge it right away (a
    /// user who can bypass the rules has it merged at once). The branch is
    /// cleaned up if making the commit or the pull request fails. Once the
    /// pull request exists the write is done: a merge GitHub won't take, or
    /// one that fails for any reason, leaves the PR open and notifies
    /// (`onPullRequestOpened`) rather than throwing, as a retry would open a
    /// second branch and pull request. A merged PR's branch is deleted.
    /// `onBase` says whether the commit landed on `base.branch` (merged) or
    /// is still only on the pull request's branch.
    private func commitViaPullRequest(api: GitHubAPI, setup: HarnessConfig, base: (branch: String, commit: String), change: HarnessChange) async throws -> (commit: String, onBase: Bool) {
        let (title, body) = change.titleAndBody
        var branch = Self.pullRequestBranchName(title: title)
        do {
            try await api.createRef(repo: setup.repo, branch: branch, sha: base.commit)
        } catch let error as APIError {
            // A name already taken: once more with another suffix.
            guard case .http(422, _) = error else { throw error }
            branch = Self.pullRequestBranchName(title: title)
            try await api.createRef(repo: setup.repo, branch: branch, sha: base.commit)
        }
        let commit: String
        let pr: (number: Int, url: URL)
        do {
            commit = try await api.createCommit(repo: setup.repo, branch: branch, expectedHead: base.commit, change: change)
            pr = try await api.createPullRequest(repo: setup.repo, base: base.branch, head: branch, title: title, body: body)
        } catch {
            try? await api.deleteRef(repo: setup.repo, branch: branch)
            throw error
        }
        do {
            let merged = try await api.mergePullRequest(repo: setup.repo, number: pr.number)
            try? await api.deleteRef(repo: setup.repo, branch: branch)
            return (merged, true)
        } catch {
            onPullRequestOpened?(setup.repo, pr.url, Self.mergeFailureNote(error))
            return (commit, false)
        }
    }

    /// Why a pull request is left open, for its notification, from the
    /// merge endpoint's refusal: 405 and 422 are GitHub saying it can't
    /// merge yet, with different reasons in the body; anything else
    /// (network, rate limit, a 5xx) means the outcome isn't known.
    static func mergeFailureNote(_ error: Error) -> String {
        guard case APIError.http(let status, let body) = error, status == 405 || status == 422 else {
            return "Gannin couldn't tell whether it merged. Check it on GitHub."
        }
        let text = body.lowercased()
        if text.contains("conflict") { return "It has a merge conflict to resolve." }
        if text.contains("merge commit") || text.contains("method") && text.contains("not allowed") {
            return "The repository doesn't allow Gannin's merge method. Merge it on GitHub."
        }
        return "Needs reviews or checks before Gannin's commit can land."
    }

    /// `gannin-<slug>-<8 hex>`: a new branch for a commit its branch's
    /// rules won't take directly.
    static func pullRequestBranchName(title: String) -> String {
        let slug = Slug.make(title, limit: 32)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return slug.isEmpty ? "gannin-\(suffix)" : "gannin-\(slug)-\(suffix)"
    }

    /// Files' texts at a commit, by path; nil for one that isn't there.
    func files(setup: HarnessConfig, at commit: String, paths: [String]) async throws -> [String: String?] {
        guard let api = auth.api else { throw APIError.unauthorized }
        let parts = setup.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw HarnessWriteError.invalidRepo(setup.repo) }
        let texts = try await api.harnessTexts(owner: parts[0], name: parts[1], expressions: paths.map { "\(commit):\($0)" })
        return Dictionary(uniqueKeysWithValues: zip(paths, texts).map { ($0, $1) })
    }
}

extension APIError {
    /// A direct commit refused because the branch's rules or protection
    /// require a pull request: classic protection says so by name, but a
    /// ruleset's refusal (GH013) just reports "repository rule
    /// violations" without naming the rule, so that's treated the same way.
    var requiresPullRequest: Bool {
        guard case .graphQL(let messages) = self else { return false }
        return messages.contains { $0.localizedCaseInsensitiveContains("pull request") || $0.localizedCaseInsensitiveContains("rule violation") }
    }

    /// `createCommitOnBranch` refusing because `expectedHeadOid` is no
    /// longer the branch's head.
    var isStaleHead: Bool {
        guard case .graphQL(let messages) = self else { return false }
        return messages.contains { $0.localizedCaseInsensitiveContains("expected branch") || $0.localizedCaseInsensitiveContains("expectedHeadOid") }
    }
}

extension GitHubAPI {
    /// One commit on a branch, several files at once, only if the branch is
    /// still at `expectedHead`. A write.
    func createCommit(repo: String, branch: String, expectedHead: String, change: HarnessChange) async throws -> String {
        struct Response: Decodable {
            struct Commit: Decodable { let oid: String }
            struct Payload: Decodable { let commit: Commit? }
            let createCommitOnBranch: Payload?
        }
        let (title, body) = change.titleAndBody
        var message: [String: Any] = ["headline": title]
        if !body.isEmpty { message["body"] = body }
        if let large = change.data.first(where: { $0.value.count > HarnessChange.maxDataBytes }) {
            throw HarnessWriteError.tooLarge(large.key)
        }
        let additions = change.files.compactMap { path, text in
            text.map { ["path": path, "contents": Data($0.utf8).base64EncodedString()] }
        } + change.data.map { path, data in ["path": path, "contents": data.base64EncodedString()] }
        let deletions = change.files.compactMap { path, text in text == nil ? ["path": path] : nil }
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": repo, "branchName": branch],
            "message": message,
            "expectedHeadOid": expectedHead,
            "fileChanges": ["additions": additions, "deletions": deletions],
        ]
        let (response, messages): (Response, [String]) = try await queryReportingReason("""
            mutation($input: CreateCommitOnBranchInput!) {
              createCommitOnBranch(input: $input) { commit { oid } }
            }
            """, values: ["input": input])
        guard let oid = response.createCommitOnBranch?.commit?.oid else {
            throw APIError.graphQL(messages.isEmpty ? ["GitHub didn't make the commit."] : messages)
        }
        return oid
    }

    /// Whether a ruleset on the branch requires changes to go through a
    /// pull request, so a direct commit would be refused.
    func branchRequiresPullRequest(repo: String, branch: String) async throws -> Bool {
        struct Rule: Decodable { let type: String }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        let rules: [Rule] = try await rest("repos/\(repo)/rules/branches/\(encoded)")
        return rules.contains { $0.type == "pull_request" }
    }

    /// Makes a new branch at a commit. A write.
    func createRef(repo: String, branch: String, sha: String) async throws {
        try await restWrite("POST", "repos/\(repo)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": sha])
    }

    /// Removes a branch.
    func deleteRef(repo: String, branch: String) async throws {
        try await restWrite("DELETE", "repos/\(repo)/git/refs/heads/\(branch)")
    }

    /// Opens a pull request. A write.
    func createPullRequest(repo: String, base: String, head: String, title: String, body: String) async throws -> (number: Int, url: URL) {
        struct Created: Decodable { let number: Int; let htmlUrl: URL }
        let created: Created = try await restWrite("POST", "repos/\(repo)/pulls", body: ["title": title, "head": head, "base": base, "body": body])
        return (created.number, created.htmlUrl)
    }

    /// Merges a pull request right away; throws when GitHub won't yet
    /// (checks pending, reviews required).
    func mergePullRequest(repo: String, number: Int) async throws -> String {
        struct Merged: Decodable { let sha: String }
        let merged: Merged = try await restWrite("PUT", "repos/\(repo)/pulls/\(number)/merge", body: [:])
        return merged.sha
    }
}
