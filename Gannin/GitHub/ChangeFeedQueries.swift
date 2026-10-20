import Foundation

extension GitHubAPI {
    /// The PRs and issues updated since `since`, for the account's own repos
    /// and each batch of outside repos: node ID, state, repo and `updatedAt`
    /// only, so a page costs far less than a store's own shape. `capped` is
    /// whether any search reached GitHub's 1000-result limit, which leaves
    /// updates out.
    func changeEntries(org: String, outsideBatches: [[String]], since: Date) async throws -> (entries: [ChangeEntry], capped: Bool) {
        let stamp = since.formatted(.iso8601).replacingOccurrences(of: "Z", with: "+00:00")
        var scopes = [(scope: "\(GitHubAccounts.scope(org)) archived:false", isOutside: false)]
        for batch in outsideBatches {
            scopes.append((scope: "\(batch.map { "repo:\($0)" }.joined(separator: " ")) archived:false", isOutside: true))
        }
        var entries: [ChangeEntry] = []
        var capped = false
        for (scope, isOutside) in scopes {
            async let prs = changeSearch("\(scope) is:pr updated:>=\(stamp)", kind: .pullRequest, isOutside: isOutside)
            async let issues = changeSearch("\(scope) is:issue updated:>=\(stamp)", kind: .issue, isOutside: isOutside)
            let (prEntries, issueEntries) = try await (prs, issues)
            capped = capped || prEntries.count >= ParallelSearches.searchCap || issueEntries.count >= ParallelSearches.searchCap
            entries += prEntries + issueEntries
        }
        return (entries, capped)
    }

    private func changeSearch(_ query: String, kind: ChangeEntry.Kind, isOutside: Bool) async throws -> [ChangeEntry] {
        let nodes: [Lossy<RawChange>] = try await search(query, fields: RawChange.fields)
        return nodes.compactMap { $0.value }.map {
            ChangeEntry(id: $0.id, kind: kind, state: $0.state, repo: $0.repository.nameWithOwner, updatedAt: $0.updatedAt, isOutside: isOutside)
        }
    }

    /// Nodes by ID, `batchSize` at a time, at most `ParallelSearches.concurrency`
    /// batches at once, each decoded as `Node` (the fields name the shape).
    /// An ID that isn't a node of that type is left out; `model` maps what's decoded.
    func nodes<Node: Decodable, Result: Sendable>(
        ids: [String],
        fields: String,
        batchSize: Int,
        progress: @escaping (Int, Int?) -> Void = { _, _ in },
        model: @escaping @MainActor @Sendable (Node) -> Result
    ) async throws -> [Result] {
        let batches = stride(from: 0, to: ids.count, by: batchSize).map { Array(ids[$0..<min($0 + batchSize, ids.count)]) }
        return try await ParallelSearches.run(count: batches.count, progress: progress) { index, fetched in
            let response: NodesResponse<Node> = try await self.query(
                "query($ids: [ID!]!) { nodes(ids: $ids) { \(fields) } }",
                values: ["ids": batches[index]]
            )
            let found = response.nodes.compactMap { $0?.value }.map(model)
            fetched(found.count)
            return found
        }
    }
}

private struct NodesResponse<Node: Decodable>: Decodable { let nodes: [Lossy<Node>?] }

private struct RawChange: Decodable {
    struct Repository: Decodable { let nameWithOwner: String }

    let id: String
    let state: String
    let updatedAt: Date
    let repository: Repository

    static let fields = """
        ... on PullRequest { id state updatedAt repository { nameWithOwner } }
        ... on Issue { id state updatedAt repository { nameWithOwner } }
        """
}
