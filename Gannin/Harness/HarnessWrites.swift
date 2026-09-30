import Foundation

/// A commit Gannin makes to the harness through the GitHub API, never
/// through a checkout: files added or replaced by path (nil removes one).
struct HarnessChange {
    var message: String
    var files: [String: String?]
}

enum HarnessWriteError: LocalizedError {
    /// Someone committed in between, twice.
    case headMoved(String)
    case invalidRepo(String)

    var errorDescription: String? {
        switch self {
        case .headMoved(let repo): "\(repo) changed while Gannin was writing to it, twice. Try again."
        case .invalidRepo(let repo): "\(repo) isn't owner/name."
        }
    }
}

extension HarnessStore {
    /// Commits to the harness's branch (the default when none is picked).
    /// `change` is given the head commit to build on; when the branch moves
    /// before the commit lands, it's asked again against the newer head and
    /// retried once. Callers confirm with the user first. The index is
    /// fetched again after (unless `refreshing` is off, for files it doesn't
    /// index), so what was written shows. Returns the new
    /// commit's ID, or nil when `change` found nothing to write.
    @discardableResult
    func commit(org: String, setup: HarnessConfig, refreshing: Bool = true, change: (_ head: String) async throws -> HarnessChange?) async throws -> String? {
        guard let api = auth.api else { throw APIError.unauthorized }
        let parts = setup.repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw HarnessWriteError.invalidRepo(setup.repo) }
        for attempt in 0..<2 {
            let head = try await api.harnessHead(owner: parts[0], name: parts[1], branch: setup.branch)
            guard let planned = try await change(head.commit) else { return nil }
            do {
                let commit = try await api.createCommit(repo: setup.repo, branch: head.branch, expectedHead: head.commit, change: planned)
                if refreshing { Task { await load(org: org, setup: setup, force: true) } }
                return commit
            } catch let error as APIError where error.isStaleHead && attempt == 0 {
                continue
            }
        }
        throw HarnessWriteError.headMoved(setup.repo)
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
        let lines = change.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var message: [String: Any] = ["headline": String(lines.first ?? "Gannin")]
        if lines.count > 1 {
            let body = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { message["body"] = body }
        }
        let additions = change.files.compactMap { path, text in
            text.map { ["path": path, "contents": Data($0.utf8).base64EncodedString()] }
        }
        let deletions = change.files.compactMap { path, text in text == nil ? ["path": path] : nil }
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": repo, "branchName": branch],
            "message": message,
            "expectedHeadOid": expectedHead,
            "fileChanges": ["additions": additions, "deletions": deletions],
        ]
        let response: Response = try await mutate("""
            mutation($input: CreateCommitOnBranchInput!) {
              createCommitOnBranch(input: $input) { commit { oid } }
            }
            """, variables: ["input": input])
        guard let oid = response.createCommitOnBranch?.commit?.oid else {
            throw APIError.graphQL(["GitHub didn't make the commit."])
        }
        return oid
    }
}
