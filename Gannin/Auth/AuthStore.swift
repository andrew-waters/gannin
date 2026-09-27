import Foundation
import Observation

@Observable
final class AuthStore {
    private static let viewerKey = "viewer"

    private(set) var viewer: Viewer?
    private(set) var token: String?
    /// GitHub's GraphQL budget as of the latest query.
    private(set) var rateLimit: RateLimit?
    /// The token's scopes, as GitHub last reported them.
    private(set) var grantedScopes: Set<String>?

    /// Project boards need the `project` scope, which tokens from before it
    /// was requested lack. Unknown counts as yes.
    var canUseProjects: Bool { grantedScopes?.contains("project") ?? true }

    var isSignedIn: Bool { token != nil && viewer != nil }

    var api: GitHubAPI? {
        token.map { token in
            GitHubAPI(
                token: token,
                onRateLimit: { [weak self] in self?.rateLimit = $0 },
                onScopes: { [weak self] scopes in
                    if self?.grantedScopes != scopes { self?.grantedScopes = scopes }
                }
            )
        }
    }

    /// Automatic refreshes hold off until the budget resets.
    var shouldHoldOff: Bool { rateLimit?.isLow ?? false }

    init() {
        token = Keychain.token()
        if token != nil, let data = UserDefaults.standard.data(forKey: Self.viewerKey) {
            viewer = try? JSONDecoder().decode(Viewer.self, from: data)
        }
    }

    func completeSignIn(token: String) async throws {
        let viewer = try await GitHubAPI(token: token).viewer()
        Keychain.setToken(token)
        self.token = token
        setViewer(viewer)
    }

    func signOut() {
        Keychain.clearToken()
        token = nil
        viewer = nil
        rateLimit = nil
        grantedScopes = nil
        UserDefaults.standard.removeObject(forKey: Self.viewerKey)
    }

    /// Refreshes the cached profile. Signs out if GitHub rejects the token;
    /// other failures keep the cached session so offline launches still work.
    func validate() async {
        guard let api else { return }
        do {
            setViewer(try await api.viewer())
        } catch APIError.unauthorized {
            signOut()
        } catch {}
    }

    private func setViewer(_ viewer: Viewer) {
        self.viewer = viewer
        if let data = try? JSONEncoder().encode(viewer) {
            UserDefaults.standard.set(data, forKey: Self.viewerKey)
        }
    }
}
