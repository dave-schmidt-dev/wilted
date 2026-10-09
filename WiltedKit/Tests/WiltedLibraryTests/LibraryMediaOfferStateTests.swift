import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryMediaOfferStateTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-a")
    private let revision = try! RevisionID(rawValue: "rev-1")

    private func decodedOffer(state: String = "ready", hash: String? = nil,
                              preparation: Any? = nil) throws -> LibraryMediaOffer {
        var object: [String: Any] = [
            "entryID": entry.rawValue, "revisionID": revision.rawValue,
            "contentHash": hash ?? MediaHash.prefix + String(repeating: "a", count: 64),
            "byteCount": 4096, "mediaType": "audio/mp4", "state": state
        ]
        if let preparation { object["preparation"] = preparation }
        return try JSONDecoder().decode(LibraryMediaOffer.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testLegacyReadyAndAvailableAreUnprovenWithoutPreparation() throws {
        for state in ["ready", "available"] {
            let offer = try decodedOffer(state: state)
            XCTAssertEqual(offer.state.rawValue, state)
            XCTAssertFalse(offer.isPrepared, "transport state alone does not certify Mac preparation")
        }
        XCTAssertFalse(try decodedOffer(state: "available", hash: "").isPrepared)
    }

    func testV1PreparationRoundTripsForExactReadyAndAvailableIdentity() throws {
        for state in ["ready", "available"] {
            let offer = try decodedOffer(state: state, preparation: [
                "schemaVersion": 1, "preparedAt": "2000-01-01T00:00:00Z"
            ])
            XCTAssertTrue(offer.isPrepared)
            let encoded = try JSONEncoder().encode(offer)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let proof = try XCTUnwrap(object["preparation"] as? [String: Any])
            XCTAssertEqual(proof["schemaVersion"] as? Int, 1)
            XCTAssertEqual(proof["preparedAt"] as? String, "2000-01-01T00:00:00Z")
            XCTAssertEqual(try JSONDecoder().decode(LibraryMediaOffer.self, from: encoded), offer)
        }
    }

    func testUnknownPreparationVersionIsUnprovenWithoutLosingDisplayIdentity() throws {
        let offer = try decodedOffer(preparation: ["schemaVersion": 2, "preparedAt": "2000-01-01T00:00:00Z"])
        XCTAssertEqual(offer.entryID, entry)
        XCTAssertEqual(offer.revisionID, revision)
        XCTAssertFalse(offer.isPrepared)
    }

    func testMalformedPreparationIsUnprovenWithoutLosingDisplayIdentity() throws {
        let malformed: [Any] = ["not-an-object", NSNull(), [:] as [String: Any],
            ["schemaVersion": "1", "preparedAt": "2000-01-01T00:00:00Z"],
            ["schemaVersion": 1, "preparedAt": "not-a-date"], ["schemaVersion": 1]]
        for proof in malformed {
            let offer = try decodedOffer(preparation: proof)
            XCTAssertEqual(offer.entryID, entry)
            XCTAssertEqual(offer.byteCount, 4096)
            XCTAssertFalse(offer.isPrepared, "malformed proof must not certify the retained identity")
        }
    }

    func testPreparationCannotCertifyHashlessAvailableOrNotReady() throws {
        let proof: [String: Any] = ["schemaVersion": 1, "preparedAt": "2000-01-01T00:00:00Z"]
        XCTAssertFalse(try decodedOffer(state: "available", hash: "", preparation: proof).isPrepared)
        XCTAssertFalse(try decodedOffer(state: "notReady", preparation: proof).isPrepared)
    }

    func testPreparationChangesAreObservableEvenForTheSameRevision() throws {
        let first = try decodedOffer(preparation: ["schemaVersion": 1, "preparedAt": "2000-01-01T00:00:00Z"])
        let second = try decodedOffer(preparation: ["schemaVersion": 1, "preparedAt": "2000-01-02T00:00:00Z"])
        XCTAssertEqual(first.revisionID, second.revisionID)
        XCTAssertNotEqual(first, second, "same-revision authority renewal must reach consumers")
        XCTAssertNotEqual(first, try decodedOffer(), "proof withdrawal must reach consumers")
    }

    private func available(hash: String = "") throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: entry, revisionID: revision, contentHash: hash, byteCount: 4_096,
            mediaType: "audio/mp4", durationSeconds: 61, state: .available
        )
    }

    func testAvailableOfferRoundTripsWithoutAHash() throws {
        let offer = try available()
        XCTAssertEqual(offer.state, .available)
        XCTAssertFalse(offer.isPrepared)
        XCTAssertEqual(offer.contentHash, "")
        XCTAssertEqual(try JSONDecoder().decode(LibraryMediaOffer.self, from: JSONEncoder().encode(offer)), offer)
        let json = String(decoding: try JSONEncoder().encode(offer), as: UTF8.self)
        XCTAssertTrue(json.contains("\"available\""))
    }

    func testAvailableOfferStillNeedsARevisionSizeAndTypeButAcceptsAWellFormedHash() throws {
        let hash = MediaHash.prefix + String(repeating: "a", count: 64)
        XCTAssertNoThrow(try available(hash: hash))
        XCTAssertThrowsError(try available(hash: "md5:nope"))
        XCTAssertThrowsError(try LibraryMediaOffer(
            entryID: entry, revisionID: nil, contentHash: "", byteCount: 1, mediaType: "audio/mp4", state: .available))
        XCTAssertThrowsError(try LibraryMediaOffer(
            entryID: entry, revisionID: revision, contentHash: "", byteCount: 0, mediaType: "audio/mp4", state: .available))
        XCTAssertThrowsError(try LibraryMediaOffer(
            entryID: entry, revisionID: revision, contentHash: "", byteCount: 1, mediaType: "", state: .available))
    }

    func testReadyStillRequiresAHash() {
        XCTAssertThrowsError(try LibraryMediaOffer(
            entryID: entry, revisionID: revision, contentHash: "", byteCount: 1, mediaType: "audio/mp4", state: .ready))
    }

    func testAnUnknownStateDecodesAsNotReady() throws {
        let json = """
        {"entryID":"item-a","revisionID":"rev-1","contentHash":"","byteCount":4096,"mediaType":"audio/mp4","state":"someFutureState"}
        """
        let offer = try JSONDecoder().decode(LibraryMediaOffer.self, from: Data(json.utf8))
        XCTAssertEqual(offer.state, .notReady)
        XCTAssertFalse(offer.isPrepared)
    }

    func testTheTransportHoldsAnAvailableOfferWithoutAudioAndRefusesToServeIt() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let offer = try available()
        try await mac.publishMedia(offer: offer, fileURL: URL(fileURLWithPath: "/dev/null"))
        let listed = try await phone.mediaOffers()
        XCTAssertEqual(listed, [offer])
        do {
            _ = try await phone.fetchMedia(offer) { _ in }
            XCTFail("an available offer has no audio to fetch")
        } catch {}
    }
}
