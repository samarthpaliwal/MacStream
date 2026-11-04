import CryptoKit
import Foundation
import Network
import Security

/// Builds Network framework parameters for the reliable control channel:
/// TCP with Nagle disabled, wrapped in TLS 1.2 using a pre-shared key.
///
/// Why PSK rather than certificates: both sides already share a secret from
/// pairing, so no certificate authority, no self-signed cert pinning, and no
/// identity prompt on the iPad. The PSK cipher suites exist only in TLS 1.2,
/// which is why the version is pinned.
public enum ControlTransport {
    /// Sent in the clear as the TLS PSK identity hint. It is a protocol label,
    /// not a secret; the client's real identity travels inside `hello`.
    static let pskIdentity = "macstream-control-v1"

    public static func tlsParameters(psk: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true          // input events must not wait for coalescing
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    public static func browserParameters() -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        return parameters
    }
}
