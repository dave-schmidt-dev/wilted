import Foundation
import Network
import Security

/// Why the TLS profile was refused. Callers treat every case as "do not talk to this peer".
public enum LANTLSError: Error, Equatable, Sendable {
    /// A PSK that is not 32 bytes, an empty identity, no allowed phones, or a duplicate identity.
    case invalidProfile
    /// The connection negotiated something other than TLS 1.2 with the one allowed cipher suite.
    case unexpectedNegotiation
}

/// One allowed phone, as the Mac's listener knows it.
public struct LANTLSPeer: Sendable, Equatable {
    public let identity: Data
    public let psk: Data

    public init(identity: Data, psk: Data) {
        self.identity = identity
        self.psk = psk
    }
}

/// The TLS options for direct LAN transfers: TLS 1.2 ECDHE-PSK with ChaCha20-Poly1305 and nothing else,
/// adapted from Scarecrow's nearby profile. The spike (docs/lan-transport-spike-2026-11-02.md) found
/// TLS 1.3 external PSK unusable on this OS and one multi-key listener able to serve several phones.
///
/// A failed handshake shows on the client as `NWConnection.State.waiting`, not `.failed` (a wrong key gave
/// `-9820 bad MAC`). Callers must treat `.waiting` before `.ready` as a failure and cancel at once; waiting
/// for the retry would hang. Every ready connection must still pass `validate(metadata:)`.
public enum LANTLSProfile {
    public static let versionRaw: UInt16 = 0x0303
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256.
    public static let cipherRaw: UInt16 = 0xCCAC

    /// Options for the Mac's listener: one pre-shared key per allowed phone, selected by the identity the
    /// client sends. The key set is fixed when the listener starts, so a change restarts the listener.
    public static func serverParameters(peers: [LANTLSPeer]) throws -> NWParameters {
        guard !peers.isEmpty, Set(peers.map(\.identity)).count == peers.count else { throw LANTLSError.invalidProfile }
        let (tls, options) = try baseOptions()
        for peer in peers {
            try check(psk: peer.psk, identity: peer.identity)
            sec_protocol_options_add_pre_shared_key(options, dispatchData(peer.psk), dispatchData(peer.identity))
        }
        return parameters(tls)
    }

    /// Options for the phone's connection: its one key, and the identity it answers with whatever the
    /// server hints.
    public static func clientParameters(psk: Data, identity: Data) throws -> NWParameters {
        try check(psk: psk, identity: identity)
        let (tls, options) = try baseOptions()
        sec_protocol_options_add_pre_shared_key(options, dispatchData(psk), dispatchData(identity))
        let selected = dispatchData(identity)
        sec_protocol_options_set_pre_shared_key_selection_block(
            options, { _, _, complete in complete(selected) }, DispatchQueue(label: "com.zerodelta.wilted.lan.psk-selection"))
        return parameters(tls)
    }

    /// Fails closed unless the connection negotiated TLS 1.2 and the one allowed cipher suite. Call on
    /// every connection, both sides, once it is ready.
    public static func validate(metadata: NWProtocolTLS.Metadata?) throws {
        guard let metadata else { throw LANTLSError.unexpectedNegotiation }
        let security = metadata.securityProtocolMetadata
        try validate(
            version: sec_protocol_metadata_get_negotiated_tls_protocol_version(security).rawValue,
            cipher: sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue)
    }

    /// The pure check behind `validate(metadata:)`.
    public static func validate(version: UInt16, cipher: UInt16) throws {
        guard version == versionRaw, cipher == cipherRaw else { throw LANTLSError.unexpectedNegotiation }
    }

    // MARK: Internals

    private static func baseOptions() throws -> (NWProtocolTLS.Options, sec_protocol_options_t) {
        guard let cipher = tls_ciphersuite_t(rawValue: cipherRaw) else { throw LANTLSError.invalidProfile }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, cipher)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_set_tls_renegotiation_enabled(options, false)
        return (tls, options)
    }

    private static func parameters(_ tls: NWProtocolTLS.Options) -> NWParameters {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        // Infrastructure Wi-Fi only: AWDL would slow the link and widen who can reach the listener.
        parameters.includePeerToPeer = false
        return parameters
    }

    private static func check(psk: Data, identity: Data) throws {
        guard psk.count == LANPairingKey.pskByteCount, !identity.isEmpty else { throw LANTLSError.invalidProfile }
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
