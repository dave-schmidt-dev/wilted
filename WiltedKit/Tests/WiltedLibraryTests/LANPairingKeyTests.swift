import CryptoKit
import Foundation
import XCTest
@testable import WiltedLibrary

/// The per-pair PSK both devices derive from CloudKit-published public keys.
final class LANPairingKeyTests: XCTestCase {
    private let tag = "owner-binding-tag"
    private let macID = "mac-device"
    private let phoneID = "phone-device"

    /// Fixed private scalars (0x01...0x20 and 0x21...0x40), so the golden vector is reproducible.
    private func fixedKey(from first: UInt8) throws -> LANKeyAgreementKey {
        try LANKeyAgreementKey(rawRepresentation: Data((0..<32).map { first + UInt8($0) }))
    }

    private func pair() -> (mac: LANKeyAgreementKey, phone: LANKeyAgreementKey) { (LANKeyAgreementKey(), LANKeyAgreementKey()) }

    private func macPSK(
        _ mac: LANKeyAgreementKey, _ phone: LANKeyAgreementKey, tag: String? = nil, macID: String? = nil, phoneID: String? = nil
    ) throws -> Data {
        try LANPairingKey.derive(
            ownKey: mac, peerPublicKey: phone.publicKey, ownerBindingTag: tag ?? self.tag,
            macDeviceID: macID ?? self.macID, phoneDeviceID: phoneID ?? self.phoneID,
            macPublicKey: mac.publicKey, phonePublicKey: phone.publicKey)
    }

    private func phonePSK(
        _ mac: LANKeyAgreementKey, _ phone: LANKeyAgreementKey, tag: String? = nil, macID: String? = nil, phoneID: String? = nil
    ) throws -> Data {
        try LANPairingKey.derive(
            ownKey: phone, peerPublicKey: mac.publicKey, ownerBindingTag: tag ?? self.tag,
            macDeviceID: macID ?? self.macID, phoneDeviceID: phoneID ?? self.phoneID,
            macPublicKey: mac.publicKey, phonePublicKey: phone.publicKey)
    }

    func testBothSidesDeriveTheSameThirtyTwoByteKey() throws {
        let (mac, phone) = pair()
        let fromMac = try macPSK(mac, phone), fromPhone = try phonePSK(mac, phone)
        XCTAssertEqual(fromMac, fromPhone)
        XCTAssertEqual(fromMac.count, 32)
    }

    func testADifferentOwnerTagDeviceIDOrPublicKeyDerivesADifferentKey() throws {
        let (mac, phone) = pair()
        let base = try macPSK(mac, phone)
        XCTAssertNotEqual(try macPSK(mac, phone, tag: "another-owner"), base)
        XCTAssertNotEqual(try macPSK(mac, phone, macID: "another-mac"), base)
        XCTAssertNotEqual(try macPSK(mac, phone, phoneID: "another-phone"), base)
        XCTAssertNotEqual(try macPSK(mac, LANKeyAgreementKey()), base, "another phone key")
        XCTAssertNotEqual(try macPSK(LANKeyAgreementKey(), phone), base, "another Mac key")
    }

    func testThePartsOfTheContextCannotBeShiftedBetweenFields() throws {
        let (mac, phone) = pair()
        XCTAssertNotEqual(try macPSK(mac, phone, tag: "ab", macID: "c"), try macPSK(mac, phone, tag: "a", macID: "bc"))
        XCTAssertNotEqual(try macPSK(mac, phone, macID: "ab", phoneID: "c"), try macPSK(mac, phone, macID: "a", phoneID: "bc"))
    }

    func testTheRolesMustMatchTheKeys() throws {
        let (mac, phone) = pair()
        XCTAssertThrowsError(try LANPairingKey.derive(
            ownKey: mac, peerPublicKey: phone.publicKey, ownerBindingTag: tag, macDeviceID: macID, phoneDeviceID: phoneID,
            macPublicKey: phone.publicKey, phonePublicKey: LANKeyAgreementKey().publicKey))
        XCTAssertThrowsError(try LANPairingKey.derive(
            ownKey: mac, peerPublicKey: Data(repeating: 1, count: 64), ownerBindingTag: tag, macDeviceID: macID,
            phoneDeviceID: phoneID, macPublicKey: mac.publicKey, phonePublicKey: Data(repeating: 1, count: 64))) {
            XCTAssertEqual($0 as? LANKeyError, .invalidKey, "bytes that are not a curve point")
        }
    }

    /// Fixed inputs to a fixed key. If this fails, the derivation changed and every deployed pair would
    /// stop agreeing; fix the code, not the vector.
    func testGoldenVector() throws {
        let mac = try fixedKey(from: 0x01), phone = try fixedKey(from: 0x21)
        XCTAssertEqual(mac.publicKey.hex, Self.goldenMacPublicKey)
        XCTAssertEqual(phone.publicKey.hex, Self.goldenPhonePublicKey)
        let psk = try macPSK(mac, phone)
        XCTAssertEqual(psk.hex, Self.goldenPSK)
        XCTAssertEqual(try phonePSK(mac, phone).hex, Self.goldenPSK)
        XCTAssertEqual(LANPairingKey.identity(phonePublicKey: phone.publicKey).hex, Self.goldenIdentity)
        XCTAssertEqual(LANPairingKey.fingerprint(of: phone.publicKey), Self.goldenFingerprint)
    }

    func testTheIdentityIsTheFirstSixteenBytesOfTheHashOfTheRawPhoneKey() throws {
        let phone = LANKeyAgreementKey()
        let identity = LANPairingKey.identity(phonePublicKey: phone.publicKey)
        XCTAssertEqual(identity.count, 16)
        XCTAssertEqual(identity, Data(SHA256.hash(data: phone.publicKey).prefix(16)))
        XCTAssertEqual(phone.publicKey.count, 64)
    }

    func testTheFingerprintIsStableAndDiffersPerKey() {
        let first = LANKeyAgreementKey(), second = LANKeyAgreementKey()
        XCTAssertEqual(LANPairingKey.fingerprint(of: first.publicKey), first.fingerprint)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 64)
    }

    // MARK: golden values

    // Also reproduced independently with Python `cryptography` (ECDH, then HKDF-SHA256 over the same info).
    static let goldenMacPublicKey = "515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f"
        + "4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354"
    static let goldenPhonePublicKey = "1f140146bfb1b251f84f4ddbe0d4cdcfd77afd984a9520e35794021f8312bb9e"
        + "ec995a08b1fa7704df3dcc0b50a9665263fb7711f95f9f8a449c5096e47c892b"
    static let goldenPSK = "97125493e2f4bd7228110325e6929ff4c735c594c86b257ef1cff970bba123df"
    static let goldenIdentity = "284a200ec882a5ddbcc25d169bba98a6"
    static let goldenFingerprint = "284a200ec882a5ddbcc25d169bba98a64c45692e4d10fdabee9cc0c5c9f2033a"
}

extension Data {
    /// Lowercase hex, for fixtures.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
