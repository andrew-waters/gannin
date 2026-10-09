import SwiftUI

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
    ///   - connectsBySSH: false when sessions run through a Connect with
    ///     command that isn't ssh, which can't be handed credentials.
    static func decide(enabled: Bool, repos: [String], reposNeedingMac: Set<String>, org: String, hasGitHubToken: Bool, connectsBySSH: Bool = true) -> SandboxPlacement {
        guard enabled else { return .host(nil) }
        guard connectsBySSH else {
            return .host("Settings' Connect with command isn't ssh, so Gannin can't hand a sandbox its credentials there. This session runs on the server unsandboxed.")
        }
        if let repo = repos.first(where: reposNeedingMac.contains) {
            return .host("\(repo) is marked Needs the Mac, so this session runs on the Mac rather than in a sandbox.")
        }
        guard hasGitHubToken else {
            return .host("There's no GitHub token for sandboxes in \(org) yet. Add one in \(org)'s Settings, under Harness, to run its sessions in a sandbox.")
        }
        return .sandboxed
    }

    /// Why a session started before sandboxing was turned on stays where it is.
    static let startedBefore = "Started before sandboxing was turned on, so it stays where its conversation is. Finish it and work on the issue again to run it in a sandbox."

    /// Why a session the user started on the Mac by choice runs there.
    static let pickedHost = "Started on the Mac by choice rather than in a sandbox."

    /// The container a session's issue runs in: one per issue, which its
    /// helpers share.
    static func containerName(for id: UUID) -> String {
        "gannin-" + id.uuidString.lowercased()
    }
}

/// A sandbox's state as a session shows it (R14), from what its start
/// script wrote (`starting`, `running`, `failed: <why>`) or `stopped`.
struct SandboxStatus: Equatable {
    enum State: Equatable { case starting, running, stopped, failed }

    let state: State
    let error: String?

    init(_ text: String?) {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("failed") {
            state = .failed
            let why = text.dropFirst("failed".count).drop { $0 == ":" || $0 == " " }
            error = why.isEmpty ? nil : String(why)
        } else {
            state = switch text {
            case "running": .running
            case "stopped": .stopped
            default: .starting
            }
            error = nil
        }
    }

    var label: String {
        switch state {
        case .starting: "Starting"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch state {
        case .starting: .orange
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}
