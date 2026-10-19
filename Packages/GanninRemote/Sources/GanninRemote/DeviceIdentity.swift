import CryptoKit
import Foundation
import Security

public enum IdentityError: Error, LocalizedError {
    case keychain(OSStatus)
    case keyUnavailable

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "The keychain refused (\(status))."
        case .keyUnavailable: "Couldn't make this device's key."
        }
    }
}

/// This device's TLS identity: a P-256 key and a self-signed certificate, both in the keychain.
///
/// The key is what identifies the device. The certificate only carries it, so it may be
/// replaced without breaking a pairing; a new key breaks every pairing made with the old one.
/// The certificate's common name is the label: macOS files a certificate under its common name
/// and ignores `kSecAttrLabel`, so this is what makes the certificate findable by label.
/// `fingerprint` is what the other side pins and what pairing proves.
public final class DeviceIdentity: @unchecked Sendable {  // SecIdentity is immutable and thread-safe, but not marked Sendable.
    public let identity: SecIdentity
    /// SHA-256 of the key's DER SubjectPublicKeyInfo: the usual public-key pin, equal to
    /// `openssl pkey -pubin -outform der | openssl dgst -sha256`.
    public let fingerprint: Data

    /// The macOS file-based keychain fails when keys are made or removed concurrently, so every write waits its turn.
    private static let lock = NSLock()

    private init(identity: SecIdentity, fingerprint: Data) {
        self.identity = identity
        self.fingerprint = fingerprint
    }

    /// The identity kept under `label`, made on first use. A key left without its certificate
    /// by an interrupted first run is cleared and made again.
    public static func loadOrCreate(label: String) throws -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let found = try find(label: label) { return found }
        remove(label: label)
        try create(label: label)
        guard let made = try find(label: label) else { throw IdentityError.keyUnavailable }
        return made
    }

    /// Removes the key and certificate. For tests and a deliberate reset; every pairing made with this key stops working.
    public static func delete(label: String) {
        lock.lock()
        defer { lock.unlock() }
        remove(label: label)
    }

    private static func remove(label: String) {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            SecItemDelete([kSecClass: itemClass, kSecAttrLabel: label, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary)
        }
    }

    // MARK: Keychain

    private static func find(label: String) throws -> DeviceIdentity? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecAttrLabel: label, kSecReturnRef: true] as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let found else { throw IdentityError.keychain(status) }
        let certificate = found as! SecCertificate  // The query asked for a certificate.
        var identity: SecIdentity?
        #if os(macOS)
        // Pairs the certificate with its key. A `kSecClassIdentity` query by label is not used here: macOS
        // ignores the label for identities and returns whichever identity comes first, which is not ours.
        SecIdentityCreateWithCertificate(nil, certificate, &identity)
        #else
        var result: CFTypeRef?
        SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecAttrLabel: label, kSecReturnRef: true] as CFDictionary, &result)
        identity = result as! SecIdentity?
        #endif
        // The fingerprint comes from the certificate, which is what a peer sees: a private key read back
        // from the keychain can't always give up its public half. Checking the name and that the key is
        // P-256 stops any other identity being taken for this one.
        guard let identity, SecCertificateCopySubjectSummary(certificate) as String? == label,
              let fingerprint = PinnedTLS.fingerprint(of: SecCertificateCopyKey(certificate)) else { throw IdentityError.keyUnavailable }
        return DeviceIdentity(identity: identity, fingerprint: fingerprint)
    }

    private static func create(label: String) throws {
        // P-256 is the only curve `PinnedTLS.fingerprint(of:)` accepts. Permanent, so the key lives in
        // the keychain and a later launch finds it again; the private half never leaves it.
        var keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrLabel: label,
            kSecAttrIsPermanent: true,
        ]
        var certificateAttributes: [CFString: Any] = [kSecAttrLabel: label]
        #if os(iOS)
        // iOS only: the macOS file-based keychain has no such attribute. Usable only while the phone
        // is unlocked, and never copied to another device or a backup. Unverified on a device.
        keyAttributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        certificateAttributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let spki = (try? P256.Signing.PublicKey(x963Representation: point))?.derRepresentation else {
            throw IdentityError.keyUnavailable
        }
        // A random serial, with the top bit cleared so the DER INTEGER is positive. Nothing checks it.
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[serial.startIndex] &= 0x7F
        let der = try SelfSignedCertificate.make(name: label, spki: spki, serial: serial) { toBeSigned in
            guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, toBeSigned as CFData, &error) else {
                throw error!.takeRetainedValue()
            }
            return signature as Data
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw IdentityError.keyUnavailable }
        certificateAttributes[kSecClass] = kSecClassCertificate
        certificateAttributes[kSecValueRef] = certificate
        let status = SecItemAdd(certificateAttributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}
