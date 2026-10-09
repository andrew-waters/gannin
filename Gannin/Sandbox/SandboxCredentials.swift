import Foundation

/// What a sandboxed session is given, and nothing else (R6, R7, R18): the
/// Claude credential, the org's fine-grained GitHub token and the sandbox
/// signing key, each in the keychain under `service`. The user's own Claude
/// login, gh login, Gannin's GitHub token and SSH keys never go in.
nonisolated enum SandboxCredentials {
    static let service = "dev.andon.gannin.sandbox"

    // MARK: Settings (UserDefaults, this Mac)

    static let enabledKey = "sandbox.enabled"
    static let claudeKindKey = "sandbox.claudeCredential"
    static let cpusKey = "sandbox.cpus"
    static let memoryKey = "sandbox.memoryGB"
    /// The signing key's public half, which isn't secret.
    static let signingPublicKey = "sandbox.signingPublicKey"

    static let defaultCPUs = 4
    static let defaultMemoryGB = 8

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var cpus: Int {
        let value = UserDefaults.standard.integer(forKey: cpusKey)
        return value > 0 ? value : defaultCPUs
    }

    static var memoryGB: Int {
        let value = UserDefaults.standard.integer(forKey: memoryKey)
        return value > 0 ? value : defaultMemoryGB
    }

    // MARK: Claude

    /// How Claude Code signs in inside a sandbox: the user's choice.
    enum ClaudeKind: String, CaseIterable, Identifiable, Sendable {
        /// A long-lived token from `claude setup-token`, on the user's
        /// subscription.
        case subscription
        /// An Anthropic API key, billed to the API.
        case apiKey

        var id: String { rawValue }

        var name: String {
            switch self {
            case .subscription: "Subscription token"
            case .apiKey: "API key"
            }
        }

        /// The variable Claude Code reads it from.
        var environmentName: String {
            switch self {
            case .subscription: "CLAUDE_CODE_OAUTH_TOKEN"
            case .apiKey: "ANTHROPIC_API_KEY"
            }
        }

        /// What one looks like, to say when a pasted value doesn't.
        var prefix: String {
            switch self {
            case .subscription: "sk-ant-oat"
            case .apiKey: "sk-ant-api"
            }
        }
    }

    static var claudeKind: ClaudeKind {
        UserDefaults.standard.string(forKey: claudeKindKey).flatMap(ClaudeKind.init(rawValue:)) ?? .subscription
    }

    /// Each kind is kept apart, so switching back finds the other.
    static func claudeCredential(_ kind: ClaudeKind) -> String? {
        Keychain.value(service: service, account: "claude-\(kind.rawValue)")
    }

    static func setClaudeCredential(_ value: String?, _ kind: ClaudeKind) {
        let account = "claude-\(kind.rawValue)"
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            Keychain.setValue(value, service: service, account: account)
        } else {
            Keychain.clear(service: service, account: account)
        }
    }

    /// The token `claude setup-token` printed, found in its terminal's text:
    /// the line it starts on, and the lines after while they're more of it
    /// (the terminal wraps a long token), up to a blank line or words.
    static func setupToken(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.contains("sk-ant-oat") }),
              let first = lines[start].firstMatch(of: #/sk-ant-oat[0-9A-Za-z_\-]+/#) else { return nil }
        var token = String(first.output)
        // Only a token that reached the line's end can carry on below.
        if lines[start].hasSuffix(token) {
            for line in lines[(start + 1)...] {
                guard !line.isEmpty, line.wholeMatch(of: #/[0-9A-Za-z_\-]+/#) != nil else { break }
                token += line
            }
        }
        return token.count >= 30 ? token : nil
    }

    // MARK: GitHub

    static func gitHubToken(org: String) -> String? {
        Keychain.value(service: service, account: "github-\(org.lowercased())")
    }

    static func setGitHubToken(_ value: String?, org: String) {
        let account = "github-\(org.lowercased())"
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            Keychain.setValue(value, service: service, account: account)
        } else {
            Keychain.clear(service: service, account: account)
        }
    }

    /// The permissions a sandboxed session needs: push, PRs and issues, and
    /// reading Actions for failed checks' logs.
    static let gitHubPermissions: [(name: String, level: String, why: String)] = [
        ("contents", "write", "to push its branch"),
        ("pull_requests", "write", "to open and update pull requests"),
        ("issues", "write", "to comment on issues"),
        ("actions", "read", "to read failed checks' logs"),
    ]

    /// GitHub's new fine-grained token page, filled in for the org.
    static func newGitHubTokenURL(org: String) -> URL {
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        components.queryItems = [
            URLQueryItem(name: "name", value: "Gannin sandbox (\(org))"),
            URLQueryItem(name: "description", value: "Used by Gannin's sandboxed Claude Code sessions to push, open pull requests and comment."),
            URLQueryItem(name: "target_name", value: org),
            URLQueryItem(name: "expires_in", value: "90"),
        ] + gitHubPermissions.map { URLQueryItem(name: $0.name, value: $0.level) }
        return components.url!
    }

    // MARK: Signing key

    /// GitHub's page for adding a key, where Key type is set to Signing Key.
    static let newSigningKeyURL = URL(string: "https://github.com/settings/ssh/new")!

    static var signingKey: String? {
        Keychain.value(service: service, account: "signing-key")
    }

    static var publicSigningKey: String? {
        UserDefaults.standard.string(forKey: signingPublicKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setSigningKey(private key: String, public publicKey: String) {
        Keychain.setValue(key, service: service, account: "signing-key")
        UserDefaults.standard.set(publicKey, forKey: signingPublicKey)
    }

    static func removeSigningKey() {
        Keychain.clear(service: service, account: "signing-key")
        UserDefaults.standard.removeObject(forKey: signingPublicKey)
    }

    struct KeyFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A new ed25519 key with no passphrase, made with ssh-keygen in a
    /// private temporary folder that's removed after.
    static func generateSigningKey(comment: String) async throws -> (private: String, public: String) {
        try await withKeyFolder { folder in
            let key = folder.appending(path: "key").path
            let result = Shell.run("/usr/bin/ssh-keygen -q -t ed25519 -N '' -C \(SandboxRuntime.quoted(comment)) -f \(SandboxRuntime.quoted(key))", .local)
            guard result.ok else { throw KeyFailure(message: "ssh-keygen couldn't make a key: \(result.failure)") }
            return try read(folder)
        }
    }

    /// A private key pasted in, checked and its public half worked out. A
    /// key with a passphrase can't be used, as nothing can type it.
    static func importSigningKey(_ text: String) async throws -> (private: String, public: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard key.contains("PRIVATE KEY") else { throw KeyFailure(message: "That isn't a private key. Paste the whole file, from -----BEGIN to -----END.") }
        return try await withKeyFolder { folder in
            let path = folder.appending(path: "key")
            try Data(key.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let result = Shell.run("/usr/bin/ssh-keygen -y -P '' -f \(SandboxRuntime.quoted(path.path))", .local)
            guard result.ok else { throw KeyFailure(message: "ssh-keygen couldn't read it. A key with a passphrase can't be used in a sandbox.") }
            return (key, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func withKeyFolder<T: Sendable>(_ work: @Sendable @escaping (URL) throws -> T) async throws -> T {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appending(path: "gannin-key-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            return try work(folder)
        }.value
    }

    private static func read(_ folder: URL) throws -> (private: String, public: String) {
        let key = try String(contentsOf: folder.appending(path: "key"), encoding: .utf8)
        let publicKey = try String(contentsOf: folder.appending(path: "key.pub"), encoding: .utf8)
        return (key, publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Readiness

    /// What's still needed before sandboxing can be turned on, in order:
    /// the Claude credential and the signing key (R18). The org's GitHub
    /// token is checked when a session starts, as it's per org.
    static var missing: [String] {
        var missing: [String] = []
        if claudeCredential(claudeKind) == nil { missing.append("a Claude \(claudeKind.name.lowercased())") }
        if signingKey == nil { missing.append("a signing key") }
        return missing
    }
}
