import Foundation

/// Issue writes for planning: closing one, creating one, and making one a
/// sub-issue of another. Every one is confirmed by the caller first.
extension GitHubAPI {
    /// Closes the issue as completed. A write.
    func closeIssue(id: String) async throws {
        struct Response: Decodable {}
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

    /// Makes `child` a sub-issue of `parent`. A write.
    func addSubIssue(parent: String, child: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await mutate("""
            mutation($parent: ID!, $child: ID!) {
              addSubIssue(input: { issueId: $parent, subIssueId: $child }) { issue { id } }
            }
            """, variables: ["parent": parent, "child": child])
    }

    /// Comments on an issue or pull request. A write.
    func addComment(subjectID: String, body: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await mutate("""
            mutation($subject: ID!, $body: String!) {
              addComment(input: { subjectId: $subject, body: $body }) { subject { id } }
            }
            """, variables: ["subject": subjectID, "body": body])
    }
}
