import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

private struct LegacyPublicationTransport: LibraryTransport {
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        LibraryChangeBatch(generationID: "legacy", changes: [], token: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { .init() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { .init() }
}

final class LibraryPublicationTests: XCTestCase {
    private func receipt(_ date: Date = Date(timeIntervalSince1970: 1_000)) throws -> LibraryPublication {
        try .init(id: "publication-1", publishedAt: date, writerDeviceID: "mac")
    }

    func testPublicationRoundTripsItsStableIdentityAndAuthorDate() throws {
        let value = try receipt()
        XCTAssertEqual(try JSONDecoder().decode(LibraryPublication.self, from: JSONEncoder().encode(value)), value)
    }

    func testEmptyPublicationIdentityIsRejectedIncludingDuringDecode() throws {
        XCTAssertThrowsError(try LibraryPublication(id: " ", publishedAt: Date(), writerDeviceID: "mac"))
        let json = Data(#"{"id":"","publishedAt":0,"writerDeviceID":"mac"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryPublication.self, from: json))
    }

    func testEmptyWriterAndNonFiniteAuthorDateAreRejected() {
        XCTAssertThrowsError(try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: ""))
        XCTAssertThrowsError(try receipt(Date(timeIntervalSinceReferenceDate: .infinity)))
    }

    func testFutureAuthorDateRemainsAnObservationWithoutClamping() throws {
        let date = Date(timeIntervalSince1970: 9_000_000_000)
        XCTAssertEqual(try receipt(date).publishedAt, date)
    }

    func testLegacyBatchAndOwnerDefaultsRemainUnverified() async throws {
        let transport = LegacyPublicationTransport()
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertNil(batch.provenance)
        XCTAssertNil(batch.observedPublication)
        let owner = await transport.verifiedOwnerToken()
        XCTAssertNil(owner)
    }

    func testLegacyPublicationReadIsUnknownAndPublishFailsUnsupported() async throws {
        let transport = LegacyPublicationTransport()
        let unknown = try await transport.readPublication()
        XCTAssertNil(unknown)
        do { try await transport.publishPublication(receipt()); XCTFail("legacy publish cannot succeed") }
        catch { XCTAssertEqual(error as? LibraryTransportError, .transport("library publication is not supported by this transport")) }
    }

    func testReferenceWriterReceiptIsSeparateFromContentAndFetchedAsMetadata() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "test-owner")
        try await mac.publishPublication(receipt())
        let observed = try await phone.readPublication()
        XCTAssertEqual(observed, try receipt())
        let batch = try await phone.fetchChanges(since: nil)
        XCTAssertEqual(batch.observedPublication, observed)
        XCTAssertTrue(batch.changes.isEmpty)
        XCTAssertEqual(batch.provenance, .init(ownerToken: "test-owner", operationGeneration: 0, isFullBootstrap: true))
        let next = try await phone.fetchChanges(since: batch.token)
        XCTAssertEqual(next.provenance?.isFullBootstrap, false)
    }

    func testReferenceReaderCannotPublishOrForgeAnotherWriterReceipt() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        do { try await phone.publishPublication(receipt()); XCTFail("reader published") } catch {}
        let forged = try LibraryPublication(id: "forged", publishedAt: Date(), writerDeviceID: "phone")
        do { try await mac.publishPublication(forged); XCTFail("forged writer published") } catch {}
        let value = try await mac.readPublication()
        XCTAssertNil(value)
    }
}
