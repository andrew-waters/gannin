import Foundation

extension Data {
    /// Lower-case hex, for fingerprints in URLs and storage.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Nil unless `hex` is an even number of hex digits.
    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

/// What the Mac's QR code carries: the pairing secret, the Mac's key fingerprint (so the
/// phone knows which key to expect before it has met the Mac) and its name.
public struct PairingInvite: Equatable, Sendable, Identifiable {
    public static let scheme = "gannin-remote"

    public var secret: PairingSecret
    public var macFingerprint: Data
    public var macName: String

    public init(secret: PairingSecret, macFingerprint: Data, macName: String) {
        self.secret = secret
        self.macFingerprint = macFingerprint
        self.macName = macName
    }

    /// One invite per secret, which is what a sheet showing it needs to tell invites apart.
    public var id: String { secret.code }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "c", value: secret.code),
            URLQueryItem(name: "f", value: macFingerprint.hexString),
            URLQueryItem(name: "n", value: macName),
        ]
        return components.url!
    }

    /// Nil for anything that isn't a complete invite.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let code = value("c"), let secret = PairingSecret(code: code),
              let hex = value("f"), let fingerprint = Data(hex: hex), !fingerprint.isEmpty,
              let name = value("n"), !name.isEmpty else { return nil }
        self.init(secret: secret, macFingerprint: fingerprint, macName: name)
    }
}
