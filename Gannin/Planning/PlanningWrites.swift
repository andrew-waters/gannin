import Foundation

/// Issue writes for planning: closing one, creating one, and making one a
/// sub-issue of another. Every one is confirmed by the caller first.
extension GitHubAPI {
    /// Closes the issue as completed. A write.
    func closeIssue(id: String) async throws {
        // closeIssue is nullable: GitHub refusing (no write access, an
        // outside repo gone read-only) leaves it null alongside an error,
        // which an empty Response would decode past silently.
        struct Response: Decodable {
            struct Payload: Decodable { struct Issue: Decodable { let id: String }; let issue: Issue }
            let closeIssue: Payload
        }
        let _: Response = try await mutate("""
            mutation($issue: ID!) {
              closeIssue(input: { issueId: $issue, stateReason: COMPLETED }) { issue { id } }
            }
            """, variables: ["issue": id])
    }

    /// A new issue in the repo, with any of its labels that exist there.
    /// Returns its node ID, number and URL. A write.
    func createIssue(repo: String, title: String, body: String, labels: [String] = [], assigneeIDs: [String] = []) async throws -> (id: String, number: Int, url: URL) {
        struct Repository: Decodable {
            struct Node: Decodable {
                struct Labels: Decodable {
                    struct Label: Decodable { let id: String; let name: String }
                    let nodes: [Label]
                }
                let id: String
                let labels: Labels
            }
            let repository: Node?
        }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw APIError.graphQL(["\(repo) isn't owner/name"]) }
        let found: Repository = try await query("""
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) { id labels(first: 100) { nodes { id name } } }
            }
            """, values: ["owner": parts[0], "name": parts[1]])
        guard let repository = found.repository else { throw APIError.graphQL(["Couldn't find \(repo)"]) }
        let wanted = Set(labels.map { $0.lowercased() })
        let labelIDs = repository.labels.nodes.filter { wanted.contains($0.name.lowercased()) }.map(\.id)

        struct Created: Decodable {
            struct Payload: Decodable {
                struct Issue: Decodable { let id: String; let number: Int; let url: URL }
                let issue: Issue
            }
            let createIssue: Payload
        }
        var input: [String: Any] = ["repositoryId": repository.id, "title": title, "body": body]
        if !labelIDs.isEmpty { input["labelIds"] = labelIDs }
        if !assigneeIDs.isEmpty { input["assigneeIds"] = assigneeIDs }
        let created: Created = try await mutate("""
            mutation($input: CreateIssueInput!) {
              createIssue(input: $input) { issue { id number url } }
            }
            """, variables: ["input": input])
        return (created.createIssue.issue.id, created.createIssue.issue.number, created.createIssue.issue.url)
    }

    /// Of `repos` (`owner/name`), those that won't take a new issue
    /// (issues turned off, or archived), lowercased, 50 to a query. A repo
    /// this token can't read isn't among them, so `createIssue` reports it,
    /// and a batch that fails filters nothing. A read.
    func reposWithIssuesOff(_ repos: [String]) async -> Set<String> {
        let pairs = repos.compactMap { repo -> (owner: String, name: String)? in
            let parts = repo.split(separator: "/").map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        var off: Set<String> = []
        for start in stride(from: 0, to: pairs.count, by: 50) {
            var values: [String: Any] = [:]
            var fields: [String] = []
            var arguments: [String] = []
            for (index, pair) in pairs[start..<min(start + 50, pairs.count)].enumerated() {
                values["o\(index)"] = pair.owner
                values["n\(index)"] = pair.name
                arguments.append("$o\(index): String!, $n\(index): String!")
                fields.append("r\(index): repository(owner: $o\(index), name: $n\(index)) { nameWithOwner hasIssuesEnabled isArchived }")
            }
            let answer: ([String: IssuesEnabledNode?], [String: String])? = try? await queryReportingReasonsByField(
                "query(\(arguments.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}", values: values)
            if let answer { off.formUnion(IssuesEnabledNode.closed(answer.0)) }
        }
        return off
    }

    /// Makes `child` a sub-issue of `parent`. A write.
    func addSubIssue(parent: String, child: String) async throws {
        // Nullable, as closeIssue is: an empty Response would mask a
        // refusal rather than surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { struct Issue: Decodable { let id: String }; let issue: Issue }
            let addSubIssue: Payload
        }
        let _: Response = try await mutate("""
            mutation($parent: ID!, $child: ID!) {
              addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { id } }
            }
            """, variables: ["parent": parent, "child": child])
    }

    /// The issue's description and type name, read fresh so an append
    /// builds on what's there now. A read.
    func issueBodyAndType(id: String) async throws -> (body: String, type: String?) {
        struct Response: Decodable {
            struct Node: Decodable {
                struct IssueType: Decodable { let name: String }
                let body: String?
                let issueType: IssueType?
            }
            let node: Node?
        }
        let found: Response = try await query("""
            query($id: ID!) {
              node(id: $id) { ... on Issue { body issueType { name } } }
            }
            """, variables: ["id": id])
        guard let node = found.node else { throw APIError.graphQL(["Couldn't read the issue"]) }
        return (node.body ?? "", node.issueType?.name)
    }

    /// Replaces an issue's description. A write.
    func setIssueBody(id: String, body: String) async throws {
        // updateIssue is nullable, as closeIssue is: an empty Response would
        // mask a refusal rather than surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { struct Issue: Decodable { let id: String }; let issue: Issue }
            let updateIssue: Payload
        }
        let _: Response = try await mutate("""
            mutation($issue: ID!, $body: String!) {
              updateIssue(input: { id: $issue, body: $body }) { issue { id } }
            }
            """, variables: ["issue": id, "body": body])
    }

    /// Comments on an issue or pull request. A write.
    func addComment(subjectID: String, body: String) async throws {
        // addComment is nullable: GitHub refusing (no write access, an
        // outside repo gone read-only) leaves it null alongside an error,
        // which an empty Response would decode past silently.
        struct Response: Decodable {
            struct Payload: Decodable { struct Subject: Decodable { let id: String }; let subject: Subject }
            let addComment: Payload
        }
        let _: Response = try await mutate("""
            mutation($subject: ID!, $body: String!) {
              addComment(input: { subjectId: $subject, body: $body }) { subject { id } }
            }
            """, variables: ["subject": subjectID, "body": body])
    }
}

/// A repo in `reposWithIssuesOff`'s answer. Every field is optional so the
/// `rateLimit` GitHub answers beside the aliases decodes too, to all nils.
struct IssuesEnabledNode: Decodable {
    let nameWithOwner: String?
    let hasIssuesEnabled: Bool?
    let isArchived: Bool?

    /// The repos in `response` that won't take a new issue, lowercased.
    static func closed(_ response: [String: IssuesEnabledNode?]) -> Set<String> {
        Set(response.values.compactMap { node in
            guard let node, let name = node.nameWithOwner, node.hasIssuesEnabled == false || node.isArchived == true else { return nil }
            return name.lowercased()
        })
    }
}
