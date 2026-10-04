import CryptoKit
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The library publisher's account binding (Task 5.0): hashed, durable, and kept apart
/// from the legacy article engine's state and from device identity.
extension LocalLibraryStoreTests {
    private static let rawRecordName = "_9f3c-raw-icloud-user-record-binding-test"

    /// The same derivation as `CloudKitAccountIdentity.token(for:)`.
    private static func hashedToken(_ recordName: String) -> String {
        "sha256:" + SHA256.hash(data: Data(recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testAccountBindingSurvivesReopenApartFromLegacyStateAndDeviceIdentity() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let owner = Self.hashedToken(Self.rawRecordName)
        let legacy = LocalLibrarySyncState(key: "private-zone", engineState: Data([7, 7, 7]))
        let store = try LocalLibraryStore(url: url)
        try await store.save(syncState: legacy)
        let empty = try await store.libraryAccountBinding()
        XCTAssertNil(empty, "a fresh library has no owner")

        let quarantined = try LocalLibraryAccountBinding(
            state: .quarantined, ownerToken: owner, candidateToken: Self.hashedToken("someone-else"),
            reason: .switchAccounts, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await store.save(libraryAccountBinding: quarantined)

        let reopened = try LocalLibraryStore(url: url)
        let binding = try await reopened.libraryAccountBinding()
        let legacyAfter = try await reopened.syncState(for: "private-zone")
        let row = try await reopened.syncState(for: LocalLibraryAccountBinding.storageKey)
        XCTAssertEqual(binding, quarantined, "the original owner and the review state survive relaunch")
        XCTAssertEqual(legacyAfter, legacy, "the legacy engine's state is untouched")
        XCTAssertNotEqual(LocalLibraryAccountBinding.storageKey, "private-zone")
        XCTAssertFalse(LocalLibraryAccountBinding.storageKey.contains("mac-"), "not derived from a device id")
        let stored = String(decoding: try XCTUnwrap(row).engineState, as: UTF8.self)
        XCTAssertFalse(stored.contains(Self.rawRecordName), "only the hash is stored")
        XCTAssertTrue(stored.contains(owner))

        let bound = try LocalLibraryAccountBinding(
            state: .bound, ownerToken: owner, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        try await reopened.save(libraryAccountBinding: bound)
        let replaced = try await reopened.libraryAccountBinding()
        XCTAssertEqual(replaced, bound, "one row per library, replaced in place")
    }

    func testAccountBindingRejectsUnhashedTokensAndDamagedRows() async throws {
        XCTAssertThrowsError(try LocalLibraryAccountBinding(state: .bound, ownerToken: Self.rawRecordName)) {
            XCTAssertEqual($0 as? LocalLibraryAccountBindingError, .unhashedToken)
        }
        let upper = Self.hashedToken("x").uppercased().replacingOccurrences(of: "SHA256:", with: "sha256:")
        XCTAssertThrowsError(try LocalLibraryAccountBinding(state: .bound, ownerToken: upper))
        XCTAssertThrowsError(try LocalLibraryAccountBinding(state: .bound)) {
            XCTAssertEqual($0 as? LocalLibraryAccountBindingError, .invalidState("a bound library needs an owner"))
        }
        XCTAssertThrowsError(try LocalLibraryAccountBinding(state: .reviewRequired, reason: .unboundLibrary))
        XCTAssertNoThrow(try LocalLibraryAccountBinding(state: .approved))

        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let token = Self.hashedToken(Self.rawRecordName)
        let valid = String(decoding: try JSONEncoder().encode(
            try LocalLibraryAccountBinding(state: .bound, ownerToken: token)), as: UTF8.self)
        let tampered = valid.replacingOccurrences(of: token, with: Self.rawRecordName)
        XCTAssertNotEqual(tampered, valid)
        try await store.save(syncState: LocalLibrarySyncState(
            key: LocalLibraryAccountBinding.storageKey, engineState: Data(tampered.utf8)))
        do {
            _ = try await store.libraryAccountBinding()
            XCTFail("a raw identifier must never load as an owner")
        } catch let error as LocalLibraryAccountBindingError {
            XCTAssertEqual(error, .unhashedToken)
        }

        try await store.save(syncState: LocalLibrarySyncState(
            key: LocalLibraryAccountBinding.storageKey, engineState: Data("not json".utf8)))
        do {
            _ = try await store.libraryAccountBinding()
            XCTFail("a damaged row must not read as unbound")
        } catch let error as LocalLibraryAccountBindingError {
            XCTAssertEqual(error, .corrupt)
        }
    }
}
