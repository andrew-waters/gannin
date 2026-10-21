import Foundation

extension GitHubAPI {
    /// Adds and removes assignees on an issue, by login. Adds go first, so a
    /// failure there leaves the issue as it was. A write.
    func setAssignees(issueID: String, add: [String], remove: [String]) async throws {
        // Both lookups come before any write, so a login that can't be
        // found changes nothing.
        let addIDs = try await assigneeIDs(add)
        let removeIDs = try await assigneeIDs(remove)
        if !addIDs.isEmpty {
            // Nullable, so an empty Response would decode past a refusal (no
            // write access) rather than surfacing it.
            struct Response: Decodable {
                struct Payload: Decodable { let clientMutationId: String? }
                let addAssigneesToAssignable: Payload
            }
            let _: Response = try await mutate("""
                mutation($issue: ID!, $users: [ID!]!) {
                  addAssigneesToAssignable(input: { assignableId: $issue, assigneeIds: $users }) { clientMutationId }
                }
                """, variables: ["issue": issueID, "users": addIDs])
        }
        if !removeIDs.isEmpty {
            struct Response: Decodable {
                struct Payload: Decodable { let clientMutationId: String? }
                let removeAssigneesFromAssignable: Payload
            }
            let _: Response = try await mutate("""
                mutation($issue: ID!, $users: [ID!]!) {
                  removeAssigneesFromAssignable(input: { assignableId: $issue, assigneeIds: $users }) { clientMutationId }
                }
                """, variables: ["issue": issueID, "users": removeIDs])
        }
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
