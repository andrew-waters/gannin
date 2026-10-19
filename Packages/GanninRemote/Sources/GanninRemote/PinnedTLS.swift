import CryptoKit
import Foundation
import Network
import Security

/// Mutual TLS in which each side identifies the other by the fingerprint of its public key
/// (`DeviceIdentity.fingerprint`) and by nothing else.
///
/// Certificates are self-signed, so system trust evaluation is never run: it would fail every
/// connection, and trusting a certificate authority is the wrong question. The verify block
/// below replaces it and decides on the key alone.
///
/// That is only safe if the peer has proved it holds the key it presented, not merely that it
/// can send its certificate. TLS 1.3 does this in CertificateVerify, which the system performs, so
/// 1.3 is the minimum. This code relies on that and doesn't re-check it, and no test here presents
/// a certificate without its key.
public enum PinnedTLS {
    /// Parameters for a listener or a connection that presents `identity` and asks the peer for its own.
    ///
    /// `accept` is given the fingerprint of the key the peer presented, before any application
    /// byte moves, and returns whether to carry on. A phone passes the pin of a paired Mac; the Mac
    /// accepts any key, because an unpaired phone must be able to reach the pairing exchange, and
    /// holds that connection to pairing alone until the phone's key is in `PairedPhones`.
    ///
    /// The block can run more than once per connection and must answer each run, so it keeps no state.
    public static func parameters(identity: DeviceIdentity, accept: @escaping @Sendable (Data) -> Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, sec_identity_create(identity.identity)!)
        // A listener doesn't ask for a client certificate unless told to.
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            // Reads the key off the presented chain without evaluating trust in it.
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let key = SecTrustCopyKey(trustRef), let fingerprint = fingerprint(of: key) else {
                return complete(false)
            }
            complete(accept(fingerprint))
        }, DispatchQueue(label: "dev.andon.gannin.remote.tls-verify"))
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    /// The fingerprint of the key the peer presented on a connection whose handshake has completed.
    ///
    /// Read from the connection's own TLS metadata, because the verify block isn't told which
    /// connection it is running for. The key is the one `parameters`' `accept` approved.
    public static func peerFingerprint(of connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var leaf: SecCertificate?
        // The chain is delivered leaf first.
        _ = sec_protocol_metadata_access_peer_certificate_chain(tls.securityProtocolMetadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        guard let leaf, let key = SecCertificateCopyKey(leaf) else { return nil }
        return fingerprint(of: key)
    }

    /// SHA-256 of the key's DER SubjectPublicKeyInfo, or nil for anything but a P-256 key.
    ///
    /// Security exports an EC key as a bare X9.63 point, not SPKI, so it is re-wrapped by CryptoKit,
    /// which writes the full structure (a fixed header and the point), then hashed.
    static func fingerprint(of key: SecKey?) -> Data? {
        guard let key,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else { return nil }
        return Data(SHA256.hash(data: publicKey.derRepresentation))
    }
}
