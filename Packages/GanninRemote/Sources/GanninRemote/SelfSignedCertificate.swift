import Foundation

/// Minimal DER writer: just what a self-signed certificate needs.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 128 {
            out.append(UInt8(content.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0).drop { $0 == 0 } }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        return out + content
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ part: Data) -> Data { tlv(0x31, part) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static func utf8String(_ text: String) -> Data { tlv(0x0C, Data(text.utf8)) }
    static func utcTime(_ text: String) -> Data { tlv(0x17, Data(text.utf8)) }
    static func generalizedTime(_ text: String) -> Data { tlv(0x18, Data(text.utf8)) }
    /// A BIT STRING whose bits are whole bytes, so no unused-bits count other than zero.
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    /// A positive INTEGER from big-endian bytes: leading zeros dropped, one added back if the top bit is set.
    static func positiveInteger(_ bytes: Data) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { trimmed = Data([0]) }
        if trimmed[trimmed.startIndex] & 0x80 != 0 { trimmed.insert(0, at: trimmed.startIndex) }
        return tlv(0x02, trimmed)
    }
}

/// A self-signed X.509 certificate around a P-256 key, which TLS needs in order to present the key.
///
/// Nothing ever checks this certificate: its name, dates and signature are not trusted, and the
/// other side pins the key's fingerprint instead (`PinnedTLS`). It only has to be well-formed
/// enough for the TLS stack to accept and send.
enum SelfSignedCertificate {
    private static let ecdsaWithSHA256 = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
    private static let commonName: [UInt8] = [0x55, 0x04, 0x03]

    /// `spki` is the key's DER SubjectPublicKeyInfo. `sign` returns an ECDSA-SHA256 signature in DER
    /// form over the bytes it is given, made with the key `spki` describes.
    static func make(name: String, spki: Data, serial: Data, sign: (Data) throws -> Data) throws -> Data {
        let subject = DER.sequence(DER.set(DER.sequence(DER.oid(commonName), DER.utf8String(name))))
        let validity = DER.sequence(DER.utcTime("200101000000Z"), DER.generalizedTime("99991231235959Z"))
        let toBeSigned = DER.sequence(
            DER.tlv(0xA0, DER.tlv(0x02, Data([2]))),  // version 3
            DER.positiveInteger(serial),
            ecdsaWithSHA256,
            subject,  // issuer: the certificate signs itself
            validity,
            subject,
            spki
        )
        return DER.sequence(toBeSigned, ecdsaWithSHA256, DER.bitString(try sign(toBeSigned)))
    }
}
