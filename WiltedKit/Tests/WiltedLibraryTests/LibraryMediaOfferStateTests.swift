import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryMediaOfferStateTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-a")
    private let revision = try! RevisionID(rawValue: "rev-1")

    private func available(hash: String = "") throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: entry, revisionID: revision, contentHash: hash, byteCount: 4_096,
            mediaType: "audio/mp4", durationSeconds: 61, state: .available
        )
    }

    func testAvailableOfferRoundTripsWithoutAHash() throws {
        let offer = try available()
        XCTAssertEqual(offer.state, .available)
        XCTAssertTrue(offer.isPrepared)
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
