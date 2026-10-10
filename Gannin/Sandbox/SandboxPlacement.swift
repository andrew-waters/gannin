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

/// Where a session's claude actually runs, as its tab and panel say it:
/// this Mac, a sandbox here, the Connect with server, or a sandbox there.
nonisolated enum SessionLocation: Equatable, Sendable {
    case thisMac
    case sandbox
    case server(String)
    case sandboxOnServer(String)

    init(sandboxed: Bool, connect: String?) {
        switch (sandboxed, connect.map(Self.serverName)) {
        case (false, nil): self = .thisMac
        case (true, nil): self = .sandbox
        case (false, let server?): self = .server(server)
        case (true, let server?): self = .sandboxOnServer(server)
        }
    }

    var name: String {
        switch self {
        case .thisMac: "This Mac"
        case .sandbox: "Sandbox on this Mac"
        case .server(let server): server
        case .sandboxOnServer(let server): "Sandbox on \(server)"
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: "laptopcomputer"
        case .sandbox, .sandboxOnServer: "shippingbox"
        case .server: "server.rack"
        }
    }

    var isSandboxed: Bool {
        switch self {
        case .sandbox, .sandboxOnServer: true
        case .thisMac, .server: false
        }
    }

    var explanation: String {
        switch self {
        case .thisMac: "Claude runs on this Mac as you, able to reach anything you can."
        case .sandbox: "Claude runs in a Linux sandbox on this Mac that sees only this issue's folder and what it's given."
        case .server(let server): "Claude runs on \(server), through Settings' Connect with command, as you there."
        case .sandboxOnServer(let server): "Claude runs in a Linux sandbox on \(server) that sees only this issue's folder and what it's given."
        }
    }

    /// The host a Connect with command reaches: `ssh -t me@studio` is
    /// studio. Anything else is the command itself.
    static func serverName(_ connect: String) -> String {
        let words = connect.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first == "ssh" || first.hasSuffix("/ssh") else {
            return connect.trimmingCharacters(in: .whitespaces)
        }
        // ssh's options that take a value.
        let valued = Set("BbcDEeFIiJLlmOoPpQRSWw".map { "-\($0)" })
        var index = 1
        while index < words.count {
            let word = words[index]
            if valued.contains(word) {
                index += 2
            } else if word.hasPrefix("-") {
                index += 1
            } else {
                return word.split(separator: "@").last.map(String.init) ?? word
            }
        }
        return connect.trimmingCharacters(in: .whitespaces)
    }
}
