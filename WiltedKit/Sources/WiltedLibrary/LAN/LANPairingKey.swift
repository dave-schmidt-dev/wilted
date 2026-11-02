import CryptoKit
import Foundation

/// Why a LAN key could not be built or derived. Never carries key bytes.
public enum LANKeyError: Error, Equatable, Sendable {
    /// Bytes that are not a valid P-256 key.
    case invalidKey
    /// The Keychain refused an operation (the `OSStatus`).
    case keychain(Int32)
}

/// This install's P-256 key-agreement private key. A wrapper so the secret has no printable form: its
/// `description`, `debugDescription` and reflection are all redacted, and the raw bytes are internal to
/// the module (the Keychain store and the tests).
public struct LANKeyAgreementKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let key: P256.KeyAgreement.PrivateKey

    /// A new random key.
    public init() { key = P256.KeyAgreement.PrivateKey() }

    init(rawRepresentation: Data) throws {
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation) else {
            throw LANKeyError.invalidKey
        }
        self.key = key
    }

    /// The private scalar, for the Keychain store only.
    var rawRepresentation: Data { key.rawRepresentation }

    /// The raw 64-byte public key (x and y), the form published in CloudKit payloads.
    public var publicKey: Data { key.publicKey.rawRepresentation }

    /// The fingerprint of this key's public half (`LANPairingKey.fingerprint(of:)`).
    public var fingerprint: String { LANPairingKey.fingerprint(of: publicKey) }

    func sharedSecret(with peerPublicKey: Data) throws -> SharedSecret {
        guard let peer = try? P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let secret = try? key.sharedSecretFromKeyAgreement(with: peer) else {
            throw LANKeyError.invalidKey
        }
        return secret
    }

    public var description: String { "LANKeyAgreementKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The per-pair pre-shared key for the LAN TLS profile, and the helpers both sides share.
///
/// The phone and the Mac each hold a P-256 key whose public half travels in an existing CloudKit
/// payload. Both derive `HKDF-SHA256(ECDH, salt, info)` over the same roles in the same order, so the two
/// sides agree and nothing secret crosses the network or CloudKit.
public enum LANPairingKey {
    public static let salt = Data("wilted-lan-v1".utf8)
    public static let pskByteCount = 32
    public static let identityByteCount = 16

    /// The 32-byte PSK for one Mac and phone pair. Both sides pass the same roles: `ownKey` is whichever
    /// of the two this device holds, `peerPublicKey` the other's raw public key, and the Mac and phone
    /// arguments are fixed by role, not by who is calling.
    ///
    /// `info` is `ownerBindingTag ‖ macDeviceID ‖ phoneDeviceID ‖ macPublicKey ‖ phonePublicKey`, each part
    /// preceded by its length as a 32-bit big-endian count so no two inputs concatenate alike.
    public static func derive(
        ownKey: LANKeyAgreementKey, peerPublicKey: Data, ownerBindingTag: String,
        macDeviceID: String, phoneDeviceID: String, macPublicKey: Data, phonePublicKey: Data
    ) throws -> Data {
        let own = ownKey.publicKey
        guard own == macPublicKey && peerPublicKey == phonePublicKey
            || own == phonePublicKey && peerPublicKey == macPublicKey else {
            throw LANKeyError.invalidKey
        }
        let secret = try ownKey.sharedSecret(with: peerPublicKey)
        var info = Data()
        for part in [Data(ownerBindingTag.utf8), Data(macDeviceID.utf8), Data(phoneDeviceID.utf8), macPublicKey, phonePublicKey] {
            info.append(contentsOf: LANFrameCodec.bigEndian32(UInt32(part.count)))
            info.append(part)
        }
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: pskByteCount)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The opaque TLS PSK identity: the first 16 bytes of SHA-256 over the phone's raw public key.
    public static func identity(phonePublicKey: Data) -> Data {
        Data(SHA256.hash(data: phonePublicKey).prefix(identityByteCount))
    }

    /// A public key's fingerprint: lowercase hex of the full SHA-256 of its raw representation. Published
    /// as `knownPhoneKeyFingerprint` so a phone can tell whether the Mac holds its current key.
    public static func fingerprint(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
}
