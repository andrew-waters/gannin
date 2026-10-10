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

    /// How Claude Code signs in inside a sandbox: the user's choice. Gannin
    /// never holds a Claude subscription's credentials (Anthropic's terms:
    /// sign-in completes through its own flow, and developers may not
    /// collect, store or intermediate them), so for a subscription claude
    /// signs in inside the sandbox and keeps its own login in the folder
    /// every sandbox shares (`claudeFolder`); only an API key is passed in.
    enum ClaudeKind: String, CaseIterable, Identifiable, Sendable {
        /// Claude's own sign-in, inside the sandbox. The raw value is the
        /// older setting's, so a choice made before still reads.
        case signIn = "subscription"
        /// An Anthropic API key, billed to the API.
        case apiKey

        var id: String { rawValue }

        var name: String {
            switch self {
            case .signIn: "Sign in with Claude"
            case .apiKey: "API key"
            }
        }
    }

    static var claudeKind: ClaudeKind {
        UserDefaults.standard.string(forKey: claudeKindKey).flatMap(ClaudeKind.init(rawValue:)) ?? .signIn
    }

    /// The API key sandboxes are given when the user picks one.
    static var apiKey: String? {
        Keychain.value(service: service, account: "claude-apiKey")
    }

    static func setAPIKey(_ value: String?) {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            Keychain.setValue(value, service: service, account: "claude-apiKey")
        } else {
            Keychain.clear(service: service, account: "claude-apiKey")
        }
    }

    /// What an API key starts with, to say when a pasted value doesn't.
    static let apiKeyPrefix = "sk-ant-api"

    /// A subscription token an earlier build of this branch kept is
    /// removed: Gannin doesn't hold one.
    static func removeStoredSubscriptionToken() {
        Keychain.clear(service: service, account: "claude-subscription")
    }

    /// Claude Code's config folder that every sandbox on this Mac shares, so
    /// its own login (and settings) carry from one to the next; each issue's
    /// transcripts are mounted over its `projects/`. Claude writes it, and
    /// Gannin never reads the login in it.
    static var claudeFolder: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.gannin", directoryHint: .isDirectory)
            .appending(path: "Sandbox/claude", directoryHint: .isDirectory)
    }

    /// The same on a server, as a shell expression there.
    static let remoteClaudeFolder = #""$HOME"/.gannin/sandbox/claude"#

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

    /// What's still needed before sandboxing can be turned on, in order: an
    /// API key when that's the choice, and the signing key (R18). The org's
    /// GitHub token is checked when a session starts, as it's per org.
    static var missing: [String] {
        var missing: [String] = []
        if claudeKind == .apiKey, apiKey == nil { missing.append("an API key") }
        if signingKey == nil { missing.append("a signing key") }
        return missing
    }
}
