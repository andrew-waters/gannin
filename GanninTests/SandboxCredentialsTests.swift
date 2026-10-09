import Foundation
import Testing
@testable import Gannin

/// What sandboxes are given (andrew-waters/gannin#8, R6, R7, R18), short of
/// the keychain itself.
struct SandboxCredentialsTests {
    @Test func setupTokenIsFoundInTheTerminal() {
        let screen = """
            ✓ Long-lived authentication token created successfully!

            Your OAuth token (valid for 1 year):

            sk-ant-oat01-AbCdEf_GhIjKlMnOpQrStUvWx-
            yz0123456789

            Store this token securely. You won't be able to see it again.
            """
        #expect(SandboxCredentials.setupToken(in: screen) == "sk-ant-oat01-AbCdEf_GhIjKlMnOpQrStUvWx-yz0123456789")
        #expect(SandboxCredentials.setupToken(in: "Opening browser to sign in") == nil)
        #expect(SandboxCredentials.setupToken(in: "sk-ant-api03-not-a-subscription-token-at-all") == nil)
    }

    @Test func claudeKindsNameTheirVariable() {
        #expect(SandboxCredentials.ClaudeKind.subscription.environmentName == "CLAUDE_CODE_OAUTH_TOKEN")
        #expect(SandboxCredentials.ClaudeKind.apiKey.environmentName == "ANTHROPIC_API_KEY")
    }

    @Test func newTokenPageIsFilledInForTheOrg() throws {
        let url = SandboxCredentials.newGitHubTokenURL(org: "andrew-waters")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "github.com")
        #expect(url.path() == "/settings/personal-access-tokens/new")
        #expect(values["target_name"] == "andrew-waters")
        #expect(values["contents"] == "write")
        #expect(values["pull_requests"] == "write")
        #expect(values["issues"] == "write")
        #expect(values["actions"] == "read")
        #expect((values["name"] ?? "").count <= 40)
    }

    @Test func aMadeKeyReadsBackIn() async throws {
        let made = try await SandboxCredentials.generateSigningKey(comment: "Gannin test")
        #expect(made.private.contains("OPENSSH PRIVATE KEY"))
        #expect(made.public.hasPrefix("ssh-ed25519 "))
        #expect(made.public.hasSuffix("Gannin test"))
        // Pasting the same key works out the same public half.
        let imported = try await SandboxCredentials.importSigningKey(made.private)
        #expect(imported.public.split(separator: " ").prefix(2) == made.public.split(separator: " ").prefix(2))
    }

    @Test func notAKeyIsRefused() async {
        await #expect(throws: SandboxCredentials.KeyFailure.self) {
            _ = try await SandboxCredentials.importSigningKey("ssh-ed25519 AAAA public only")
        }
        await #expect(throws: SandboxCredentials.KeyFailure.self) {
            _ = try await SandboxCredentials.importSigningKey("-----BEGIN OPENSSH PRIVATE KEY-----\nnonsense\n-----END OPENSSH PRIVATE KEY-----")
        }
    }
}
