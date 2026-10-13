import Foundation

/// The one-time secret that pairs a phone with a Mac. 128 bits, so a device on the same
/// network that sees the exchange can't work it out offline.
public struct PairingSecret: Sendable, Equatable {
    public static let byteCount = 16
    /// No I or O, 0 or 1, which are misread when typed.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public static func generate() -> PairingSecret {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return PairingSecret(bytes: bytes)!
    }

    /// 26 characters in groups of four, `ABCD-EFGH-...`, for typing when the QR code can't be scanned.
    public var code: String {
        var out = ""
        var accumulator = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(Self.alphabet[(accumulator >> (bits - 5)) & 31])
                bits -= 5
            }
            accumulator &= (1 << bits) - 1
        }
        if bits > 0 { out.append(Self.alphabet[(accumulator << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { start in
            String(out.dropFirst(start).prefix(4))
        }.joined(separator: "-")
    }

    /// Reads a typed code, ignoring case, dashes and spaces. Nil for anything that isn't one.
    public init?(code: String) {
        let characters = code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard characters.count == 26 else { return nil }
        var out = Data()
        var accumulator = 0
        var bits = 0
        for character in characters {
            guard let value = Self.alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((accumulator >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            accumulator &= (1 << bits) - 1
        }
        // The two bits left over must be the padding `code` writes.
        guard accumulator == 0 else { return nil }
        self.init(bytes: out)
    }
}

/// A pairing code's life on the Mac: it works for one attempt within `lifetime`, and a
/// wrong guess spends it as a right one does.
public struct PairingWindow: Sendable {
    public static let lifetime: TimeInterval = 120

    public let secret: PairingSecret
    public let expiresAt: Date
    private var spent = false

    public init(secret: PairingSecret = .generate(), now: Date = Date()) {
        self.secret = secret
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    /// The secret to check a phone's proof against, once; nil when expired or already used.
    public mutating func consume(at now: Date = Date()) -> PairingSecret? {
        guard !spent, now < expiresAt else { return nil }
        spent = true
        return secret
    }
}

#if canImport(CryptoKit)
import CryptoKit

/// Each side proves it knows the pairing secret, bound to both public-key fingerprints and a
/// fresh nonce each, so a relayed or replayed proof is useless and a Mac that isn't the one
/// in the QR code can't produce its own.
public enum PairingProof {
    public enum Role: String, Sendable {
        case phone
        case mac
    }

    public static func make(role: Role, secret: PairingSecret, macFingerprint: Data, phoneFingerprint: Data, macNonce: Data, phoneNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: message(role, macFingerprint, phoneFingerprint, macNonce, phoneNonce),
            using: SymmetricKey(data: secret.bytes)
        ))
    }

    /// Constant time.
    public static func verify(_ proof: Data, role: Role, secret: PairingSecret, macFingerprint: Data, phoneFingerprint: Data, macNonce: Data, phoneNonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: message(role, macFingerprint, phoneFingerprint, macNonce, phoneNonce),
            using: SymmetricKey(data: secret.bytes)
        )
    }

    /// The label, then each field behind its length, so no two field splits read the same.
    private static func message(_ role: Role, _ fields: Data...) -> Data {
        var out = Data("gannin-pair-v1-\(role.rawValue)".utf8)
        for field in fields {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(field)
        }
        return out
    }
}
#endif
