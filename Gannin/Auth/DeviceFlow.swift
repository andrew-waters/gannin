import Foundation

// MARK: - Configuration

enum GitHubOAuthConfig {
    /// Client ID of the GitHub OAuth App. Device flow must be enabled on the
    /// app in GitHub's developer settings.
    static let clientID = "Ov23lict75KEMvZoPley"

    /// `read:org` lists orgs, members and teams. `repo` is needed to read PRs
    /// and issues in private repositories (classic OAuth has no read-only
    /// variant). Gannin only ever issues read queries.
    /// `project` is for board status history, and for adding an issue to a
    /// board and editing its fields there: the app's only writes.
    static let scopes = "read:user read:org repo project"
}

// MARK: - Models

struct DeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int
}

enum AuthError: Error, LocalizedError, Equatable {
    case http(status: Int, body: String)
    case network(String)
    case parse(String)
    case denied
    case expired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "GitHub returned HTTP \(code): \(body)"
        case .network(let message): "Network error: \(message)"
        case .parse(let reason): "Could not parse GitHub response: \(reason)"
        case .denied: "Authorization was denied."
        case .expired: "The code expired before you authorized. Try again."
        case .server(let message): "GitHub error: \(message)"
        }
    }
}

// MARK: - Device flow

/// GitHub OAuth device flow: request a user code, the user enters it on
/// github.com, and we poll until GitHub hands back an access token.
enum DeviceFlow {
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    static func requestCode() async throws -> DeviceCode {
        let json = try await post(deviceCodeURL, [
            "client_id": GitHubOAuthConfig.clientID,
            "scope": GitHubOAuthConfig.scopes,
        ])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)),
              let expiresIn = json["expires_in"] as? Int,
              let interval = json["interval"] as? Int else {
            throw AuthError.parse("device code response missing fields")
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    /// Polls until the user authorizes, the code expires, or the task is
    /// cancelled.
    static func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        let expiry = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        while true {
            try await Task.sleep(for: .seconds(interval))
            let json: [String: Any]
            do {
                json = try await post(accessTokenURL, [
                    "client_id": GitHubOAuthConfig.clientID,
                    "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch AuthError.network {
                // A dropped connection (the Mac asleep, a network change)
                // isn't the end of the sign-in; keep polling until the code
                // expires.
                guard Date.now < expiry else { throw AuthError.expired }
                continue
            }
            if let token = json["access_token"] as? String {
                return token
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, json["interval"] as? Int ?? 0)
            case "expired_token":
                throw AuthError.expired
            case "access_denied":
                throw AuthError.denied
            case let error?:
                throw AuthError.server(json["error_description"] as? String ?? error)
            case nil:
                throw AuthError.parse("token response missing 'access_token' and 'error'")
            }
        }
    }

    private static func post(_ url: URL, _ params: [String: String]) async throws -> [String: Any] {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw AuthError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.parse("response is not a JSON object")
        }
        return json
    }
}
