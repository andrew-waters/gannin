import Foundation

extension GitHubAPI {
    /// GitHub's limit on an issue's assignees.
    static let maxAssignees = 10

    /// Assigns people to an issue, by login, and returns who is assigned
    /// afterwards as GitHub reports it: it silently skips someone who can't
    /// be assigned on the issue's repo, so a login missing from the result
    /// wasn't assigned. A write.
    func addAssignees(issueID: String, logins: [String]) async throws -> [String] {
        // Looked up before writing, so a login that can't be found changes nothing.
        let ids = try await assigneeIDs(logins)
        struct Response: Decodable {
            struct Payload: Decodable { let assignable: Assigned? }
            let addAssigneesToAssignable: Payload
        }
        let response: Response = try await mutate("""
            mutation($issue: ID!, $users: [ID!]!) {
              addAssigneesToAssignable(input: { assignableId: $issue, assigneeIds: $users }) {
                assignable { assignees(first: \(Self.maxAssignees)) { nodes { login } } }
              }
            }
            """, variables: ["issue": issueID, "users": ids])
        return try Self.logins(response.addAssigneesToAssignable.assignable)
    }

    /// Takes people off an issue, and returns who is assigned afterwards. A write.
    func removeAssignees(issueID: String, logins: [String]) async throws -> [String] {
        let ids = try await assigneeIDs(logins)
        struct Response: Decodable {
            struct Payload: Decodable { let assignable: Assigned? }
            let removeAssigneesFromAssignable: Payload
        }
        let response: Response = try await mutate("""
            mutation($issue: ID!, $users: [ID!]!) {
              removeAssigneesFromAssignable(input: { assignableId: $issue, assigneeIds: $users }) {
                assignable { assignees(first: \(Self.maxAssignees)) { nodes { login } } }
              }
            }
            """, variables: ["issue": issueID, "users": ids])
        return try Self.logins(response.removeAssigneesFromAssignable.assignable)
    }

    private struct Assigned: Decodable {
        struct Login: Decodable { let login: String }
        let assignees: Connection<Login>
    }

    /// An empty payload is how a refusal (no write access) comes back, so it
    /// must not read as "no assignees".
    private static func logins(_ assigned: Assigned?) throws -> [String] {
        guard let assigned else { throw APIError.graphQL(["GitHub didn't change the assignees; you may not have write access"]) }
        return assigned.assignees.nodes.map(\.login)
    }

    /// `userIDs` leaves out a login it can't find; for a write that has to be
    /// an error, or the person would be silently left off.
    private func assigneeIDs(_ logins: [String]) async throws -> [String] {
        let ids = try await userIDs(logins)
        if let missing = logins.first(where: { ids[$0] == nil }) {
            throw APIError.graphQL(["Couldn't find \(missing)"])
        }
        return logins.compactMap { ids[$0] }
    }
}
