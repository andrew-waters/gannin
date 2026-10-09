import Foundation

/// Where a Work on This session runs (andrew-waters/gannin#8, R3, R8): in a
/// sandbox by default once sandboxing is on, unless one of its repos needs
/// the Mac or the org has no GitHub token for sandboxes, each said in
/// plain words. The user can still pick the Mac when it starts.
nonisolated enum SandboxPlacement: Equatable, Sendable {
    case sandboxed
    /// On the Mac (or the Connect with server, as before), and why when
    /// sandboxing is on; nil when it's off.
    case host(String?)

    var isSandboxed: Bool { self == .sandboxed }

    var reason: String? {
        if case .host(let reason) = self { return reason }
        return nil
    }

    /// - Parameters:
    ///   - repos: the issue's repo and its linked PRs' repos.
    ///   - reposNeedingMac: those marked Needs the Mac in the org's settings.
    static func decide(enabled: Bool, repos: [String], reposNeedingMac: Set<String>, org: String, hasGitHubToken: Bool) -> SandboxPlacement {
        guard enabled else { return .host(nil) }
        if let repo = repos.first(where: reposNeedingMac.contains) {
            return .host("\(repo) is marked Needs the Mac, so this session runs on the Mac rather than in a sandbox.")
        }
        guard hasGitHubToken else {
            return .host("There's no GitHub token for sandboxes in \(org) yet. Add one in \(org)'s Settings, under Harness, to run its sessions in a sandbox.")
        }
        return .sandboxed
    }

    /// Why a session the user started on the Mac by choice runs there.
    static let pickedHost = "Started on the Mac by choice rather than in a sandbox."

    /// The container a session's issue runs in: one per issue, which its
    /// helpers share.
    static func containerName(for id: UUID) -> String {
        "gannin-" + id.uuidString.lowercased()
    }
}
