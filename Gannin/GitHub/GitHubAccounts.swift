import Foundation
import os

/// Which of the accounts Gannin shows are personal ones rather than orgs.
/// Everything else keys an account by its login and needn't care; the
/// queries ask here how to scope a search (`user:` or `org:`) and which
/// GraphQL owner to read (`user` or `organization`, aliased so responses
/// decode the same). Kept on disk so it's known before the org list loads.
nonisolated enum GitHubAccounts {
    private static let key = "personalAccounts"
    private static let state = OSAllocatedUnfairLock(initialState: Set(UserDefaults.standard.stringArray(forKey: key) ?? []))

    static func isUser(_ login: String) -> Bool {
        state.withLock { $0.contains(login) }
    }

    static func setUsers(_ logins: Set<String>) {
        state.withLock { $0 = logins }
        UserDefaults.standard.set(logins.sorted(), forKey: key)
    }

    /// The search qualifier for everything the account owns.
    static func scope(_ login: String) -> String {
        isUser(login) ? "user:\(login)" : "org:\(login)"
    }

    /// The owner field for a query with `$login`, as `organization` either
    /// way: users have the same repositories and project boards.
    static func ownerField(_ login: String) -> String {
        isUser(login) ? "organization: user(login: $login)" : "organization(login: $login)"
    }

    /// For `repositories(...)`: a user's own, not those they collaborate on.
    static func repositoryArguments(_ login: String) -> String {
        isUser(login) ? ", ownerAffiliations: [OWNER]" : ""
    }
}
