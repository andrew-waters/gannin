import Foundation

// Asking people to review a PR, and withdrawing the ask, from the PR
// drawer's reviewer picker. REST takes logins, where GraphQL's
// `requestReviews` wants node IDs the snapshot doesn't keep.
extension GitHubAPI {
    private struct Ignored: Decodable {}

    func requestReviewers(repo: String, number: Int, adding: [String], removing: [String]) async throws {
        let path = "repos/\(repo)/pulls/\(number)/requested_reviewers"
        if !adding.isEmpty {
            let _: Ignored = try await restWrite("POST", path, body: ["reviewers": adding])
        }
        if !removing.isEmpty {
            let _: Ignored = try await restWrite("DELETE", path, body: ["reviewers": removing])
        }
    }

    /// GitHub's suggested reviewers for a PR (from who's changed the same
    /// code), as its sidebar lists them.
    func suggestedReviewers(pullRequestID id: String) async throws -> [Person] {
        struct Actor: Decodable { let login: String; let name: String?; let avatarUrl: URL? }
        struct Suggestion: Decodable { let reviewer: Actor? }
        struct Node: Decodable { let suggestedReviewers: [Suggestion]? }
        struct Response: Decodable { let node: Node? }
        let response: Response = try await query("""
            query($id: ID!) {
              node(id: $id) {
                ... on PullRequest { suggestedReviewers { reviewer { login name avatarUrl } } }
              }
            }
            """, variables: ["id": id])
        return (response.node?.suggestedReviewers ?? []).compactMap(\.reviewer).map {
            Person(login: $0.login, name: $0.name, avatarUrl: $0.avatarUrl)
        }
    }
}
