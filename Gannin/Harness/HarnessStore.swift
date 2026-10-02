import Foundation
import Observation

/// Each org's harness, indexed from GitHub and cached on disk. A fetch asks
/// for the default branch's head commit and stops there if it's the one
/// indexed; otherwise it lists the tree (one REST call) and fetches only the
/// documents whose blobs changed, 30 to a GraphQL query.
@Observable
final class HarnessStore {
    private static let maxAge: TimeInterval = 10 * 60
    private static let batchSize = 30

    /// By `key(org, repo)`: an org can have several harnesses.
    private(set) var indexes: [String: HarnessIndex] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private var combinedCache: [String: (key: String, index: HarnessIndex)] = [:]
    /// Every repo in the org that isn't archived, by name, for picking the
    /// harness from.
    private(set) var repositories: [String: [String]] = [:]

    @ObservationIgnored private var fetches: [String: Task<Void, Never>] = [:]
    let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
        // Every cached index at once: the team's data in them is the org's
        // settings, needed before any page asks for the harness.
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let index = try? Self.decoder.decode(HarnessIndex.self, from: data) {
                // `org@owner~name.json`, or `org.json` from when an org had one.
                let name = file.deletingPathExtension().lastPathComponent
                let org = name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name
                let indexKey = Self.key(org, index.repo)
                if indexes[indexKey] == nil || name.contains("@") { indexes[indexKey] = index }
            }
        }
    }

    static func key(_ org: String, _ repo: String) -> String { "\(org)|\(repo)" }

    /// The org's index for a harness; nil until loaded, or when its branch
    /// has changed since.
    func index(for org: String, _ setup: HarnessConfig) -> HarnessIndex? {
        indexes[Self.key(org, setup.repo)].flatMap { $0.requestedBranch == setup.branch ? $0 : nil }
    }

    /// Whatever's indexed for the harness repo, whichever branch.
    func anyIndex(org: String, repo: String) -> HarnessIndex? { indexes[Self.key(org, repo)] }

    func isLoading(_ org: String, _ setup: HarnessConfig) -> Bool { loading.contains(Self.key(org, setup.repo)) }

    func error(_ org: String, _ setup: HarnessConfig) -> String? { errors[Self.key(org, setup.repo)] }

    /// Every harness of the org as one index: the primary's, with the
    /// others' documents under `owner/name:` paths. Nil until the primary
    /// (else the first) is loaded.
    func combined(org: String, _ harnesses: [HarnessConfig]) -> HarnessIndex? {
        let loaded = harnesses.compactMap { index(for: org, $0) }
        guard let first = loaded.first else { return nil }
        guard loaded.count > 1 else { return first }
        let cacheKey = loaded.map { "\($0.repo)@\($0.commit)@\($0.fetchedAt.timeIntervalSince1970)" }.joined(separator: ",")
        if let cached = combinedCache[org], cached.key == cacheKey { return cached.index }
        let merged = first.combined(with: Array(loaded.dropFirst()))
        combinedCache[org] = (cacheKey, merged)
        return merged
    }

    /// From disk at once, then from GitHub when stale (or `force`). The
    /// fetch is the store's, not the caller's: a view going away (as Settings
    /// redraws once a harness is picked) mustn't cancel it half done, and a
    /// second caller waits on the fetch already running.
    func load(org: String, setup: HarnessConfig, force: Bool = false) async {
        let indexKey = Self.key(org, setup.repo)
        loadCached(org, repo: setup.repo)
        if !force, let index = index(for: org, setup), -index.fetchedAt.timeIntervalSinceNow < Self.maxAge { return }
        if let running = fetches[indexKey] {
            await running.value
            // A forced fetch (after a commit, say) wants what's there now,
            // which the running one may have started before.
            guard force else { return }
            if let again = fetches[indexKey] {
                await again.value
                return
            }
        }
        guard let api = auth.api else { return }
        // Unchanged blobs are kept from whatever was indexed before, even
        // another branch.
        let previous = indexes[indexKey]
        loading.insert(indexKey)
        let task = Task {
            defer {
                loading.remove(indexKey)
                fetches[indexKey] = nil
            }
            do {
                indexes[indexKey] = try await Self.fetch(setup: setup, previous: previous, api: api)
                errors[indexKey] = nil
                save(org, repo: setup.repo)
            } catch APIError.unauthorized {
                auth.signOut()
            } catch {
                errors[indexKey] = error.localizedDescription
            }
        }
        fetches[indexKey] = task
        await task.value
    }

    /// Every harness the org has.
    func loadAll(org: String, _ harnesses: [HarnessConfig], force: Bool = false) async {
        // Each fetch runs as the store's own task, so starting them all
        // first lets them go side by side.
        let tasks = harnesses.map { setup in Task { await load(org: org, setup: setup, force: force) } }
        for task in tasks { await task.value }
    }

    /// A repo's branches, and which is its default, once a launch.
    private(set) var branches: [String: (all: [String], defaultBranch: String?)] = [:]

    func loadBranches(repo: String) async {
        let parts = repo.split(separator: "/").map(String.init)
        guard branches[repo] == nil, parts.count == 2, let api = auth.api else { return }
        if let result = try? await api.branchNames(owner: parts[0], name: parts[1]) {
            branches[repo] = result
        }
    }

    /// The org's repos, once a launch.
    func loadRepositories(org: String) async {
        guard repositories[org] == nil, let api = auth.api else { return }
        if let names = try? await api.repositoryNames(org: org) {
            repositories[org] = names
        }
    }

    private static func fetch(setup: HarnessConfig, previous: HarnessIndex?, api: GitHubAPI) async throws -> HarnessIndex {
        let repo = setup.repo
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw APIError.graphQL(["\(repo) isn't owner/name."]) }
        let head = try await api.harnessHead(owner: parts[0], name: parts[1], branch: setup.branch)
        // Documents indexed by an older reading of them are read again.
        let reusable = previous?.parserVersion == HarnessDocument.parserVersion ? previous : previous.map {
            HarnessIndex(parserVersion: nil, repo: $0.repo, requestedBranch: $0.requestedBranch, branch: $0.branch, commit: $0.commit, fetchedAt: $0.fetchedAt, documents: [], dataFiles: $0.dataFiles)
        }
        if var previous = reusable, previous.commit == head.commit, previous.requestedBranch == setup.branch, previous.dataFiles != nil, previous.parserVersion != nil {
            previous.fetchedAt = .now
            return previous
        }
        let tree = try await api.harnessTree(repo: repo, commit: head.commit)
        let wanted = tree.compactMap { entry in HarnessKind(path: entry.path).map { (entry, $0) } }
        let known = Dictionary((reusable?.documents ?? []).map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })

        // The team's data, unchanged files kept from before.
        let knownData = Dictionary((previous?.dataFiles ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var dataFiles: [HarnessDataFile] = []
        var missingData: [HarnessTreeEntry] = []
        for entry in tree where HarnessDataFile.isData(entry.path) {
            if let file = knownData[entry.path], file.sha == entry.sha { dataFiles.append(file) } else { missingData.append(entry) }
        }
        for start in stride(from: 0, to: missingData.count, by: Self.batchSize) {
            let batch = Array(missingData[start..<min(start + Self.batchSize, missingData.count)])
            let texts = try await api.harnessTexts(owner: parts[0], name: parts[1], expressions: batch.map { "\(head.commit):\($0.path)" })
            dataFiles += zip(batch, texts).compactMap { entry, text in text.map { HarnessDataFile(path: entry.path, sha: entry.sha, text: $0) } }
        }
        dataFiles.sort { $0.path < $1.path }

        var documents: [HarnessDocument] = []
        var missing: [(HarnessTreeEntry, HarnessKind)] = []
        for (entry, kind) in wanted {
            if let document = known[entry.sha], document.path == entry.path {
                documents.append(document)
            } else {
                missing.append((entry, kind))
            }
        }
        for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
            let batch = Array(missing[start..<min(start + Self.batchSize, missing.count)])
            let texts = try await api.harnessTexts(owner: parts[0], name: parts[1], expressions: batch.map { "\(head.commit):\($0.0.path)" })
            let fetched = zip(batch, texts).compactMap { item, text in text.map { (item.0.path, item.0.sha, item.1, $0) } }
            // Reading the documents is string work: off the main thread.
            documents += await Task.detached {
                fetched.map { HarnessDocument(path: $0.0, sha: $0.1, kind: $0.2, text: $0.3) }
            }.value
        }
        documents.sort { $0.path < $1.path }
        return HarnessIndex(parserVersion: HarnessDocument.parserVersion, repo: repo, requestedBranch: setup.branch, branch: head.branch, commit: head.commit, fetchedAt: .now, documents: documents, dataFiles: dataFiles)
    }

    func clear() {
        indexes = [:]
        errors = [:]
        combinedCache = [:]
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Disk cache

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Harness", directoryHint: .isDirectory)
    }

    private static func fileURL(_ org: String, repo: String) -> URL {
        directory.appending(path: "\(org)@\(repo.replacingOccurrences(of: "/", with: "~")).json")
    }

    private func loadCached(_ org: String, repo: String) {
        let indexKey = Self.key(org, repo)
        guard indexes[indexKey] == nil,
              let data = try? Data(contentsOf: Self.fileURL(org, repo: repo)),
              let index = try? Self.decoder.decode(HarnessIndex.self, from: data) else { return }
        indexes[indexKey] = index
    }

    private func save(_ org: String, repo: String) {
        guard let index = indexes[Self.key(org, repo)] else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(index) {
            try? data.write(to: Self.fileURL(org, repo: repo), options: .atomic)
            // The file from when an org had one harness.
            try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(org).json"))
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated struct HarnessTreeEntry: Decodable, Sendable {
    let path: String
    let type: String
    let sha: String
}

extension GitHubAPI {
    /// Every repo in the org that isn't archived, by name.
    func repositoryNames(org: String) async throws -> [String] {
        struct Node: Decodable { let nameWithOwner: String }
        struct Response: Decodable {
            struct Org: Decodable { let repositories: PagedConnection<Node> }
            let organization: Org?
        }
        let nodes: [Node] = try await paginate(limit: 2000) { cursor in
            var variables = ["login": org]
            if let cursor { variables["cursor"] = cursor }
            let response: Response = try await query("""
                query($login: String!, $cursor: String) {
                  \(GitHubAccounts.ownerField(org)) {
                    repositories(first: 100, after: $cursor, isArchived: false, orderBy: { field: NAME, direction: ASC }\(GitHubAccounts.repositoryArguments(org))) {
                      pageInfo { hasNextPage endCursor }
                      nodes { nameWithOwner }
                    }
                  }
                }
                """, variables: variables)
            return response.organization?.repositories
        }
        return nodes.map(\.nameWithOwner).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The harness branch (the default when nil) and its head commit.
    func harnessHead(owner: String, name: String, branch: String?) async throws -> (branch: String, commit: String) {
        struct Response: Decodable {
            struct Target: Decodable { let oid: String }
            struct Ref: Decodable { let name: String; let target: Target }
            struct Repository: Decodable { let defaultBranchRef: Ref?; let ref: Ref? }
            let repository: Repository?
        }
        var variables = ["owner": owner, "name": name]
        let selection: String
        if let branch {
            variables["ref"] = "refs/heads/\(branch)"
            selection = "ref(qualifiedName: $ref) { name target { oid } }"
        } else {
            selection = "defaultBranchRef { name target { oid } }"
        }
        let response: Response = try await query("""
            query($owner: String!, $name: String!\(branch == nil ? "" : ", $ref: String!")) {
              repository(owner: $owner, name: $name) { \(selection) }
            }
            """, variables: variables)
        guard let ref = branch == nil ? response.repository?.defaultBranchRef : response.repository?.ref else {
            throw APIError.graphQL([branch.map { "Couldn't find the branch \($0) in \(owner)/\(name)." } ?? "Couldn't find \(owner)/\(name), or it has no default branch."])
        }
        return (ref.name, ref.target.oid)
    }

    /// A repo's branches by name, and its default.
    func branchNames(owner: String, name: String) async throws -> (all: [String], defaultBranch: String?) {
        struct Node: Decodable { let name: String }
        struct Ref: Decodable { let name: String }
        struct Response: Decodable {
            struct Repository: Decodable { let refs: PagedConnection<Node>; let defaultBranchRef: Ref? }
            let repository: Repository?
        }
        var defaultBranch: String?
        let nodes: [Node] = try await paginate(limit: 1000) { cursor in
            var variables = ["owner": owner, "name": name]
            if let cursor { variables["cursor"] = cursor }
            let response: Response = try await query("""
                query($owner: String!, $name: String!, $cursor: String) {
                  repository(owner: $owner, name: $name) {
                    defaultBranchRef { name }
                    refs(refPrefix: "refs/heads/", first: 100, after: $cursor, orderBy: { field: ALPHABETICAL, direction: ASC }) {
                      pageInfo { hasNextPage endCursor }
                      nodes { name }
                    }
                  }
                }
                """, variables: variables)
            defaultBranch = defaultBranch ?? response.repository?.defaultBranchRef?.name
            return response.repository?.refs
        }
        return (nodes.map(\.name), defaultBranch)
    }

    /// Every file at the commit, from REST's recursive tree listing.
    func harnessTree(repo: String, commit: String) async throws -> [HarnessTreeEntry] {
        struct Response: Decodable {
            let tree: [HarnessTreeEntry]
            let truncated: Bool
        }
        let response: Response = try await rest("repos/\(repo)/git/trees/\(commit)", query: ["recursive": "1"])
        return response.tree.filter { $0.type == "blob" }
    }

    /// Blob texts by `commit:path` expression, in order; nil for anything
    /// that isn't text.
    func harnessTexts(owner: String, name: String, expressions: [String]) async throws -> [String?] {
        struct Blob: Decodable { let text: String? }
        struct Response: Decodable { let repository: [String: Blob?]? }
        var variables = ["owner": owner, "name": name]
        var declarations = ["$owner: String!", "$name: String!"]
        var selections: [String] = []
        for (index, expression) in expressions.enumerated() {
            variables["e\(index)"] = expression
            declarations.append("$e\(index): String!")
            selections.append("f\(index): object(expression: $e\(index)) { ... on Blob { text } }")
        }
        let response: Response = try await query("""
            query(\(declarations.joined(separator: ", "))) {
              repository(owner: $owner, name: $name) {
                \(selections.joined(separator: "\n    "))
              }
            }
            """, variables: variables)
        return expressions.indices.map { response.repository?["f\($0)"].flatMap { $0 }?.text }
    }
}
